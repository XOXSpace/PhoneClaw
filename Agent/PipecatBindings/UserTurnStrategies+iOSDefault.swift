import Foundation

// iOS-specific default for `UserTurnStrategies.stop`.
//
// The base `UserTurnStrategies` lives in PipecatRuntime (cross-platform).
// It deliberately does NOT hardcode a default stop strategy because the
// canonical pipecat default — `TurnAnalyzerUserTurnStopStrategy(LocalSmartTurnAnalyzer())` —
// requires the ONNX Runtime C bridging header that only the iOS app target
// links. Mac CLI provides its own default via a parallel extension.
//
// PipecatLivePipeline calls `UserTurnStrategies(stop: UserTurnStrategies.iosDefaultStop())`
// so the runtime composition stays platform-iso while the iOS app gets
// the SmartTurn-backed behaviour pipecat expects by default.

extension UserTurnStrategies {
    /// Mirrors pipecat `default_user_turn_stop_strategies()` (user_turn_strategies.py:36),
    /// scoped to the iOS app target where `LocalSmartTurnAnalyzer` (ORT C API)
    /// is linked.
    static func iosDefaultStop() -> [BaseUserTurnStopStrategy] {
        [TurnAnalyzerUserTurnStopStrategy(turnAnalyzer: LocalSmartTurnAnalyzer())]
    }
}
