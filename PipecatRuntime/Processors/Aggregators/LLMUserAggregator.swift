import Foundation

struct LLMUserAggregatorParams {
    let userMuteStrategies: [BaseUserMuteStrategy]
    let userIdleTimeout: TimeInterval
    let userTurnStopTimeout: TimeInterval
    let audioIdleTimeout: TimeInterval
    let filterIncompleteUserTurns: Bool
    let userTurnCompletionConfig: UserTurnCompletionConfig?
    /// VAD analyzer for internal VADController. When non-nil, the pipeline's
    /// VADProcessor node should be removed (VAD is handled here instead).
    /// Mirrors Pipecat LLMUserAggregator params.vad_analyzer.
    let vadAnalyzer: VADAnalyzerProtocol?
    /// Minimum interval between on_speech_activity events (mirrors vad_controller.py:75).
    let speechActivityPeriod: TimeInterval

    init(
        userMuteStrategies: [BaseUserMuteStrategy] = [],
        userIdleTimeout: TimeInterval = 0,
        userTurnStopTimeout: TimeInterval = 5.0,
        audioIdleTimeout: TimeInterval = 1.0,
        filterIncompleteUserTurns: Bool = false,
        userTurnCompletionConfig: UserTurnCompletionConfig? = nil,
        vadAnalyzer: VADAnalyzerProtocol? = nil,
        speechActivityPeriod: TimeInterval = 0.2
    ) {
        self.userMuteStrategies = userMuteStrategies
        self.userIdleTimeout = userIdleTimeout
        self.userTurnStopTimeout = userTurnStopTimeout
        self.audioIdleTimeout = audioIdleTimeout
        self.filterIncompleteUserTurns = filterIncompleteUserTurns
        self.userTurnCompletionConfig = userTurnCompletionConfig
        self.vadAnalyzer = vadAnalyzer
        self.speechActivityPeriod = speechActivityPeriod
    }
}

final class LLMUserAggregator: LLMContextAggregator, @unchecked Sendable {
    private let params: LLMUserAggregatorParams
    private let turnController: UserTurnController
    private let userIdleController: UserIdleController
    private var userIsMuted = false
    /// Internal VADController. Non-nil when params.vadAnalyzer is set.
    /// When active, the pipeline's VADProcessor node must be removed.
    private var vadController: VADController?

    var onUserTurnIdle: (@Sendable () async -> Void)?
    var onUserMuteStarted: (@Sendable () async -> Void)?
    var onUserMuteStopped: (@Sendable () async -> Void)?

    init(
        context: LLMContext = LLMContext(),
        params: LLMUserAggregatorParams = LLMUserAggregatorParams(),
        turnController: UserTurnController = UserTurnController(),
        userIdleController: UserIdleController? = nil
    ) {
        self.params = params
        self.turnController = turnController
        self.userIdleController = userIdleController ?? UserIdleController(
            userIdleTimeout: params.userIdleTimeout
        )
        // Build VADController if a VADAnalyzer was provided.
        // Mirrors Pipecat LLMUserAggregator._vad_controller setup.
        if let analyzer = params.vadAnalyzer {
            self.vadController = VADController(
                vadAnalyzer: analyzer,
                speechActivityPeriod: params.speechActivityPeriod,
                audioIdleTimeout: params.audioIdleTimeout
            )
        }
        super.init(context: context, role: .user, name: "LLMUserAggregator")
        // VADController callbacks are bound at process() time (need context).
    }

    override func didReceiveStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        // Mirrors Pipecat llm_response_universal.py:562
        // `await self._vad_controller.setup(self.task_manager)` — exact equivalent
        if let vc = vadController {
            await vc.setup(sampleRate: Int(frame.audioMetadata?.input?.sampleRate ?? 16000))
            // Also broadcast initial SpeechControlParamsFrame (mirrors vad_controller.py:_start)
            await vc.processFrame(frame)
        }

