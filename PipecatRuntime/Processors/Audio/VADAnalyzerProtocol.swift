import Foundation

// Mirrors Pipecat `audio/vad/vad_analyzer.py` — protocol and constants.
//
// VADParams 定义在 ControlFrames.swift（单一来源，与 Pipecat Python 同构）。
// 这里只定义 VADState enum、常量、和 VADAnalyzerProtocol。

// Mirrors vad_analyzer.py module-level constants:
//   VAD_STOP_SECS = 0.8 (but overridden to 0.2 in default VADParams)
//   VAD_START_SECS = 0.2
//   VAD_CONFIDENCE = 0.7
//   VAD_MIN_VOLUME = 0.6
let VAD_STOP_SECS: Double = 0.2
let VAD_START_SECS: Double = 0.2
let VAD_CONFIDENCE: Double = 0.7
let VAD_MIN_VOLUME: Double = 0.6

/// Mirrors Pipecat `VADState` enum.
enum VADState: Equatable {
    case quiet
    case starting
    case speaking
    case stopping
}

/// Mirrors Pipecat `VADAnalyzer` ABC.
/// Uses the single `VADParams` type (defined in ControlFrames.swift),
/// matching Pipecat's unified model where frames and analyzer share the same VADParams.
protocol VADAnalyzerProtocol: AnyObject {
    var params: VADParams { get }
    func setSampleRate(_ rate: Int)
    func setParams(_ params: VADParams)
    /// Analyze one chunk of raw audio (float32 PCM).
    func analyzeAudio(_ samples: [Float]) async -> VADState
    func cleanup() async
}
