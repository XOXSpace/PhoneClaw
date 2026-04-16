import Foundation

// Mirrors Pipecat `turns/user_stop/base_user_turn_stop_strategy.py`

/// Base class for all user-turn stop strategies.
class BaseUserTurnStopStrategy {

    let enableUserSpeakingFrames: Bool

    var onUserTurnStopped: ((UserTurnStoppedParams) async -> Void)?
    var onPushFrame: ((Frame, FrameDirection) async -> Void)?
    var onBroadcastFrame: ((() -> Frame) async -> Void)?

    init(enableUserSpeakingFrames: Bool = true) {
        self.enableUserSpeakingFrames = enableUserSpeakingFrames
    }

    func setup() async {}
    func cleanup() async {}
    func reset() async {}

    func processFrame(_ frame: Frame) async -> ProcessFrameResult {
        return .continue
    }

    func triggerUserTurnStopped() async {
        await onUserTurnStopped?(UserTurnStoppedParams(
            enableUserSpeakingFrames: enableUserSpeakingFrames
        ))
    }
}
