import Foundation

// Mirrors Pipecat `turns/user_start/base_user_turn_start_strategy.py`

/// Base class for all user-turn start strategies.
/// Mirrors `BaseUserTurnStartStrategy` in Pipecat.
class BaseUserTurnStartStrategy {

    // Configuration (mirrors Python class-level defaults)
    let enableInterruptions: Bool
    let enableUserSpeakingFrames: Bool

    // Callbacks injected by UserTurnController.setupStrategies()
    var onUserTurnStarted: ((UserTurnStartedParams) async -> Void)?
    var onPushFrame: ((Frame, FrameDirection) async -> Void)?
    var onBroadcastFrame: ((() -> Frame) async -> Void)?
    var onResetAggregation: (() async -> Void)?

    init(enableInterruptions: Bool = true, enableUserSpeakingFrames: Bool = true) {
        self.enableInterruptions = enableInterruptions
        self.enableUserSpeakingFrames = enableUserSpeakingFrames
    }

    // Lifecycle — mirrors setup/cleanup/reset methods
    func setup() async {}
    func cleanup() async {}
    func reset() async {}

    /// Core method subclasses implement.
    /// Mirrors `process_frame(frame, direction, callback)`.
    func processFrame(_ frame: Frame) async -> ProcessFrameResult {
        return .continue
    }

    // MARK: - Helpers for subclasses

    /// Trigger turn-started event. Mirrors `_trigger_user_turn_start` callback.
    func triggerUserTurnStarted() async {
        await onUserTurnStarted?(UserTurnStartedParams(
            enableInterruptions: enableInterruptions,
            enableUserSpeakingFrames: enableUserSpeakingFrames
        ))
    }
}
