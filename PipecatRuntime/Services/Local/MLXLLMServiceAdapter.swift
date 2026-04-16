import Foundation
import MLXLMCommon

typealias LLMAdditionalContext = [String: any Sendable]

private enum TurnCompletionIncompleteType {
    case short
    case long
}

private actor TurnCompletionRuntime {
    private let sleeper: Sleeper
    private var config = UserTurnCompletionConfig()
    private var turnTextBuffer = ""
    private var turnSuppressed = false
    private var turnCompleteFound = false
    private var spokenBuffer = ""
    private var sanitizer = StreamingSanitizer(mode: .liveVoice)
    private var incompleteTimeoutTask: Task<Void, Never>?
    private var incompleteTimeoutToken = UUID()

    init(sleeper: Sleeper) {
        self.sleeper = sleeper
    }

    func updateConfig(_ config: UserTurnCompletionConfig?) {
        self.config = config ?? UserTurnCompletionConfig()
    }

    func beginResponse() {
        turnTextBuffer = ""
        turnSuppressed = false
        turnCompleteFound = false
        spokenBuffer = ""
        sanitizer = StreamingSanitizer(mode: .liveVoice)
    }

    func handleInterruption(push: @escaping @Sendable (Frame) async -> Void) async {
        await cancelIncompleteTimeout()
        await turnReset(push: push)
    }

    func cancelPendingTimeout() async {
        await cancelIncompleteTimeout()
    }

    func handleResponseEnd(push: @escaping @Sendable (Frame) async -> Void) async {
        await turnReset(push: push)
    }

    func handleToken(_ text: String, push: @escaping @Sendable (Frame) async -> Void) async {
        if turnSuppressed {
            return
        }

        if turnCompleteFound {
            await emitSanitized(text, push: push)
            return
        }

        turnTextBuffer += text

        let incompleteType: TurnCompletionIncompleteType?
        if turnTextBuffer.contains("○") {
            incompleteType = .short
        } else if turnTextBuffer.contains("◐") {
            incompleteType = .long
        } else {
            incompleteType = nil
        }

        if let incompleteType {
            turnSuppressed = true
            await push(LLMTextFrame(text: turnTextBuffer, skipTTS: true))
            turnTextBuffer = ""
            await startIncompleteTimeout(incompleteType, push: push)
            return
        }

        guard let markerIndex = turnTextBuffer.firstIndex(of: "✓") else {
            return
        }

        let markerEnd = turnTextBuffer.index(after: markerIndex)
        let markerText = String(turnTextBuffer[..<markerEnd])
        await push(LLMTextFrame(text: markerText, skipTTS: true))

        var remainingText = String(turnTextBuffer[markerEnd...])
        if remainingText.first == " " {
            remainingText.removeFirst()
        }

        turnTextBuffer = ""
        turnCompleteFound = true

        if !remainingText.isEmpty {
            await emitSanitized(remainingText, push: push)
        }
    }

    private func emitSanitized(
        _ text: String,
        push: @escaping @Sendable (Frame) async -> Void
    ) async {
        spokenBuffer += text
        let delta = sanitizer.feed(spokenBuffer)
        if !delta.isEmpty {
            await push(LLMTextFrame(text: delta))
        }
    }

    private func turnReset(push: @escaping @Sendable (Frame) async -> Void) async {
        let markerFound = turnSuppressed || turnCompleteFound
        if !markerFound && !turnTextBuffer.isEmpty {
            await emitSanitized(turnTextBuffer, push: push)
        }

        let finalDelta = sanitizer.finalize(spokenBuffer)
        if !finalDelta.isEmpty {
            await push(LLMTextFrame(text: finalDelta))
        }

        beginResponse()
    }

    private func startIncompleteTimeout(
        _ type: TurnCompletionIncompleteType,
        push: @escaping @Sendable (Frame) async -> Void
    ) async {
        await cancelIncompleteTimeout()

        let token = UUID()
        incompleteTimeoutToken = token
        let timeout = type == .short ? config.incompleteShortTimeout : config.incompleteLongTimeout

        incompleteTimeoutTask = Task { [sleeper] in
            do {
                try await sleeper.sleep(for: timeout)
                await self.handleIncompleteTimeout(token: token, type: type, push: push)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }

        await Task.yield()
    }

    private func handleIncompleteTimeout(
        token: UUID,
        type: TurnCompletionIncompleteType,
        push: @escaping @Sendable (Frame) async -> Void
    ) async {
        guard incompleteTimeoutToken == token else { return }

        await turnReset(push: push)
        incompleteTimeoutTask = nil

        let prompt = type == .short ? config.shortPrompt : config.longPrompt
        await push(
            LLMMessagesAppendFrame(
                messages: [
                    LLMContextMessage(role: .system, content: prompt)
                ]
            )
        )
        await push(LLMRunFrame())
    }

    private func cancelIncompleteTimeout() async {
        incompleteTimeoutTask?.cancel()
        incompleteTimeoutTask = nil
        incompleteTimeoutToken = UUID()
    }
}

protocol LocalLLMServicing: AnyObject {
    var isLoaded: Bool { get }
    func load() async throws
    func warmup() async throws
    func generateStream(
        chat: [Chat.Message],
        additionalContext: LLMAdditionalContext?
    ) -> AsyncThrowingStream<String, Error>
    func cancel()
}

extension MLXLocalLLMService: LocalLLMServicing {}

private actor LLMGenerationTracker {
    private var currentID: UInt64 = 0

    func begin() -> UInt64 {
        currentID += 1
        return currentID
    }

    func invalidate() {
        currentID += 1
    }

    func isActive(_ id: UInt64) -> Bool {
        currentID == id
    }
}

final class MLXLLMServiceAdapter: FrameProcessor, @unchecked Sendable {
    typealias AdditionalContextProvider = (LLMContext) -> LLMAdditionalContext?

    private let service: LocalLLMServicing
    private let additionalContextProvider: AdditionalContextProvider?
    private let warmupOnFirstLoad: Bool
    private let tracker = LLMGenerationTracker()
    private let turnCompletionRuntime: TurnCompletionRuntime
    private let settings = LLMSettings.defaultStore()
    private var generationTask: Task<Void, Never>?
    private var baseSystemInstruction: String?
    private var filterIncompleteUserTurns = false
    private var userTurnCompletionConfig = UserTurnCompletionConfig()

    /// Diagnostic counter: 累计收到的 LLMContextFrame 数. Test runner 观察用,
    /// runtime 不消费. Thread-safe (NSLock).
    private let ctxCountLock = NSLock()
    private var _receivedContextCount = 0
    var receivedContextCount: Int {
        ctxCountLock.withLock { _receivedContextCount }
    }

    init(
        service: LocalLLMServicing,
        additionalContextProvider: AdditionalContextProvider? = nil,
        warmupOnFirstLoad: Bool = false,
        sleeper: Sleeper = RealSleeper()
    ) {
        self.service = service
        self.additionalContextProvider = additionalContextProvider
        self.warmupOnFirstLoad = warmupOnFirstLoad
        self.turnCompletionRuntime = TurnCompletionRuntime(sleeper: sleeper)
        super.init(name: "MLXLLMServiceAdapter")
    }

    override func didReceiveStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await cancelGeneration()
        await turnCompletionRuntime.cancelPendingTimeout()
    }

    override func didReceiveCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await cancelGeneration()
        await turnCompletionRuntime.cancelPendingTimeout()
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        switch frame {
        case let frame as LLMUpdateSettingsFrame:
            if let service = frame.service, service !== self {
                await context.push(frame, direction: direction)
            } else if let delta = frame.llmDelta {
                await applySettings(delta)
            } else if !frame.settings.isEmpty {
                await applySettings(LLMSettings.fromMapping(frame.settings))
            } else {
                await applySettings(nil)
            }

        case let frame as LLMContextFrame:
            ctxCountLock.withLock { _receivedContextCount += 1 }
            print("[MLXLLMAdapter] received LLMContextFrame messages=\(frame.context.messages.count)")
            await startGeneration(for: frame.context, context: context)

        case is InterruptionFrame:
            print("[MLXLLMAdapter] received InterruptionFrame — cancelling generation")
            let emit: @Sendable (Frame) async -> Void = { frame in
                await context.push(frame, direction: .downstream)
            }
            await turnCompletionRuntime.handleInterruption(push: emit)
            await cancelGeneration()
            print("[MLXLLMAdapter] cancelGeneration DONE")
            await context.push(frame, direction: direction)

        default:
            await super.process(frame, direction: direction, context: context)
        }
    }

    private func startGeneration(for contextFrame: LLMContext, context: FrameProcessorContext) async {
        await cancelGeneration()

        let requestID = await tracker.begin()
        let chat = buildChatMessages(from: contextFrame.messages)
        let additionalContext = additionalContextProvider?(contextFrame)

        let systemChars = chat.first(where: { $0.role == .system })?.content.count ?? 0
        print("[MLXLLMAdapter] chat roles=\(chat.map { String(describing: $0.role) }.joined(separator: "+")) systemChars=\(systemChars)")
        let emit: @Sendable (Frame) async -> Void = { frame in
            await context.push(frame, direction: .downstream)
        }

        generationTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.ensureServiceReady()
                guard await self.tracker.isActive(requestID) else { return }
                await self.turnCompletionRuntime.beginResponse()
                print("[MLXLLMAdapter] ▶ LLMFullResponseStartFrame")
                await emit(LLMFullResponseStartFrame())

                var sanitizer = StreamingSanitizer(mode: .liveVoice)
                var rawBuffer = ""

                // Gemma 4 specific: 走手写 <|turn> 模板字符串 + UserInput(prompt:) 路径,
                // 和 AgentEngine (iOS Chat UI) 一致. 不走 UserInput(chat:), 因为 MLXLMCommon
                // 对 Gemma 4 的 chat template apply 会让 system role 对 E2B/E4B 失效
                // (CLI live-pipeline-mlx harness 实测: chat 路径输出 "我是 Gemma 4" 忽略 persona;
                // prompt 路径输出 "✓ 我是手机龙虾" 正常遵守). 详见 PromptBuilder.buildGemmaChatPrompt.
                let stream: AsyncThrowingStream<String, Error>
                if let mlx = self.service as? MLXLocalLLMService {
                    let gemmaPrompt = PromptBuilder.buildGemmaChatPrompt(chat: chat)
                    _ = additionalContext  // Gemma 分支不透传 additionalContext (多模态已由 adapter 上游剥离)
                    stream = mlx.generateStream(prompt: gemmaPrompt, images: [], audios: [])
                } else {
                    stream = self.service.generateStream(
                        chat: chat,
                        additionalContext: additionalContext
                    )
                }

                // DIAGNOSTIC: 收集 Gemma 原始 token 流. 用来诊断 "LLM 生成 N tokens 但下游 0 字"
                // 这类 ghost 输出场景 (例如 thinking channel / tool_call / 其它被 sanitizer 吃掉的内容).
                // 在 LLMFullResponseEnd 后整体打印. 保留长期, 信号密度合理 (每轮一行).
                var rawTokenTrace = ""
                for try await token in stream {
                    guard await self.tracker.isActive(requestID), !Task.isCancelled else {
                        return
                    }

                    rawTokenTrace += token

                    if self.filterIncompleteUserTurns {
                        await self.turnCompletionRuntime.handleToken(token, push: emit)
                    } else {
                        rawBuffer += token
                        let delta = sanitizer.feed(rawBuffer)
                        if !delta.isEmpty {
                            await emit(LLMTextFrame(text: delta))
                        }
                    }
                }
                let preview = rawTokenTrace.count > 300
                    ? String(rawTokenTrace.prefix(300)) + "…"
                    : rawTokenTrace
                print("[MLXLLMAdapter] raw stream (\(rawTokenTrace.count) chars): \(preview.debugDescription)")

                guard await self.tracker.isActive(requestID), !Task.isCancelled else {
                    return
                }

                if self.filterIncompleteUserTurns {
                    await self.turnCompletionRuntime.handleResponseEnd(push: emit)
                } else {
                    let finalDelta = sanitizer.finalize(rawBuffer)
                    if !finalDelta.isEmpty {
                        await emit(LLMTextFrame(text: finalDelta))
                    }
                }

                print("[MLXLLMAdapter] ◼ LLMFullResponseEndFrame")
                await emit(LLMFullResponseEndFrame())
            } catch is CancellationError {
                return
            } catch {
                guard await self.tracker.isActive(requestID), !Task.isCancelled else {
                    return
                }
                await emit(
                    ErrorFrame(
                        message: "MLXLLMServiceAdapter generation failed",
                        underlyingError: error
                    )
                )
            }
        }
    }

    private func ensureServiceReady() async throws {
        guard !service.isLoaded else { return }

        try await service.load()
        if warmupOnFirstLoad {
            try await service.warmup()
        }
    }

    private func cancelGeneration() async {
        generationTask?.cancel()
        generationTask = nil
        service.cancel()
        await tracker.invalidate()
    }

    private func applySettings(_ delta: LLMSettings?) async {
        guard let delta else { return }

        let changed = settings.applyUpdate(delta)

        if changed.keys.contains("filter_incomplete_user_turns") {
            filterIncompleteUserTurns = settings.resolvedFilterIncompleteUserTurns
            if filterIncompleteUserTurns {
                baseSystemInstruction = settings.resolvedSystemInstruction
                composeSystemInstruction()
            } else {
                settings.systemInstruction = .value(baseSystemInstruction)
                baseSystemInstruction = nil
            }
        }

        if changed.keys.contains("user_turn_completion_config"),
           filterIncompleteUserTurns {
            userTurnCompletionConfig = settings.resolvedUserTurnCompletionConfig ?? UserTurnCompletionConfig()
            composeSystemInstruction()
        }

        if changed.keys.contains("system_instruction"),
           filterIncompleteUserTurns,
           !changed.keys.contains("filter_incomplete_user_turns") {
            baseSystemInstruction = settings.resolvedSystemInstruction
            composeSystemInstruction()
        }

        if !changed.keys.contains("user_turn_completion_config") {
            userTurnCompletionConfig = settings.resolvedUserTurnCompletionConfig ?? UserTurnCompletionConfig()
        }

        await turnCompletionRuntime.updateConfig(userTurnCompletionConfig)
    }

    private func buildChatMessages(from messages: [LLMContextMessage]) -> [Chat.Message] {
        injectSystemInstruction(into: messages).compactMap { message in
            let content = serializeContent(for: message)

            switch message.role {
            case .system, .developer:
                guard !content.isEmpty else { return nil }
                return .system(content)
            case .user:
                guard !content.isEmpty else { return nil }
                return .user(content)
            case .assistant:
                guard !content.isEmpty else { return nil }
                return .assistant(content)
            case .tool:
                guard !content.isEmpty else { return nil }
                return .tool(content)
            }
        }
    }

    private func composeSystemInstruction() {
        var parts: [String] = []
        if let baseSystemInstruction,
           !baseSystemInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(baseSystemInstruction)
        }
        if filterIncompleteUserTurns {
            parts.append(userTurnCompletionConfig.completionInstructions)
        }

        let composed = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        settings.systemInstruction = .value(composed.isEmpty ? nil : composed)
    }

    private func injectSystemInstruction(into messages: [LLMContextMessage]) -> [LLMContextMessage] {
        guard let instruction = settings.resolvedSystemInstruction else {
            return messages
        }

        let instructions = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { return messages }

        if let index = messages.firstIndex(where: { $0.role == .system || $0.role == .developer }) {
            let message = messages[index]
            let existingContent = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let mergedContent: String
            if existingContent.contains(instructions) {
                mergedContent = existingContent
            } else if existingContent.isEmpty {
                mergedContent = instructions
            } else {
                mergedContent = "\(existingContent)\n\n\(instructions)"
            }

            var updatedMessages = messages
            updatedMessages[index] = LLMContextMessage(
                role: message.role,
                content: mergedContent,
                toolCalls: message.toolCalls,
                toolCallID: message.toolCallID
            )
            return updatedMessages
        }

        return [LLMContextMessage(role: .system, content: instructions)] + messages
    }

    private func serializeContent(for message: LLMContextMessage) -> String {
        var parts: [String] = []

        let trimmedContent = message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedContent.isEmpty {
            parts.append(trimmedContent)
        }

        if !message.toolCalls.isEmpty {
            let serializedCalls = message.toolCalls.map { call in
                """
                <tool_call>
                id=\(call.id)
                name=\(call.name)
                arguments=\(call.arguments)
                </tool_call>
                """
            }
            parts.append(contentsOf: serializedCalls)
        }

        if let toolCallID = message.toolCallID,
           message.role == .tool {
            parts.insert("<tool_result id=\(toolCallID)>", at: 0)
            parts.append("</tool_result>")
        }

        return parts.joined(separator: "\n")
    }
}
