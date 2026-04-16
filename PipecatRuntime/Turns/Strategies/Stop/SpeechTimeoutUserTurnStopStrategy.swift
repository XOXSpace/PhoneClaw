import Foundation

// Optional, non-default. Never selected by default path.
// Mirrors Pipecat `turns/user_stop/speech_timeout_user_turn_stop_strategy.py`
// Only available for explicit opt-in: UserTurnStrategies(stop: [SpeechTimeoutUserTurnStopStrategy()])

final class SpeechTimeoutUserTurnStopStrategy: BaseUserTurnStopStrategy {

    /// Silence timeout after VAD stops (seconds). Mirrors `user_speech_timeout` param.
    var userSpeechTimeout: TimeInterval = 0.6

    private var vadUserSpeaking = false
    private var timeoutTask: Task<Void, Never>?

    override func reset() async {
        vadUserSpeaking = false
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    override func cleanup() async {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    override func processFrame(_ frame: Frame) async -> ProcessFrameResult {
        if frame is VADUserStartedSpeakingFrame {
            vadUserSpeaking = true
            timeoutTask?.cancel()
            timeoutTask = nil
        } else if frame is VADUserStoppedSpeakingFrame {
            vadUserSpeaking = false
            scheduleTimeout()
        } else if frame is TranscriptionFrame {
            // Transcription resets the timeout if user is still speaking
            if vadUserSpeaking {
                timeoutTask?.cancel()
                timeoutTask = nil
            }
        }
        return .continue
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(userSpeechTimeout * 1_000_000_000))
            } catch { return }
            guard !Task.isCancelled, !self.vadUserSpeaking else { return }
            await self.triggerUserTurnStopped()
        }
    }
}
