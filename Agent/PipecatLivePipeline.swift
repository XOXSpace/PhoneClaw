import Foundation
import Observation

// MARK: - PipecatLivePipeline
//
// 对应 Pipecat Python 的 `asyncio.run(main())` + `PipelineTask` 组合。
// 负责组装 live pipeline，持有 PipelineTask 生命周期，暴露事件 callback 给 LiveModeEngine。
//
// Pipeline 处理器顺序（与 pipecat `examples/getting-started/06a-voice-agent-local.py` 同构）：
//   IOSLiveInputTransport
//   → SherpaSTTServiceAdapter    (上游 STT，由 VAD 帧驱动 batch transcribe)
//   → LLMUserAggregator          (内置 VADController + UserTurnController；消费 TranscriptionFrame)
//   → MLXLLMServiceAdapter
//   → SherpaTTSServiceAdapter
//   → IOSLiveOutputTransport
//   → LLMAssistantAggregator     (transport.output 之后，消费 TTSTextFrame 构建 spoken history)
//
// 移除 BotSpeechGateProcessor — pipecat 没有此节点。Bot-speaking 期间的
// barge-in 由 LLMUserAggregator 内部 turn_controller + InterruptionFrame
// 广播处理（与 pipecat `broadcast_interruption` 同构）。
//
// 生命周期契约（对齐 Pipecat asyncio.create_task 模型）：
//   - start() : 创建 pipeline + task，非阻塞，await task.start() 等待 .running
//   - stop()  : await pipelineTask.stop() + await runTask.value（等待 transport 完全退出）
//   - cancel(): await pipelineTask.cancel() + await runTask.value

@MainActor
final class PipecatLivePipeline {

    // MARK: - STT Path Toggle (验证通过后保留 streaming，删另两个)
    //
    // 三态选择 STT 适配器：
    //   .legacy    —— 原 SherpaSTTServiceAdapter (批用流式模型，VAD STOP 一次转写)
    //   .segmented —— SherpaSegmentedSTTServiceAdapter (pipecat SegmentedSTT 同构，1s pre-buffer)
    //   .streaming —— SherpaStreamingSTTServiceAdapter (pipecat 流式 STTService 同构，每帧吐 partial)
    //
    // pipecat 18 个范例默认走 streaming（继承 STTService 直接基类）——
    // 我们的 sherpa-onnx 模型本就支持 streaming API，应当对齐 streaming。
    enum STTPath {
        case legacy
        case segmented
        case streaming
    }
    static let sttPath: STTPath = .streaming

    // MARK: - State

    /// 当前会话状态，供 LiveModeEngine 通过 AsyncStream 观察。
    let sessionState = LiveSessionState()

    // MARK: - Event Callbacks (UI / observability only)

    /// 收到不完整 turn 标记时触发 (○ 或 ◐)。
    /// runtime (MLXLLMServiceAdapter.handleIncompleteTimeout) 已自主处理 follow-up；
    /// 此 callback 仅用于 UI 状态更新，不得重复调用 scheduleIncompleteTurnFollowUp。
    var onIncompleteTurn: ((String) -> Void)?

    /// 收到 error 时触发（对应 LiveSessionState.stage == .error）。
    var onError: ((String) -> Void)?

    // MARK: - Private

    private var pipelineTask: PipelineTask?
    private var runTask: Task<Void, Never>?

    // MARK: - Start

