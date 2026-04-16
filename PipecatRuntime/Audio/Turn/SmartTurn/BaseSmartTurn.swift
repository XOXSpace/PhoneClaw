import Foundation

// Mirrors Pipecat `base_smart_turn.py`
// Reference constants from base_smart_turn.py:27-29
private let kStopSecs: Float = 3.0
private let kPreSpeechMs: Float = 500
private let kMaxDurationSecs: Float = 8.0

/// Base class for ML-driven turn analyzers.
/// Mirrors Pipecat `BaseSmartTurn(BaseTurnAnalyzer)`.
class BaseSmartTurn: BaseTurnAnalyzerProtocol {

    struct Params {
        /// Silence threshold (seconds) before declaring end-of-turn without ML.
        /// Mirrors SmartTurnParams.stop_secs = STOP_SECS = 3.
        var stopSecs: Float = kStopSecs
        /// Pre-speech audio to include before detected speech start (ms).
        /// Mirrors SmartTurnParams.pre_speech_ms = PRE_SPEECH_MS = 500.
        var preSpeechMs: Float = kPreSpeechMs
        /// Maximum segment duration fed to ML model.
        /// Mirrors SmartTurnParams.max_duration_secs = MAX_DURATION_SECONDS = 8.
        var maxDurationSecs: Float = kMaxDurationSecs
    }

    // MARK: - State (mirrors Python instance vars)

    private(set) var sampleRate: Int = 16000
    let params: Params

    /// [(timestamp: TimeInterval, samples: [Float])]
    /// Mirrors `self._audio_buffer = []`
    private var audioBuffer: [(TimeInterval, [Float])] = []

    /// Mirrors `self._speech_triggered = False`
    private var speechTriggered = false

    /// Accumulated silence in ms since last speech chunk.
    /// Mirrors `self._silence_ms = 0`
    private var silenceMs: Float = 0

    /// Wall-clock time when speech first triggered.
    /// Mirrors `self._speech_start_time = 0`
    private var speechStartTime: TimeInterval = 0

    /// Mirrors `self._vad_start_secs: float = 0.0`
    private var vadStartSecs: Float = 0.0

    // MARK: - Init

    init(params: Params = Params()) {
        self.params = params
    }

    // MARK: - BaseTurnAnalyzerProtocol

    func setSampleRate(_ rate: Int) {
        sampleRate = rate
    }

    /// Mirrors `append_audio(buffer, is_speech)` → `base_smart_turn.py:101`.
    @discardableResult
    func appendAudio(_ audio: Data, isSpeech: Bool) -> EndOfTurnState {
        let int16Samples = audio.withUnsafeBytes { buf in
            Array(buf.bindMemory(to: Int16.self))
        }
        let float32: [Float] = int16Samples.map { Float($0) / 32768.0 }
        let now = Date().timeIntervalSince1970
        audioBuffer.append((now, float32))

        var state: EndOfTurnState = .incomplete

        if isSpeech {
            // Reset silence tracking on speech
            silenceMs = 0
            speechTriggered = true
            if speechStartTime == 0 {
                speechStartTime = now
            }
        } else {
            if speechTriggered {
                let chunkDurationMs = Float(int16Samples.count) / (Float(sampleRate) / 1000.0)
                silenceMs += chunkDurationMs
                // Silence-based fallback: mirrors Python stop_secs logic
                if silenceMs >= params.stopSecs * 1000 {
                    state = .complete
                    clearInternal(state)
                }
            } else {
                // Trim buffer before speech to prevent unbounded growth
                // Mirrors Python while loop at base_smart_turn.py:142
                let maxBufferTime = TimeInterval(
                    (params.preSpeechMs / 1000) + params.stopSecs + params.maxDurationSecs
                )
                while !audioBuffer.isEmpty && audioBuffer[0].0 < now - maxBufferTime {
                    audioBuffer.removeFirst()
                }
            }
        }
        return state
    }

    /// Mirrors `analyze_end_of_turn()` → `base_smart_turn.py:149`.
    /// Runs `processSpeechSegment` on a detached background Task
    /// (equivalent to `loop.run_in_executor(self._executor, ...)`).
    func analyzeEndOfTurn() async -> (EndOfTurnState, TurnMetricsData?) {
        let bufferSnapshot = audioBuffer
        let speechStart = speechStartTime
        let vadStart = vadStartSecs

        let (state, metrics) = await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return (EndOfTurnState.incomplete, nil as TurnMetricsData?) }
            return self.processSpeechSegment(
                buffer: bufferSnapshot,
                speechStartTime: speechStart,
                vadStartSecs: vadStart
            )
        }.value

        if state == .complete {
            clearInternal(state)
        }
        return (state, metrics)
    }

    func updateVADStartSecs(_ secs: Float) {
        vadStartSecs = secs
    }

    func clear() {
        clearInternal(.complete)
    }

    func cleanup() async {
        // Base implementation: nothing to release. Subclasses override for ML resources.
    }

    // MARK: - Abstract (subclass must override)

    /// Mirrors `_predict_endpoint(audio_array)` abstract method.
    /// Returns `(prediction: 1|0, probability: Float)`.
    func predictEndpoint(_ audioSegment: [Float]) -> (prediction: Int, probability: Float) {
        fatalError("\(type(of: self)) must implement predictEndpoint(_:)")
    }

    // MARK: - Private

    /// Mirrors `_process_speech_segment(audio_buffer)` → `base_smart_turn.py:181`.
    private func processSpeechSegment(
        buffer: [(TimeInterval, [Float])],
        speechStartTime: TimeInterval,
        vadStartSecs: Float
    ) -> (EndOfTurnState, TurnMetricsData?) {
        guard !buffer.isEmpty else { return (.incomplete, nil) }

        // Compute pre-speech window start time
        // Mirrors: start_time = _speech_start_time - (effective_pre_speech_ms / 1000)
        let effectivePreSpeechMs = params.preSpeechMs + (vadStartSecs * 1000)
        let windowStart = speechStartTime - TimeInterval(effectivePreSpeechMs / 1000)

        // Find start index in buffer
        var startIndex = 0
        for (i, (t, _)) in buffer.enumerated() {
            if t >= windowStart {
                startIndex = i
                break
            }
        }

        // Concatenate audio segment
        var segmentAudio: [Float] = buffer[startIndex...].flatMap { $0.1 }

        // Limit to maxDurationSecs (keep tail: mirrors `segment_audio[-max_samples:]`)
        let maxSamples = Int(params.maxDurationSecs * Float(sampleRate))
        if segmentAudio.count > maxSamples {
            segmentAudio = Array(segmentAudio.suffix(maxSamples))
        }

        guard !segmentAudio.isEmpty else { return (.incomplete, nil) }

        let wallStart = CFAbsoluteTimeGetCurrent()
        let result = predictEndpoint(segmentAudio)
        let e2eMs = (CFAbsoluteTimeGetCurrent() - wallStart) * 1000

        let state: EndOfTurnState = result.prediction == 1 ? .complete : .incomplete
        let metrics = TurnMetricsData(
            isComplete: result.prediction == 1,
            probability: result.probability,
            e2eProcessingTimeMs: e2eMs
        )
        return (state, metrics)
    }

    private func clearInternal(_ turnState: EndOfTurnState) {
        // If incomplete, keep speechTriggered = true (mirrors Python _clear logic)
        speechTriggered = (turnState == .incomplete)
        audioBuffer = []
        speechStartTime = 0
        silenceMs = 0
    }
}
