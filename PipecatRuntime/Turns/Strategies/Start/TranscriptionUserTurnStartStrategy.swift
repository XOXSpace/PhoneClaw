import Foundation

// Mirrors Pipecat `turns/user_start/transcription_user_turn_start_strategy.py`

/// Transcription-based turn start strategy (bot-speech interruption fallback).
/// InterimTranscriptionFrame (configurable) or TranscriptionFrame → triggerUserTurnStarted → .stop
final class TranscriptionUserTurnStartStrategy: BaseUserTurnStartStrategy {

    /// If true, InterimTranscriptionFrame also triggers turn start.
    /// Mirrors Python `use_interim` param.
    var useInterim: Bool = true

    override func processFrame(_ frame: Frame) async -> ProcessFrameResult {
        if useInterim && frame is InterimTranscriptionFrame {
            await triggerUserTurnStarted()
            return .stop
        }
        if frame is TranscriptionFrame {
            await triggerUserTurnStarted()
            return .stop
        }
        return .continue
    }
}