    /// 组装 pipeline 并启动 PipelineTask。
    /// - Parameters:
    ///   - audioIO: 已启动的 LiveAudioIO 实例（由 LiveModeEngine 管理生命周期）
    ///   - llm: MLXLocalLLMService 本地推理服务
    ///   - userSystemPrompt: AgentEngine.config.systemPrompt（来自 SYSPROMPT.md）。
    ///     传 nil 时回落到 PromptBuilder.defaultSystemPrompt。
    ///     不论传什么都会在尾部追加 live voice 强约束（marker / 角色 / 语气 / 字数）。
    func start(
        audioIO: LiveAudioIO,
        llm: MLXLocalLLMService,
        userSystemPrompt: String? = nil
    ) async {
        // --- LLM Context ---
        let basePrompt = userSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBase = (basePrompt?.isEmpty == false ? basePrompt! : PromptBuilder.defaultSystemPrompt)
        let fullSystemPrompt = liveVoiceSystemPrompt(base: effectiveBase)
        // DEBUG: 验证 prompt 注入链是否真的把 SYSPROMPT.md + live voice 强约束送到 LLM
        print("[PipecatPipeline] userSystemPrompt nil=\(userSystemPrompt == nil) chars=\(userSystemPrompt?.count ?? 0)")
        print("[PipecatPipeline] effectiveBase chars=\(effectiveBase.count) head=\"\(String(effectiveBase.prefix(60)))\"")
        print("[PipecatPipeline] fullSystemPrompt chars=\(fullSystemPrompt.count)")
        print("[PipecatPipeline] fullSystemPrompt tail=\"\(String(fullSystemPrompt.suffix(120)))\"")
        let context = LLMContext(messages: [
            LLMContextMessage(role: .system, content: fullSystemPrompt)
        ])

        // --- UserAggregator（内置 VAD + TurnController，替代独立 VADProcessor 节点）---
        // 注: instructions="" 故意给空 — 默认的 userTurnCompletionInstructions 是 2000+ 字英文
        // 描述 ✓/○/◐ 语义, 和我们 liveConstraint (中文重写版) 功能完全重复, 会被 adapter 的
        // composeSystemInstruction 拼到 prompt 末尾, 让 prefill 从 ~625 tokens 涨到 ~1144 tokens,
        // TTFT P50 从 700ms 涨到 1400ms. 过空字符串让它被 filter(.isEmpty) 干掉, 不进 prompt.
        let userParams = LLMUserAggregatorParams(
            filterIncompleteUserTurns: true,
            userTurnCompletionConfig: UserTurnCompletionConfig(instructions: ""),
            vadAnalyzer: FluidAudioVADAnalyzer()
        )
        // iOS 显式装配 TurnController：UserTurnStrategies.iosDefaultStop() 来自
        // Agent/PipecatBindings/UserTurnStrategies+iOSDefault.swift（iOS-only 扩展），
        // 提供 LocalSmartTurnAnalyzer。Mac CLI 走另一条 path 注入 stub analyzer。
        let strategies = UserTurnStrategies(stop: UserTurnStrategies.iosDefaultStop())
        let turnController = UserTurnController(strategies: strategies)
        let userAggregator = LLMUserAggregator(
            context: context,
            params: userParams,
            turnController: turnController
        )

        // --- AssistantAggregator（pipecat 同构：放在 transport.output 之后）---
        let assistantAggregator = LLMAssistantAggregator(context: context)

        // --- STT 适配器（三态 toggle）---
        let stt: FrameProcessor
        switch Self.sttPath {
        case .legacy:
            stt = SherpaSTTServiceAdapter()
        case .segmented:
            stt = SherpaSegmentedSTTServiceAdapter()
        case .streaming:
            stt = SherpaStreamingSTTServiceAdapter()
        }
        print("[PipecatPipeline] STT path = \(Self.sttPath)")

        // --- Pipeline 顺序（pipecat 06a-voice-agent-local.py 同构）---
        let pipeline = Pipeline([
            IOSLiveInputTransport(audioIO: audioIO, autoManageEngine: false),
            stt,                        // 上游 STT，VAD 驱动 batch transcribe
            userAggregator,             // 内置 VAD + TurnController；消费 TranscriptionFrame
            MLXLLMServiceAdapter(service: llm),
            // text_filters 同 pipecat `TTSService(text_filters=[...])` —— 顺序应用：
            //   1. MarkdownTextFilter: 剥除 LLM 输出的 markdown (** _ ` 等)
            //   2. RemoveEmojiTextFilter: 剥除 sherpa-onnx 词典外的 emoji
            // pipecat 没有内置 emoji filter（云 TTS 能处理），这里用 BaseTextFilter
            // 抽象扩展，符合 pipecat 设计原则（filter 链可叠加）。
            SherpaTTSServiceAdapter(textFilters: [
                MarkdownTextFilter(),
                RemoveEmojiTextFilter(),
            ]),
            IOSLiveOutputTransport(audioIO: audioIO),
            assistantAggregator,        // transport.output 之后
        ])

        // --- StateObserver（在 task.start() 前注入，确保不遗漏任何事件）---
        let stateObserver = LiveStateObserver(state: sessionState)
        stateObserver.onIncompleteTurn = { [weak self] marker in
            // 中继给 LiveModeEngine（UI 专用，runtime 不需要再次触发 follow-up）
            self?.onIncompleteTurn?(marker)
        }
        stateObserver.onError = { [weak self] message in
            self?.onError?(message)
        }

        // --- PipelineTask ---
        let task = PipelineTask(pipeline: pipeline)
        await task.addObserver(stateObserver)
        pipelineTask = task

        // run() 在独立 Task 中运行，对应 Python asyncio.create_task(task.run())
        // 不 await，避免阻塞 start() 调用方
        print("[PipecatPipeline] Creating runTask...")
        runTask = Task { await task.run() }

        // 等待 pipeline 进入 .running 状态
        // 对应 Python runner.py 里 await task.run() 等到 StartFrame 跑完全链。
        // run() 在 Task 里异步执行，用 waitUntilRunning() 等 StartFrame 跑到 boundary。
        await task.waitUntilRunning()
        print("[PipecatPipeline] Pipeline running ✓, state = \(await task.state)")
    }

