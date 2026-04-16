import Foundation

// Mirrors Pipecat UserTurnStartedParams dataclass
// from base_user_turn_start_strategy.py
struct UserTurnStartedParams {
    let enableInterruptions: Bool
    let enableUserSpeakingFrames: Bool
}

// Mirrors Pipecat UserTurnStoppedParams dataclass
// from base_user_turn_stop_strategy.py
struct UserTurnStoppedParams {
    let enableUserSpeakingFrames: Bool
}
