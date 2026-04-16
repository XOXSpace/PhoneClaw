import Foundation

// Mirrors Pipecat `turns/user_stop/turn_analyzer_user_turn_stop_strategy.py`
// Source-isomorphic path: same state machine, same frame dispatch order as Python.

final class TurnAnalyzerUserTurnStopStrategy: BaseUserTurnStopStrategy {

    private let turnAnalyzer: BaseTurnAnalyzerProtocol

    // Mirrors Python instance vars (py:57-67)
    private var sttTimeout: TimeInterval = 0       // STT P99 latency from STTMetadataFrame
    private var stopSecs: TimeInterval = 0         // VAD stop_secs from VADUserStoppedSpeakingFrame
    private var text = ""
    private var turnComplete = false
    private var vadUserSpeaking = false
    private var vadStoppedTime: TimeInterval? = nil
    private var transcriptFinalized = false
    private var timeoutTask: Task<Void, Never>? = nil

    init(turnAnalyzer: BaseTurnAnalyzerProtocol, enableUserSpeakingFrames: Bool = true) {
        self.turnAnalyzer = turnAnalyzer
        super.init(enableUserSpeakingFrames: enableUserSpeakingFrames)
    }

    // MARK: - Lifecycle

    override func setup() async {
        // turnAnalyzer.setSampleRate is called when StartFrame arrives
    }

    override func cleanup() async {
        timeoutTask?.cancel()
        timeoutTask = nil
        await turnAnalyzer.cleanup()
    }