        // Mirrors `await self._user_turn_controller.setup(self.task_manager)` → py:566
        // Must be awaited: strategies are not ready until setup() completes.
        await turnController.setup()

        // Mirrors `await self._user_idle_controller.setup(self.task_manager)` → py:568
        userIdleController.start()

        userIsMuted = false
        for strategy in params.userMuteStrategies {
            await strategy.setup()
            await strategy.reset()
        }
        if params.filterIncompleteUserTurns {
            let config = params.userTurnCompletionConfig ?? UserTurnCompletionConfig()
            await context.push(
                LLMUpdateSettingsFrame(
                    delta: LLMSettings(
                        filterIncompleteUserTurns: true,
                        userTurnCompletionConfig: config
                    )
                ),
                direction: .downstream
            )
        }
    }

    override func didReceiveStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await maybePushAggregation(context: context)
        // Mirrors Pipecat _cleanup() → py:596: await vad/turn/idle controller.cleanup()
        if let vc = vadController { await vc.cleanup() }
        await turnController.cleanup()
        turnController.clearHandlers()
        userIdleController.stop()
        await cleanupMuteStrategies()
    }

    override func didReceiveCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await maybePushAggregation(context: context)
        // Mirrors Pipecat _cleanup() → py:596
        if let vc = vadController { await vc.cleanup() }
        await turnController.cleanup()
        turnController.clearHandlers()
        userIdleController.cancel()
        await cleanupMuteStrategies()
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        bindTurnController(to: context)
        bindUserIdleController()
        bindVADController(to: context)  // re-binds each call, but closures are identical (no-op after first)
        if await maybeMuteFrame(frame, context: context) {
            return
        }

        switch frame {
        case is StartFrame, is StopFrame, is CancelFrame:
            await super.process(frame, direction: direction, context: context)

        case let frame as TranscriptionFrame:
            let text = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[LLMUserAgg] received TranscriptionFrame text=\"\(text)\" dir=\(direction)")
            if !text.isEmpty {
                appendAggregation(
                    text,
                    includesInterFrameSpaces: frame.includesInterFrameSpaces
                )
            }
            // Route to stop strategies: TurnAnalyzerStopStrategy.handleTranscription
            // needs the finalized flag to trigger maybeTriggerUserTurnStopped.
            await processTurnFrame(frame, direction: direction, context: context)

        case let frame as InputAudioRawFrame:
            // Route audio to VADController first (when internal VAD is active).
            // Mirrors Pipecat LLMUserAggregator._handle_input_audio.
            await vadController?.processFrame(frame)
            // Also route to turn strategies so TurnAnalyzerStopStrategy can buffer audio
            // for SmartTurn ML inference. Mirrors turn_analyzer_user_turn_stop_strategy.py:_handle_input_audio.
            await processTurnFrame(frame, direction: direction, context: context)
            await context.push(frame, direction: direction)

        case is InterimTranscriptionFrame:
            break

        case is UserTurnCommittedFrame:
            // UserTurnCommittedFrame is a legacy PhoneC frame used in UserTurnProcessor.
            // In LLMUserAggregator, aggregation is triggered by onUserTurnStopped callback,
            // not by an external committed signal. Pass through to avoid blocking downstream.
            await context.push(frame, direction: direction)

        case let frame as UserStartedSpeakingFrame:
            await context.push(frame, direction: direction)
            await processTurnFrame(frame, direction: direction, context: context)

        case let frame as UserStoppedSpeakingFrame:
            await context.push(frame, direction: direction)
            await processTurnFrame(frame, direction: direction, context: context)

        case is VADUserStartedSpeakingFrame,
            is VADUserStoppedSpeakingFrame:
            // Pipecat frame surface (user_turn_controller.py:12-19). Route to stop strategy chain.
            await processTurnFrame(frame, direction: direction, context: context)

        case is StartInterruptionFrame,
            is StopInterruptionFrame:
            // PhoneC-specific: STT gate control for SherpaSTT.
            // No Pipecat equivalent (Pipecat uses cloud STT with no gate needed).
            // Pass through so SherpaSTTServiceAdapter receives them; do NOT route to
            // turn strategies (they have no knowledge of these frames).
            await context.push(frame, direction: direction)

        case is LLMRunFrame:
            await pushContextFrame(direction: .downstream, context: context)

        case let frame as LLMMessagesAppendFrame:
            addMessages(frame.messages)
            if frame.runLLM {
                await pushContextFrame(direction: .downstream, context: context)
            }

        case let frame as LLMMessagesUpdateFrame:
            setMessages(frame.messages)
            if frame.runLLM {
                await pushContextFrame(direction: .downstream, context: context)
            }

        case let frame as LLMMessagesTransformFrame:
            transformMessages(frame.transform)
            if frame.runLLM {
                await pushContextFrame(direction: .downstream, context: context)
            }

        default:
            await context.push(frame, direction: direction)
        }

        await userIdleController.process(frame)
    }

    private func bindTurnController(to context: FrameProcessorContext) {
        turnController.onUserTurnStarted = { [weak self] _, params in
            guard let self else { return }

            print("[LLMUserAgg] onUserTurnStarted enableUserSpeakingFrames=\(params.enableUserSpeakingFrames) enableInterruptions=\(params.enableInterruptions)")
            if params.enableUserSpeakingFrames {
                await self.broadcast(UserStartedSpeakingFrame(), context: context)
                await self.userIdleController.process(UserStartedSpeakingFrame())
            }
            if params.enableInterruptions {
                print("[LLMUserAgg] broadcasting InterruptionFrame (barge-in)")
                await self.broadcast(InterruptionFrame(), context: context)
                print("[LLMUserAgg] InterruptionFrame broadcast DONE")
            }
        }

        turnController.onUserTurnStopped = { [weak self] _, params in
            guard let self else { return }

            print("[LLMUserAgg] onUserTurnStopped enableUserSpeakingFrames=\(params.enableUserSpeakingFrames)")
            if params.enableUserSpeakingFrames {
                await self.broadcast(UserStoppedSpeakingFrame(), context: context)
                await self.userIdleController.process(UserStoppedSpeakingFrame())
            }
            await self.maybePushAggregation(context: context)
            // PhoneClaw-specific: trigger SherpaSTT batch transcription.
            // Pipecat cloud STT does not need this; streaming transcription follows VAD automatically.
            // This replaces UserTurnProcessor.onUserTurnStopped → UserTurnCommittedFrame path,
            // eliminating the need for a separate UserTurnProcessor node in the aggregator-centric pipeline.
            await context.push(UserTurnCommittedFrame(wasInterruptedTurn: false), direction: .downstream)
        }
    }

    private func bindUserIdleController() {
        userIdleController.onUserTurnIdle = { [weak self] in
            guard let self else { return }
            await self.onUserTurnIdle?()
        }
    }

    private func cleanupMuteStrategies() async {
        for strategy in params.userMuteStrategies {
            await strategy.cleanup()
        }
        userIsMuted = false
    }

    private func maybeMuteFrame(
        _ frame: Frame,
        context: FrameProcessorContext
    ) async -> Bool {
        if frame is StartFrame || frame is StopFrame || frame is CancelFrame {
            return false
        }

        let shouldMuteFrame = userIsMuted && (
            frame is InterruptionFrame ||
            frame is VADUserStartedSpeakingFrame ||
            frame is VADUserStoppedSpeakingFrame ||
            frame is UserStartedSpeakingFrame ||
            frame is UserStoppedSpeakingFrame ||
            frame is InputAudioRawFrame ||
            frame is InterimTranscriptionFrame ||
            frame is TranscriptionFrame
        )

        var shouldMuteNextTime = false
        for strategy in params.userMuteStrategies {
            let strategyMuted = await strategy.processFrame(frame)
            shouldMuteNextTime = shouldMuteNextTime || strategyMuted
        }

        if shouldMuteNextTime != userIsMuted {
            userIsMuted = shouldMuteNextTime
            if userIsMuted {
                await onUserMuteStarted?()
                await broadcast(UserMuteStartedFrame(), context: context)
            } else {
                await onUserMuteStopped?()
                await broadcast(UserMuteStoppedFrame(), context: context)
            }
        }

        return shouldMuteFrame
    }

    private func processTurnFrame(
        _ frame: Frame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        let push: @Sendable (Frame, FrameDirection) async -> Void = { frame, direction in
            await context.push(frame, direction: direction)
        }
        await turnController.processFrame(frame, direction: direction, push: push)
    }

    @discardableResult
    private func maybePushAggregation(context: FrameProcessorContext) async -> String {
        let content = aggregationString().trimmingCharacters(in: .whitespacesAndNewlines)
        resetAggregation()

        print("[LLMUserAgg] maybePushAggregation content=\"\(content)\"")
        guard !content.isEmpty else { return "" }

        llmContext.addMessage(
            LLMContextMessage(
                role: .user,
                content: content
            )
        )
        print("[LLMUserAgg] pushing LLMContextFrame downstream")
        await pushContextFrame(direction: .downstream, context: context)
        return content
    }

    private func broadcast(
        _ frame: @autoclosure () -> Frame,
        context: FrameProcessorContext
    ) async {
        let downstreamFrame = frame()
        let upstreamFrame = frame()
        downstreamFrame.broadcastSiblingID = upstreamFrame.id
        upstreamFrame.broadcastSiblingID = downstreamFrame.id

        await context.push(downstreamFrame, direction: .downstream)
        await context.push(upstreamFrame, direction: .upstream)
    }

    /// Wire VADController event callbacks that require pipeline context.
    /// Called from process() so we always have a valid FrameProcessorContext.
    /// Mirrors Pipecat on_speech_started / on_speech_stopped wiring inside LLMUserAggregator.
    private func bindVADController(to context: FrameProcessorContext) {
        guard let vc = vadController else { return }
        guard vc.onSpeechStarted == nil else { return }  // already bound on first process() call

        let startSecs = params.vadAnalyzer?.params.startSecs ?? 0.2
        let stopSecs  = params.vadAnalyzer?.params.stopSecs  ?? 0.2

        // Broadcast the frame into the pipeline. The frame will reenter process() and
        // hit `case is VADUserStartedSpeakingFrame → processTurnFrame → turnController.processFrame`.
        // This matches Pipecat's structure: VADController emits on_speech_started, the
        // enclosing processor pushes a VADUserStartedSpeakingFrame downstream.
        vc.onSpeechStarted = { [weak self] in
            guard let self else { return }
            print("[LLMUserAgg] broadcasting VADUserStartedSpeakingFrame + feeding turnController")
            let frame = VADUserStartedSpeakingFrame(startSecs: startSecs)
            await self.broadcast(frame, context: context)
            // Source-iso with pipecat llm_response_universal.py:546 —
            // pipecat queues VAD frames back to self via `_queued_broadcast_frame`,
            // so process_frame runs again and feeds them to user_turn_controller.
            // Swift broadcast() pushes to neighbours only, never self-loops,
            // so we feed the turn controller explicitly to mirror pipecat's
            // single source of truth for VAD-driven turn transitions.
            await self.processTurnFrame(frame, direction: .downstream, context: context)
        }

        vc.onSpeechStopped = { [weak self] in
            guard let self else { return }
            print("[LLMUserAgg] broadcasting VADUserStoppedSpeakingFrame + feeding turnController")
            let frame = VADUserStoppedSpeakingFrame(stopSecs: stopSecs)
            await self.broadcast(frame, context: context)
            await self.processTurnFrame(frame, direction: .downstream, context: context)
        }

        vc.onBroadcastFrame = { [weak self] makeFrame in
            guard let self else { return }
            await self.broadcast(makeFrame(), context: context)
        }
    }
}
