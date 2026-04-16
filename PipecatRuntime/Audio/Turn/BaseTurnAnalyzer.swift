import Foundation

// Mirrors Pipecat `base_turn_analyzer.py`

/// End-of-turn detection result.
/// Mirrors Pipecat `EndOfTurnState`.
enum EndOfTurnState {
    case complete
    case incomplete
}

/// Metrics emitted after each ML inference run.
/// Mirrors Pipecat `TurnMetricsData`.
struct TurnMetricsData {
    let isComplete: Bool
    let probability: Float
    let e2eProcessingTimeMs: Double
}

/// Protocol mirroring Pipecat `BaseTurnAnalyzer` ABC.
protocol BaseTurnAnalyzerProtocol: AnyObject {
    /// Current pipeline sample rate (set by setSampleRate).
    var sampleRate: Int { get }

    /// Called when StartFrame arrives with the pipeline audio sample rate.
    func setSampleRate(_ rate: Int)

    /// Append a chunk of audio data for buffering.
    /// `isSpeech` mirrors Pipecat's VAD `is_speech` flag passed per chunk.
    /// Returns whether the silence-based fallback has detected end-of-turn.
    @discardableResult
    func appendAudio(_ audio: Data, isSpeech: Bool) -> EndOfTurnState

    /// Run ML inference on the current audio buffer.
    /// Mirrors `analyze_end_of_turn()` — runs in a background context.
    func analyzeEndOfTurn() async -> (EndOfTurnState, TurnMetricsData?)

    /// Update the VAD start_secs value used to compute pre-speech padding.
    func updateVADStartSecs(_ secs: Float)

    /// Reset the turn analyzer to its initial state.
    func clear()

    /// Release any ML resources (model, executor).
    func cleanup() async
}