    override func reset() async {
        // Mirrors py:69
        text = ""
        turnComplete = false
        vadUserSpeaking = false
        vadStoppedTime = nil
        transcriptFinalized = false
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    // MARK: - processFrame

    /// Mirrors `process_frame(frame)` → py:97. Always returns .continue.
    override func processFrame(_ frame: Frame) async -> ProcessFrameResult {
        if let f = frame as? StartFrame {
            await handleStart(f)
        } else if let f = frame as? InputAudioRawFrame {
            await handleInputAudio(f)
        } else if let f = frame as? VADUserStartedSpeakingFrame {
            await handleVADStarted(f)
        } else if let f = frame as? VADUserStoppedSpeakingFrame {
            await handleVADStopped(f)
        } else if let f = frame as? TranscriptionFrame {
            // Swift TranscriptionFrame = Pipecat TranscriptionFrame with finalized=True
            // InterimTranscriptionFrame = finalized=False (not handled by this strategy)
            await handleTranscription(f, finalized: true)
        } else if let f = frame as? InterimTranscriptionFrame {
            // Pipecat py fires _handle_transcription for all TranscriptionFrame regardless of
            // finalized; pass finalized=false for interim frames. (py:108-111 branch)
            await handleTranscription(f, finalized: false)
        }
        return .continue
    }

    // MARK: - Handlers (mirrors Python _handle_* methods)

    /// Mirrors `_start(frame)` → py:124
    /// Python: self._turn_analyzer.set_sample_rate(frame.audio_in_sample_rate)
    /// Swift:  StartFrame.audioMetadata?.input?.sampleRate (Double) → Int for BaseTurnAnalyzer
    private func handleStart(_ frame: StartFrame) async {
        let rate = Int(frame.audioMetadata?.input?.sampleRate ?? 16000)
        turnAnalyzer.setSampleRate(rate)
    }

    /// Mirrors `_handle_input_audio(frame)` → py:129.
    /// Pipecat Python passes Int16 PCM bytes into BaseSmartTurn.append_audio.
    /// Swift AudioChunk is Float32 samples, so convert at the boundary to preserve
    /// the same appendAudio contract as Python.
    private func handleInputAudio(_ frame: InputAudioRawFrame) async {
        let audioData = frame.chunk.toInt16PCMData()
        let state = turnAnalyzer.appendAudio(audioData, isSpeech: vadUserSpeaking)
        if state == .complete {
            let (_, metrics) = await turnAnalyzer.analyzeEndOfTurn()
            await handlePredictionResult(metrics)
            turnComplete = true
            await maybeTriggerUserTurnStopped()
        }
    }

    /// Mirrors `_handle_vad_user_started_speaking(frame)` → py:144
    /// Python: frame.start_secs (float); Swift: frame.startSecs (Double) → Float for BaseTurnAnalyzer
    private func handleVADStarted(_ frame: VADUserStartedSpeakingFrame) async {
        turnAnalyzer.updateVADStartSecs(Float(frame.startSecs))
        turnComplete = false
        vadUserSpeaking = true
        vadStoppedTime = nil
        transcriptFinalized = false
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    /// Mirrors `_handle_vad_user_stopped_speaking(frame)` → py:157
    private func handleVADStopped(_ frame: VADUserStoppedSpeakingFrame) async {
        vadUserSpeaking = false
        stopSecs = frame.stopSecs
        vadStoppedTime = Date().timeIntervalSince1970

        let (state, metrics) = await turnAnalyzer.analyzeEndOfTurn()
        await handlePredictionResult(metrics)
        turnComplete = (state == .complete)

        // STT timeout adjusted by VAD stop_secs (time already elapsed)
        let timeout = max(0, sttTimeout - stopSecs)
        scheduleTimeout(timeout)
    }

    /// Mirrors `_handle_transcription(frame)` → py:199
    /// Python's `finalized` field:
    ///   - TranscriptionFrame.finalized=True  → Swift TranscriptionFrame (passed finalized:true)
    ///   - TranscriptionFrame.finalized=False → Swift InterimTranscriptionFrame (passed finalized:false)
    private func handleTranscription(_ frame: BaseTranscriptionFrame, finalized: Bool) async {
        text = frame.text
        if finalized {
            transcriptFinalized = true
            await maybeTriggerUserTurnStopped()
        }

        // Fallback: no VAD stop received yet → assume complete, reset timeout
        if !vadUserSpeaking && vadStoppedTime == nil {
            timeoutTask?.cancel()
            turnComplete = true
            let timeout = max(0, sttTimeout - stopSecs)
            scheduleTimeout(timeout)
        }
    }

    /// Mirrors `_handle_prediction_result(result)` → py:225
    private func handlePredictionResult(_ metrics: TurnMetricsData?) async {
        guard let metrics else { return }
        // Push MetricsFrame if needed (placeholder — frame type depends on host app)
        // In Pipecat: await self.push_frame(MetricsFrame(data=[result]))
        // PhoneClaw extension point: extend when MetricsFrame is defined.
        _ = metrics
    }

    /// Mirrors `_timeout_handler(timeout)` → py:230
    private func scheduleTimeout(_ timeout: TimeInterval) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            if timeout > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch { return }
            }
            self.timeoutTask = nil       // mirrors py: finally: self._timeout_task = None
            await self.maybeTriggerUserTurnStopped()
        }
    }

    /// Mirrors `_maybe_trigger_user_turn_stopped()` → py:245
    private func maybeTriggerUserTurnStopped() async {
        guard !text.isEmpty, turnComplete else { return }

        if transcriptFinalized {
            // Trigger immediately on finalized transcript
            timeoutTask?.cancel()
            timeoutTask = nil
            await triggerUserTurnStopped()
            return
        }

        // Non-finalized: trigger once timeout task has completed (timeoutTask == nil)
        if timeoutTask == nil {
            await triggerUserTurnStopped()
        }
    }
}

// MARK: - AudioChunk Float32 Data helper

private extension AudioChunk {
    /// Convert Float32 samples into Int16 PCM bytes to match Pipecat's transport contract.
    func toInt16PCMData() -> Data {
        let samples = extractMonoSamples()
        let pcm = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            if clamped >= 1.0 {
                return Int16.max
            }
            if clamped <= -1.0 {
                return Int16.min
            }
            return Int16((clamped * Float(Int16.max)).rounded())
        }
        return pcm.withUnsafeBytes { Data($0) }
    }
}
