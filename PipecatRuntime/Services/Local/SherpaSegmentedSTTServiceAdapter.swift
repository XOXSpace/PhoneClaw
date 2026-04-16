import Foundation

// Mirrors Pipecat `SegmentedSTTService` subclass pattern (e.g. FalSTTService
// in services/fal/stt.py:151). The base class handles all VAD-driven
// buffering, pre-buffer trimming, finalize semantics, mute, metadata, and
// settings. This adapter only implements the actual transcription call.
//
// Side-by-side with the legacy SherpaSTTServiceAdapter — both exist so
// PipecatLivePipeline can A/B test which one to wire in. Once verified,
// the legacy adapter (and the deprecated StartInterruption/StopInterruption
// streaming-mode contract) can be removed.

final class SherpaSegmentedSTTServiceAdapter: SegmentedSTTService, @unchecked Sendable {

    private let service: STTServicing

    init(service: STTServicing = ASRService()) {
        self.service = service
        super.init(
            name: "SherpaSegmented",
            audioPassthrough: true,
            sttTtfbTimeout: 2.0,
            // Measured P99 latency for sherpa-onnx zh-hans int8 batch
            // transcribe on iPhone — adjust if model changes.
            ttfsP99Latency: 0.8,
            keepaliveTimeout: nil,   // local model, no connection to keep alive
            language: .zhCN
        )
    }

    override func didReceiveStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await super.didReceiveStart(frame, direction: direction, context: context)
        if !service.isAvailable {
            service.initialize()
        }
    }

    /// Mirrors pipecat subclass `run_stt(audio: bytes)` (e.g.
    /// `services/fal/stt.py:297` `_transcribe`). PhoneClaw passes Float
    /// samples directly — sherpa-onnx Swift binding takes [Float], no need
    /// to round-trip through WAV bytes.
    override func runSTT(audio: [Float]) async -> [Frame] {
        let transcript = service.transcribe(samples: audio, sampleRate: sampleRate)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print("[\(serviceName)] transcript=\"\(transcript)\"")

        guard !transcript.isEmpty else { return [] }
        return [TranscriptionFrame(text: transcript)]
    }
}
