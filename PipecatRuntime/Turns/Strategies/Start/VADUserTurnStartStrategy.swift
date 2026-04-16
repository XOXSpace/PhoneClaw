import Foundation

// Mirrors Pipecat `turns/user_start/vad_user_turn_start_strategy.py`

/// VAD-based turn start strategy.
/// VADUserStartedSpeakingFrame → triggerUserTurnStarted → .stop
final class VADUserTurnStartStrategy: BaseUserTurnStartStrategy {

    override func processFrame(_ frame: Frame) async -> ProcessFrameResult {
        if frame is VADUserStartedSpeakingFrame {
            await triggerUserTurnStarted()
            return .stop
        }
        return .continue
    }
}
