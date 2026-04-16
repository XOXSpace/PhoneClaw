import Foundation

@MainActor
final class LiveStateObserver: BaseObserver {
    private let state: LiveSessionState
    private var processedFrameIDs: Set<UUID> = []
    /// Tracks the last incomplete turn marker (○/◐) seen from a skipTTS LLMTextFrame.
    /// Fired via onIncompleteTurn callback when LLMRunFrame arrives (not via shared state).
    private var lastIncompleteMarker: String? = nil

    init(state: LiveSessionState) {
        self.state = state
    }

    // MARK: - Pipeline lifecycle

    func onPipelineStarted() async {
        state.stage = .listening
    }

    func onPipelineFinished(_ frame: Frame) async {
        state.stage = .idle
        state.isUserSpeaking = false
        state.isBotSpeaking = false
        state.lastFrameName = frame.name
    }

    // MARK: - Frame observation

    func onProcessFrame(_ data: FrameProcessed) async {
        let frame = data.frame
        let direction = data.direction
        if frame.broadcastSiblingID != nil, direction == .upstream {
            return
        }
        guard markFrameIfNeeded(frame) else { return }
        state.lastFrameName = frame.name

        switch frame {
        case is StartFrame:
            state.stage = .listening

        case is UserStartedSpeakingFrame:
            state.isUserSpeaking = true
            state.stage = .userSpeaking

        case is UserStoppedSpeakingFrame:
            state.isUserSpeaking = false
            state.stage = state.isBotSpeaking ? .assistantSpeaking : .listening

        case is BotStartedSpeakingFrame:
            state.isBotSpeaking = true
            state.stage = .assistantSpeaking

        case is BotStoppedSpeakingFrame:
            state.isBotSpeaking = false
            state.stage = state.isUserSpeaking ? .userSpeaking : .listening

        case let frame as InterimTranscriptionFrame:
            state.interimTranscript = frame.text
            state.caption = frame.text

        case let frame as TranscriptionFrame:
            state.transcript = frame.text
            state.interimTranscript = ""
            state.caption = frame.text

        case is LLMFullResponseStartFrame:
            state.assistantReply = ""
            state.stage = .assistantSpeaking
            // New LLM generation resets marker tracking.
            // onIncompleteTurn already fired atomically from LLMRunFrame before this frame
            // can arrive, so no delivery race exists.
            lastIncompleteMarker = nil

        case let frame as TextFrame where !(frame is BaseTranscriptionFrame):
            if frame.skipTTS == true {
                // Capture incomplete turn marker (○ or ◐) emitted by MLXLLMServiceAdapter
                // as LLMTextFrame(skipTTS: true) when filterIncompleteUserTurns is on.
                let text = frame.text
                if text.contains("○") { lastIncompleteMarker = "○" }
                else if text.contains("◐") { lastIncompleteMarker = "◐" }
                break
            }
            state.assistantReply += frame.text
            state.caption = state.assistantReply

        case is LLMRunFrame:
            // Fires after the incomplete-turn timeout (per MLXLLMServiceAdapter.handleIncompleteTimeout).
            // Deliver via direct callback — not via LiveSessionState field — to guarantee exactly-once
            // delivery regardless of when LLMFullResponseStartFrame arrives.
            if let marker = lastIncompleteMarker {
                lastIncompleteMarker = nil
                onIncompleteTurn?(marker)
            }

        case let frame as ErrorFrame:
            state.lastError = frame.message
            state.stage = .error
            onError?(frame.message)

        case is StopFrame, is CancelFrame, is EndFrame:
            state.stage = .stopping

        default:
            break
        }
    }

    // MARK: - Callbacks (set by PipecatLivePipeline before calling task.start())

    /// Fires when MLXLLMServiceAdapter detects an incomplete user turn.
    /// Marker is "○" (short) or "◐" (long). Guaranteed exactly-once delivery from LLMRunFrame.
    /// Safe from LLMFullResponseStartFrame clear race because it fires synchronously here.
    var onIncompleteTurn: ((String) -> Void)?

    /// Fires on ErrorFrame — optional, for facade-layer error handling.
    var onError: ((String) -> Void)?

    // MARK: - Private

    private func markFrameIfNeeded(_ frame: Frame) -> Bool {
        let inserted = processedFrameIDs.insert(frame.id).inserted
        if processedFrameIDs.count > 1024 {
            processedFrameIDs.removeAll(keepingCapacity: true)
        }
        return inserted
    }
}
