import Foundation

// Mirrors Pipecat `pipecat/services/stt_service.py:SegmentedSTTService`
// (line 596).
//
// STT service that processes speech in segments using VAD events. Used by
// batch STT backends (sherpa-onnx local, Fal cloud, Whisper batch, etc.)
// where the model expects a complete utterance rather than streaming frames.
//
// Key design (mirrors py:602-604):
//   "Maintains a small audio buffer to account for the delay between actual
//    speech start and VAD detection."
//
// Concretely:
//   - `processAudioFrame` continuously appends incoming audio to `audioBuffer`
//     regardless of VAD state.
//   - When user is NOT speaking, the buffer is trimmed to keep only the last
//     `audioBufferSize1s` samples (default 1 second). This is the pre-buffer
//     that captures the moment between actual speech start and the VAD event.
//   - When user starts speaking (VADUserStartedSpeakingFrame), nothing
//     special — buffer keeps growing.
//   - When user stops speaking (VADUserStoppedSpeakingFrame), the entire
//     buffer is fed to `runSTT(audio:)` and cleared.
//
// Subclasses implement only `runSTT(audio:)` — base handles all buffering
// and timing. TranscriptionFrames returned from runSTT are pushed downstream
// with `finalized=true` semantics (mirrors py:631-643).

class SegmentedSTTService: STTService, @unchecked Sendable {

    /// py:618. Continuous audio buffer (Float samples instead of pipecat's
    /// Int16 bytes — sherpa-onnx and friends consume Float directly, so we
    /// avoid the WAV byte round-trip pipecat needs for cloud HTTP uploads).
    private var audioBuffer: [Float] = []

    /// py:619. Number of samples to keep as pre-buffer when user is not
    /// speaking. Default = 1 second of audio at the configured sample rate.
    private var audioBufferSize1s: Int = 16000

    override init(
        name: String,
        audioPassthrough: Bool = true,
        sampleRate: Int? = nil,
        sttTtfbTimeout: TimeInterval = 2.0,
        ttfsP99Latency: Double = 1.5,
        keepaliveTimeout: TimeInterval? = nil,
        keepaliveInterval: TimeInterval = 5.0,
        language: Language? = nil
    ) {
        super.init(
            name: name,
            audioPassthrough: audioPassthrough,
            sampleRate: sampleRate,
            sttTtfbTimeout: sttTtfbTimeout,
            ttfsP99Latency: ttfsP99Latency,
            keepaliveTimeout: keepaliveTimeout,
            keepaliveInterval: keepaliveInterval,
            language: language
        )
    }

    // MARK: - Lifecycle (mirrors py:622)

    override func didReceiveStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await super.didReceiveStart(frame, direction: direction, context: context)
        // py:629. pipecat uses `sample_rate * 2` (bytes for Int16);
        // Swift uses `sampleRate` (count of Float samples = 1 second).
        audioBufferSize1s = sampleRate
    }

    override func didReceiveStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await super.didReceiveStop(frame, direction: direction, context: context)
        audioBuffer.removeAll(keepingCapacity: false)
    }

    override func didReceiveCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await super.didReceiveCancel(frame, direction: direction, context: context)
        audioBuffer.removeAll(keepingCapacity: false)
    }

    // MARK: - Audio buffering (mirrors py:674)

    override func processAudioFrame(
        _ frame: InputAudioRawFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await super.processAudioFrame(frame, direction: direction, context: context)
        if muted { return }

        let samples = frame.chunk.extractMonoSamples()
        guard !samples.isEmpty else { return }

        // py:694. Continuously buffer; userSpeaking just decides trimming.
        audioBuffer.append(contentsOf: samples)

        // py:697-699. When not speaking, keep only last `audioBufferSize1s` as pre-buffer.
        if !userSpeaking, audioBuffer.count > audioBufferSize1s {
            let discard = audioBuffer.count - audioBufferSize1s
            audioBuffer.removeFirst(discard)
        }
    }

    // MARK: - VAD handlers (mirrors py:654, 657)

    override func handleVADUserStartedSpeaking(
        _ frame: VADUserStartedSpeakingFrame,
        context: FrameProcessorContext
    ) async {
        await super.handleVADUserStartedSpeaking(frame, context: context)
        // py:654-655. Nothing else — the pre-buffer already in audioBuffer
        // captures the speech onset; new audio keeps appending.
        print("[\(serviceName)] VAD start (pre-buffer=\(audioBuffer.count) samples ≈ \(String(format: "%.2f", Double(audioBuffer.count) / Double(max(sampleRate, 1))))s)")
    }

    override func handleVADUserStoppedSpeaking(
        _ frame: VADUserStoppedSpeakingFrame,
        context: FrameProcessorContext
    ) async {
        await super.handleVADUserStoppedSpeaking(frame, context: context)

        // py:660-672. Snapshot buffer, clear, run STT on snapshot.
        let segment = audioBuffer
        audioBuffer.removeAll(keepingCapacity: true)

        guard !segment.isEmpty else {
            print("[\(serviceName)] VAD stop with empty buffer — skip")
            return
        }

        print("[\(serviceName)] VAD stop → runSTT samples=\(segment.count) ≈ \(String(format: "%.2f", Double(segment.count) / Double(max(sampleRate, 1))))s")

        // py:672. await self.process_generator(self.run_stt(content.read()))
        // Swift equivalent: await runSTT and push each returned frame.
        let frames = await runSTT(audio: segment)
        for frame in frames {
            if let transcription = frame as? TranscriptionFrame {
                // Mirrors py:631-643. SegmentedSTT always emits finalized
                // transcripts (one per segment).
                await pushTranscript(transcription, direction: .downstream, context: context)
            } else {
                await context.push(frame, direction: .downstream)
            }
        }
    }
}
