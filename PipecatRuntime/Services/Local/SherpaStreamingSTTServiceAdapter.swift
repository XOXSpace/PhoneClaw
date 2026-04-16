import Foundation

// Mirrors Pipecat streaming STT subclass pattern (e.g. DeepgramSTTService in
// services/deepgram/stt.py:283). Inherits the `STTService` base directly
// (NOT SegmentedSTTService) — because sherpa-onnx zipformer streaming model
// supports per-frame `acceptWaveform` + per-frame `getResult` for partial
// transcripts, matching the pipecat streaming STT contract.
//
// Source-iso boundary:
//   - Pipecat streaming STTService subclass overrides `process_audio_frame`
//     (or relies on base) and yields TranscriptionFrame as audio is fed.
//   - PhoneClaw equivalent: override `processAudioFrame` to feed each
//     incoming InputAudioRawFrame to ASRService.appendStreamingResult, push
//     `InterimTranscriptionFrame` (text=current partial, finalized=false)
//     when transcript text changes.
//   - On VADUserStoppedSpeakingFrame, finalize the streaming session
//     (ASRService.endStreamingResult) and push `TranscriptionFrame`
//     (text=final, finalized=true). Restart streaming session for next turn.
//
// Why not use `runSTT(audio:)` — that's the batch contract; streaming STT
// bypasses it entirely. The base class's `runSTT` fatalError default is
// never reached because we never call it.

final class SherpaStreamingSTTServiceAdapter: STTService, @unchecked Sendable {

    private let service: STTServicing
    /// De-dup partial pushes: only emit InterimTranscriptionFrame when text
    /// actually changes between consecutive `appendStreamingResult` calls.
    /// Mirrors how pipecat streaming STTs only emit transcript frames on
    /// content change rather than every audio frame.
    private var lastInterimText: String = ""

    init(service: STTServicing = ASRService()) {
        self.service = service
        super.init(
            name: "SherpaStreaming",
            audioPassthrough: true,
            // Streaming STT TTFB is ~per-frame decode time (~10-30ms on iPhone).
            ttfsP99Latency: 0.1,
            keepaliveTimeout: nil,
            language: .zhCN
        )
    }

    // MARK: - Lifecycle

    override func didReceiveStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await super.didReceiveStart(frame, direction: direction, context: context)
        if !service.isAvailable {
            service.initialize()
        }
        // Open initial streaming session.
        service.beginStreaming()
        lastInterimText = ""
    }

    override func didReceiveStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await super.didReceiveStop(frame, direction: direction, context: context)
        service.cancelStreaming()
        lastInterimText = ""
    }

    override func didReceiveCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await super.didReceiveCancel(frame, direction: direction, context: context)
        service.cancelStreaming()
        lastInterimText = ""
    }

    // MARK: - Per-frame audio processing (streaming hot path)

    override func processAudioFrame(
        _ frame: InputAudioRawFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await super.processAudioFrame(frame, direction: direction, context: context)
        if muted { return }

        let samples = frame.chunk.extractMonoSamples()
        guard !samples.isEmpty else { return }

        // Feed audio chunk to streaming recognizer.
        let result = service.appendStreamingResult(samples: samples, sampleRate: sampleRate)

        // Only emit interim frame when transcript text changes (de-dup).
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastInterimText else { return }
        lastInterimText = trimmed

        // Mirrors pipecat: streaming STT yields TranscriptionFrame with
        // `finalized=false` for partials. PhoneClaw uses the legacy
        // InterimTranscriptionFrame type for partial — the unified
        // TranscriptionFrame.finalized=false form would also work, but
        // existing aggregator path already handles InterimTranscriptionFrame.
        let interim = InterimTranscriptionFrame(text: trimmed, finalized: false)
        await context.push(interim, direction: .downstream)
    }

    // MARK: - VAD finalize

    override func handleVADUserStoppedSpeaking(
        _ frame: VADUserStoppedSpeakingFrame,
        context: FrameProcessorContext
    ) async {
        await super.handleVADUserStoppedSpeaking(frame, context: context)

        // Finalize current streaming session, get last partial as final.
        let final = service.endStreamingResult(sampleRate: sampleRate)
        let finalText = final.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if !finalText.isEmpty {
            print("[\(serviceName)] final transcript=\"\(finalText)\"")
            let transcription = TranscriptionFrame(text: finalText, finalized: true)
            await pushTranscript(transcription, direction: .downstream, context: context)
        } else {
            print("[\(serviceName)] VAD stop with empty transcript — skip")
        }

        // Reset for next utterance.
        lastInterimText = ""
        service.beginStreaming()
    }

    // MARK: - Interruption

    override func resetSTTTtfbState() async {
        await super.resetSTTTtfbState()
        // Clear streaming session — bot interruption means previous
        // partial is no longer relevant; user about to speak fresh.
        service.cancelStreaming()
        service.beginStreaming()
        lastInterimText = ""
    }

    // MARK: - Unused for streaming

    override func runSTT(audio: [Float]) async -> [Frame] {
        // Streaming STT does not use the batch run_stt contract.
        // Per-frame processing happens in `processAudioFrame` and finalize
        // in `handleVADUserStoppedSpeaking`. This override exists only to
        // satisfy the abstract method requirement from STTService base.
        return []
    }
}
