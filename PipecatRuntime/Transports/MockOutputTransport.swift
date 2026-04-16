import Foundation

// MARK: - MockOutputTransport
//
// Frame-capture output transport for headless CLI testing.
// Mirrors pipecat's `tests/utils.py::SinkTransport`: every frame the pipeline
// pushes downstream past this node is recorded for inspection. No audio
// playback, no side effects.
//
// Lifecycle:
//   - Receives all downstream frames after the LLM/TTS chain in the pipeline.
//   - Captures everything in `frames` (thread-safe), then forwards downstream
//     so PipelineTask still sees EndFrame/StopFrame/CancelFrame and unblocks
//     the run() continuation.
//
// Inspection helpers:
//   - capturedFrames           : every recorded frame in arrival order
//   - capturedFrames(of:)      : type-filtered slice
//   - clear()                  : drop captures (useful between scripted turns)

final class MockOutputTransport: BaseOutputTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Frame] = []
    private let onFrame: (@Sendable (Frame, FrameDirection) -> Void)?

    /// - Parameter onFrame: optional callback invoked synchronously for every
    ///   captured frame. Useful for live print-as-you-go logging in CLI runs.
    init(onFrame: (@Sendable (Frame, FrameDirection) -> Void)? = nil) {
        self.onFrame = onFrame
        super.init(name: "MockOutputTransport")
    }

    var capturedFrames: [Frame] {
        lock.withLock { Array(frames) }
    }

    func capturedFrames<T: Frame>(of type: T.Type) -> [T] {
        lock.withLock { frames.compactMap { $0 as? T } }
    }

    func clear() {
        lock.withLock { frames.removeAll(keepingCapacity: false) }
    }

    override func process(
        _ frame: Frame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        // Only capture downstream traffic — upstream broadcasts (e.g.
        // BotStartedSpeakingFrame siblings) would double-count otherwise.
        if direction == .downstream {
            lock.withLock { frames.append(frame) }
            onFrame?(frame, direction)
        }
        // Forward unconditionally so PipelineTask sees lifecycle frames at
        // the boundary (Start/Stop/Cancel/End).
        await super.process(frame, direction: direction, context: context)
    }
}