    // MARK: - Stop / Cancel

    /// 优雅停止：等待 pipeline 处理完当前 frame 后退出。
    /// 同步等待 runTask 结束，确保 audioIO teardown 在 pipeline 完全退出后进行。
    func stop() async {
        await pipelineTask?.stop()
        await runTask?.value   // 等待 transportDidStop + observer 回调完成
        runTask = nil
        pipelineTask = nil
    }

    /// 强制取消：立即中止，丢弃进行中的 frame。
    func cancel() async {
        await pipelineTask?.cancel()
        await runTask?.value
        runTask = nil
        pipelineTask = nil
    }

    // MARK: - System Prompt

    /// 构建 live voice mode 的完整 system prompt：
    ///   `base`（来自 SYSPROMPT.md 或 defaultSystemPrompt）+ live voice 强约束
    /// 强约束包含 4 个维度，与 LiveModeEngine 旧版同步（小模型对弱指令响应差，
    /// 必须用强语气 + 多重重复 + 就近示范才能稳定遵守）：
    ///   1. ✓/○/◐ marker 协议（filterIncompleteUserTurns 依赖）
    ///   2. 角色身份（"你叫手机龙虾"）
    ///   3. 语气强度（"必须" / "绝对不能" / "禁止"）
    ///   4. 句子数约束（"一两句话"）
    private func liveVoiceSystemPrompt(base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed + """


你叫手机龙虾，正在进行实时语音对话。**这是语音模式，不是思考模式**。

严格禁止输出以下内容（会导致用户听不到任何回复）：
- `<|channel|>` `<channel|>` `thought` 等任何 channel 标记或思考标签
- "让我想想""这是个好问题""首先""我来分析一下"等任何开场白、铺垫、推理过程
- 任何形式的内部思考、反思、步骤分解

每次回复第一字符必须是 `✓`、`○` 或 `◐` 之一：
- `✓ {回答}`：用户的话已经完整。这是默认选项。`你好` `现在几点` `天气怎样` `嗯` `好的` `是` `不是` 这种短但完整的陈述或问句都用 `✓`。
- `○`（单字符，后不跟任何字）：用户明显被打断，例如 `我想` `那我` `所以`。
- `◐`（单字符，后不跟任何字）：用户明确要求时间思考，例如 `让我想想` `等一下`。

`✓` 之后直接给最终答案，必须：
- **一句话，最多两句**。绝对不超过 30 个汉字。
- 纯中文口语，多用逗号和句号。禁止英文字母、markdown 符号 `*_#`、任何英文单词包括 AI。
- 你叫手机龙虾，自称"手机龙虾"或"龙虾"，不要说"Gemma""Google""AI 助手"。
- 遇到需要长篇展开的话题（如介绍历史/讲故事），用一句话总结，不展开细节。
"""
    }
}
