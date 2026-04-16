import Foundation

// Mirrors Pipecat `turns/user_turn_strategies.py`
// Default stop strategy in pipecat = TurnAnalyzerUserTurnStopStrategy(LocalSmartTurnAnalyzer()).
//
// SOURCE-ISO BOUNDARY:
//   - `defaultStart()` is platform-agnostic and stays here (in package).
//   - `defaultStop()` previously hardcoded iOS-only `LocalSmartTurnAnalyzer`
//     (ORT bridging header, iOS app target only). Removed from package so
//     the pipecat library is platform-agnostic.
//   - iOS app provides the SmartTurn-based default via extension file
//     `PhoneClaw/PipecatBindings/UserTurnStrategies+iOSDefault.swift`.
//   - Mac CLI provides its own default (or stub) via similar extension.
//
// Caller MUST now provide `stop:` explicitly. No-arg `UserTurnStrategies()`
// gives empty stop array — pipeline will not commit user turns until
// caller adds at least one stop strategy.

struct UserTurnStrategies {
    var start: [BaseUserTurnStartStrategy]
    var stop:  [BaseUserTurnStopStrategy]

    /// Mirrors `default_user_turn_start_strategies()` → user_turn_strategies.py:26
    static func defaultStart() -> [BaseUserTurnStartStrategy] {
        [VADUserTurnStartStrategy(), TranscriptionUserTurnStartStrategy()]
    }

    init(
        start: [BaseUserTurnStartStrategy]? = nil,
        stop:  [BaseUserTurnStopStrategy]? = nil
    ) {
        self.start = start ?? UserTurnStrategies.defaultStart()
        self.stop  = stop  ?? []
    }
}
