import Foundation

// MARK: - MockInputTransport
//
// Programmatic frame-injection input transport for headless CLI testing.
// Mirrors pipecat's `tests/utils.py::SinkTransport` + `HeadlessTransport` pattern:
// no microphone, no audio engine — the test driver enqueues scripted frames
// via `inject()` and the pipeline processes them as if they came from a real source.
//
// Lifecycle:
//   - PipelineTask.run() → StartFrame is routed downstream from this transport.
//     Routing through BaseTransport.didReceiveStart sets the internal injector.
//   - After `task.waitUntilRunning()`, callers can `inject(frame)` to push frames
//     downstream into the pipeline. Frames before that are dropped silently
//     (consistent with pipecat: emit before pipeline start is a no-op).
//
// Typical CLI usage:
//   let mock = MockInputTransport()
//   let pipeline = Pipeline([mock, aggregator, llm, output])
//   let task = PipelineTask(pipeline: pipeline)
//   Task { await task.run(with: mock.makeStartFrame()) }
//   await task.waitUntilRunning()
//   await mock.injectAsync(VADUserStartedSpeakingFrame())
//   await mock.injectAsync(TranscriptionFrame(text: "你好"))
//   await mock.injectAsync(VADUserStoppedSpeakingFrame())

final class MockInputTransport: BaseInputTransport, @unchecked Sendable {
    private let transportSource: String?

    init(transportSource: String? = "MockInputTransport") {
        self.transportSource = transportSource
        super.init(name: "MockInputTransport")
    }

    /// Convenience StartFrame builder mirroring IOSLiveInputTransport.makeStartFrame().
    /// Defaults match the iOS pipeline's input/output sample rates so downstream
    /// processors that read audioMetadata behave identically.
    func makeStartFrame(
        input: AudioFormatDescriptor = AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1),
        output: AudioFormatDescriptor = AudioFormatDescriptor(sampleRate: 22_050, channelCount: 1)
    ) -> StartFrame {
        StartFrame(audioMetadata: StartFrameAudioMetadata(input: input, output: output))
    }

    /// Push a frame downstream into the pipeline. No-op if called before the
    /// pipeline has started (mirrors BaseTransport.emit gating on injector).
    /// Use this for fire-and-forget injection from synchronous contexts.
    func inject(_ frame: Frame, direction: FrameDirection = .downstream) {
        stampTransportMetadata(frame, transportSource: transportSource)
        emit(frame, direction: direction)
    }

    /// Async variant — awaits until the frame has been queued downstream.
    /// Prefer this in test drivers so the next inject() observes the
    /// previous frame's effects.
    func injectAsync(_ frame: Frame, direction: FrameDirection = .downstream) async {
        stampTransportMetadata(frame, transportSource: transportSource)
        await emitAsync(frame, direction: direction)
    }

    /// Convenience: inject a sequence and await each in order.
    func injectAsync(_ frames: [Frame], direction: FrameDirection = .downstream) async {
        for frame in frames {
            await injectAsync(frame, direction: direction)
        }
    }
}
