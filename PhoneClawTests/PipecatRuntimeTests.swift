import AVFoundation
import FluidAudio
import MLXLMCommon
import XCTest
@testable import PhoneClaw

private final class RecordingProcessor: FrameProcessor, @unchecked Sendable {
    private let recorder: Recorder

    init(name: String, recorder: Recorder) {
        self.recorder = recorder
        super.init(name: name)
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        if let frame = frame as? TranscriptionFrame {
            await recorder.append("\(name):\(frame.text)")
        }
        await context.push(frame, direction: direction)
    }
}

private final class GateProcessor: FrameProcessor, @unchecked Sendable {
    private let recorder: Recorder
    private let firstFrameEntered: @Sendable () -> Void
    private let gate: Gate

    init(recorder: Recorder, firstFrameEntered: @escaping @Sendable () -> Void, gate: Gate) {
        self.recorder = recorder
        self.firstFrameEntered = firstFrameEntered
        self.gate = gate
        super.init(name: "GateProcessor")
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        switch frame {
        case let frame as TranscriptionFrame where frame.text == "first":
            await recorder.append("first-entered")
            firstFrameEntered()
            await gate.wait()
        case let frame as TranscriptionFrame:
            await recorder.append(frame.text)
        case is InterruptionFrame:
            await recorder.append("interruption")
        default:
            break
        }
    }
}

private final class SlowCancelableProcessor: FrameProcessor, @unchecked Sendable {
    private let recorder: Recorder

    init(recorder: Recorder) {
        self.recorder = recorder
        super.init(name: "SlowCancelableProcessor")
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        switch frame {
        case let frame as TranscriptionFrame where frame.text == "first":
            await recorder.append("first-entered")
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled {
                return
            }
            await recorder.append("first-finished")
        case let frame as TranscriptionFrame:
            await recorder.append(frame.text)
        case is InterruptionFrame:
            await recorder.append("interruption")
        default:
            break
        }

        if Task.isCancelled {
            return
        }

        await context.push(frame, direction: direction)
    }
}

private final class TaskFrameEmittingProcessor: FrameProcessor, @unchecked Sendable {
    private let emittedFrame: @Sendable () -> Frame
    private let emittedDirection: FrameDirection

    init(
        emittedDirection: FrameDirection,
        emittedFrame: @escaping @Sendable () -> Frame
    ) {
        self.emittedFrame = emittedFrame
        self.emittedDirection = emittedDirection
        super.init(name: "TaskFrameEmittingProcessor")
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        if frame is TranscriptionFrame {
            await context.push(emittedFrame(), direction: emittedDirection)
        }
        await context.push(frame, direction: direction)
    }
}

private final class LifecycleHookProcessor: FrameProcessor, @unchecked Sendable {
    private let recorder: Recorder

    init(recorder: Recorder) {
        self.recorder = recorder
        super.init(name: "LifecycleHookProcessor")
    }

    override func didReceiveStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await recorder.append("start")
    }

    override func didReceiveStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await recorder.append("stop")
    }

    override func didReceiveCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await recorder.append("cancel")
    }
}

private final class FrameNameRecordingProcessor: FrameProcessor, @unchecked Sendable {
    private let recorder: Recorder

    init(recorder: Recorder) {
        self.recorder = recorder
        super.init(name: "FrameNameRecordingProcessor")
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        switch frame {
        case is InputAudioRawFrame,
            is HeartbeatFrame,
            is BotSpeakingFrame,
            is VADUserStartedSpeakingFrame,
            is VADUserStoppedSpeakingFrame,
            is UserStartedSpeakingFrame,
            is UserStoppedSpeakingFrame,
            is UserSpeakingFrame,
            is UserTurnCommittedFrame,
            is BotStartedSpeakingFrame,
            is BotStoppedSpeakingFrame,
            is UserMuteStartedFrame,
            is UserMuteStoppedFrame,
            is LLMUpdateSettingsFrame,
            is TTSUpdateSettingsFrame,
            is STTUpdateSettingsFrame,
            is EndTaskFrame,
            is StopTaskFrame,
            is CancelTaskFrame,
            is InterruptionTaskFrame,
            is EndFrame,
            is StopFrame,
            is CancelFrame,
            is FrameProcessorPauseFrame,
            is FrameProcessorResumeFrame,
            is FrameProcessorPauseUrgentFrame,
            is FrameProcessorResumeUrgentFrame,
            is InterruptionFrame,
            is StartInterruptionFrame,
            is StopInterruptionFrame,
            is InterruptionCandidateFrame,
            is InterimTranscriptionFrame,
            is TranscriptionFrame:
            await recorder.append(frame.name)
        default:
            break
        }

        await context.push(frame, direction: direction)
    }
}

private final class TaggedFrameRecordingProcessor: FrameProcessor, @unchecked Sendable {
    private let recorder: Recorder
    private let tag: String

    init(tag: String, recorder: Recorder) {
        self.recorder = recorder
        self.tag = tag
        super.init(name: "TaggedFrameRecordingProcessor[\(tag)]")
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        switch frame {
        case let frame as InterruptionCandidateFrame:
            await recorder.append("\(tag):\(frame.name):\(frame.transcript):\(frame.unitCount)")
        case let frame as InterimTranscriptionFrame:
            await recorder.append("\(tag):\(frame.name):\(frame.text)")
        case let frame as TranscriptionFrame:
            await recorder.append("\(tag):\(frame.name):\(frame.text)")
        case is BotStartedSpeakingFrame,
            is BotStoppedSpeakingFrame,
            is UserStartedSpeakingFrame,
            is UserStoppedSpeakingFrame,
            is UserTurnCommittedFrame,
            is InterruptionFrame,
            is StartInterruptionFrame,
            is StopInterruptionFrame:
            await recorder.append("\(tag):\(frame.name)")
        default:
            break
        }

        await context.push(frame, direction: direction)
    }
}

private struct ContextSnapshot: Equatable {
    let direction: FrameDirection
    let messages: [LLMContextMessage]
}

private actor ContextRecorder {
    private var snapshots: [ContextSnapshot] = []

    func append(_ snapshot: ContextSnapshot) {
        snapshots.append(snapshot)
    }

    func snapshot() -> [ContextSnapshot] {
        snapshots
    }
}

private final class ContextFrameRecordingProcessor: FrameProcessor, @unchecked Sendable {
    private let recorder: ContextRecorder

    init(recorder: ContextRecorder) {
        self.recorder = recorder
        super.init(name: "ContextFrameRecordingProcessor")
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        if let frame = frame as? LLMContextFrame {
            await recorder.append(
                ContextSnapshot(
                    direction: direction,
                    messages: frame.context.messages
                )
            )
        }

        await context.push(frame, direction: direction)
    }
}

private final class SpeechControlRecordingProcessor: FrameProcessor, @unchecked Sendable {
    private let recorder: Recorder

    init(recorder: Recorder) {
        self.recorder = recorder
        super.init(name: "SpeechControlRecordingProcessor")
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        if let frame = frame as? SpeechControlParamsFrame, let params = frame.vadParams {
            await recorder.append(
                "speech-control:\(params.confidence):\(params.startSecs):\(params.stopSecs):\(params.minVolume)"
            )
        }

        await context.push(frame, direction: direction)
    }
}

private final class RecordingObserver: BaseObserver {
    private let recorder: Recorder

    init(recorder: Recorder) {
        self.recorder = recorder
    }

    func onProcessFrame(_ data: FrameProcessed) async {
        await recorder.append("process:\(data.processor.name):\(data.frame.name)")
    }

    func onPushFrame(_ data: FramePushed) async {
        await recorder.append("push:\(data.source.name)->\(data.destination.name):\(data.frame.name)")
    }

    func onPipelineStarted() async {
        await recorder.append("pipeline-started")
    }

    func onPipelineFinished(_ frame: Frame) async {
        await recorder.append("pipeline-finished:\(frame.name)")
    }
}

private final class BroadcastMetadataRecordingProcessor: FrameProcessor, @unchecked Sendable {
    private let recorder: Recorder
    private let tag: String

    init(tag: String, recorder: Recorder) {
        self.recorder = recorder
        self.tag = tag
        super.init(name: "BroadcastMetadataRecordingProcessor[\(tag)]")
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        switch frame {
        case is BotStartedSpeakingFrame,
            is BotSpeakingFrame,
            is BotStoppedSpeakingFrame,
            is VADUserStartedSpeakingFrame,
            is VADUserStoppedSpeakingFrame,
            is UserSpeakingFrame:
            await recorder.append(
                "\(tag):\(frame.name):\(frame.id.uuidString):\(frame.broadcastSiblingID?.uuidString ?? "nil"):\(frame.transportDestination ?? "nil")"
            )
        default:
            break
        }

        await context.push(frame, direction: direction)
    }
}

private final class TransportMetadataRecordingProcessor: FrameProcessor, @unchecked Sendable {
    private let recorder: Recorder

    init(recorder: Recorder) {
        self.recorder = recorder
        super.init(name: "TransportMetadataRecordingProcessor")
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        switch frame {
        case is InputAudioRawFrame, is TTSStartedFrame, is TTSAudioRawFrame, is TTSTextFrame, is TTSStoppedFrame:
            await recorder.append(
                "\(frame.name):src=\(frame.transportSource ?? "nil"):dst=\(frame.transportDestination ?? "nil")"
            )
        default:
            break
        }

        await context.push(frame, direction: direction)
    }
}

private final class LLMOutputRecordingProcessor: FrameProcessor, @unchecked Sendable {
    private let recorder: Recorder

    init(recorder: Recorder) {
        self.recorder = recorder
        super.init(name: "LLMOutputRecordingProcessor")
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        switch frame {
        case is LLMFullResponseStartFrame:
            await recorder.append("llm-start")
        case let frame as LLMTextFrame:
            await recorder.append("llm-text:\(frame.text):skip=\(frame.skipTTS == true)")
        case is LLMFullResponseEndFrame:
            await recorder.append("llm-end")
        case is TTSStartedFrame:
            await recorder.append("tts-start")
        case is TTSAudioRawFrame:
            await recorder.append("tts-audio")
        case let frame as TTSTextFrame:
            await recorder.append("tts-text:\(frame.text)")
        case is TTSStoppedFrame:
            await recorder.append("tts-stop")
        case let frame as LLMMessagesAppendFrame:
            let contents = frame.messages.compactMap(\.content).joined(separator: "|")
            await recorder.append("llm-append:\(contents)")
        case is LLMRunFrame:
            await recorder.append("llm-run")
        default:
            break
        }

        await context.push(frame, direction: direction)
    }
}

private final class StubVADService: VADService {
    var processedChunks: [[Float]] = []
    var stopListeningCallCount = 0

    override func initialize() async {}

    override func processChunk(_ chunk: [Float]) async {
        processedChunks.append(chunk)
        onSpeechStart?()
        onSpeechChunk?(chunk)
        onSpeechEnd?(chunk)
    }

    override func stopListening() {
        stopListeningCallCount += 1
        super.stopListening()
    }
}

private final class StreamingStubVADService: VADService {
    var processedChunks: [[Float]] = []
    private var hasStarted = false

    override func initialize() async {}

    override func processChunk(_ chunk: [Float]) async {
        processedChunks.append(chunk)
        if !hasStarted {
            hasStarted = true
            onSpeechStart?()
        }
        onSpeechChunk?(chunk)
    }

    func finishSpeaking() {
        guard hasStarted else { return }
        hasStarted = false
        onSpeechEnd?([])
    }
}

private final class StubSTTService: STTServicing {
    struct AppliedSettingsSnapshot: Equatable {
        let model: String?
        let language: String?
        let changedKeys: [String]
    }

    var isAvailable = true
    var transcribeResult = ""
    var streamingResults: [STTStreamingResult] = []
    var didBeginStreaming = false
    var didCancelStreaming = false
    var didEndStreaming = false
    var transcribeCallCount = 0
    private let lock = NSLock()
    private var appliedSettingsSnapshots: [AppliedSettingsSnapshot] = []

    func initialize() {}

    func transcribe(samples: [Float], sampleRate: Int) -> String {
        transcribeCallCount += 1
        return transcribeResult
    }

    func beginStreaming() {
        didBeginStreaming = true
    }

    func appendStreamingResult(samples: [Float], sampleRate: Int) -> STTStreamingResult {
        if !streamingResults.isEmpty {
            return streamingResults.removeFirst()
        }
        return .empty
    }

    func endStreamingResult(sampleRate: Int) -> STTStreamingResult {
        didEndStreaming = true
        if !streamingResults.isEmpty {
            return streamingResults.removeFirst()
        }
        return .empty
    }

    func cancelStreaming() {
        didCancelStreaming = true
    }

    func applyRuntimeSettings(_ settings: STTSettings, changed: [String: Any]) async {
        let snapshot = AppliedSettingsSnapshot(
            model: settings.resolvedModel,
            language: settings.resolvedLanguage,
            changedKeys: changed.keys.sorted()
        )
        lock.withLock {
            appliedSettingsSnapshots.append(snapshot)
        }
    }

    func appliedSettings() -> [AppliedSettingsSnapshot] {
        lock.withLock { appliedSettingsSnapshots }
    }
}

private final class StubLLMService: LocalLLMServicing {
    var isLoaded = true
    var streamedTokens: [String] = []
    var loadCallCount = 0
    var warmupCallCount = 0
    var cancelCallCount = 0
    private(set) var generatedChats: [[String]] = []

    func load() async throws {
        loadCallCount += 1
        isLoaded = true
    }

    func warmup() async throws {
        warmupCallCount += 1
    }

    func generateStream(
        chat: [Chat.Message],
        additionalContext: LLMAdditionalContext?
    ) -> AsyncThrowingStream<String, Error> {
        generatedChats.append(chat.map { "\($0.role.rawValue):\($0.content)" })
        let tokens = streamedTokens

        return AsyncThrowingStream { continuation in
            Task {
                for token in tokens {
                    continuation.yield(token)
                }
                continuation.finish()
            }
        }
    }

    func cancel() {
        cancelCallCount += 1
    }
}

private final class StubTTSService: TTSServicing {
    struct AppliedSettingsSnapshot: Equatable {
        let model: String?
        let voice: String?
        let language: String?
        let changedKeys: [String]
    }

    var isAvailable = true
    private(set) var initializeCallCount = 0
    private let lock = NSLock()
    private var synthesizedTexts: [String] = []
    private var appliedSettingsSnapshots: [AppliedSettingsSnapshot] = []
    private let makeChunk: () -> AudioChunk

    init(makeChunk: @escaping () -> AudioChunk) {
        self.makeChunk = makeChunk
    }

    func initialize() async {
        initializeCallCount += 1
    }

    func synthesizeChunk(_ text: String) -> AudioChunk? {
        lock.withLock {
            synthesizedTexts.append(text)
        }
        return makeChunk()
    }

    func applyRuntimeSettings(_ settings: TTSSettings, changed: [String: Any]) async {
        let snapshot = AppliedSettingsSnapshot(
            model: settings.resolvedModel,
            voice: settings.resolvedVoice,
            language: settings.resolvedLanguage,
            changedKeys: changed.keys.sorted()
        )
        lock.withLock {
            appliedSettingsSnapshots.append(snapshot)
        }
    }

    func snapshot() -> [String] {
        lock.withLock { synthesizedTexts }
    }

    func appliedSettings() -> [AppliedSettingsSnapshot] {
        lock.withLock { appliedSettingsSnapshots }
    }
}

private final class StubLiveAudioIO: LiveAudioIO {
    private(set) var stopPlaybackCallCount = 0

    override func playBuffer(_ buffer: AVAudioPCMBuffer) async {}

    override func stopPlayback() {
        stopPlaybackCallCount += 1
        onPlaybackStopped?()
    }
}

private actor Recorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }

    func clear() {
        events.removeAll(keepingCapacity: true)
    }
}

private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private final class ManualSleeper: @unchecked Sendable, Sleeper, UserIdleSleeper {
    private struct Waiter {
        var id = 0
        var deadline: TimeInterval = 0
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var nextID = 0
    private var waiters: [Waiter] = []

    var waiterCount: Int {
        lock.withLock { waiters.count }
    }

    func sleep(for duration: TimeInterval) async throws {
        var generatedID = 0
        var computedDeadline: TimeInterval = 0
        lock.withLock {
            generatedID = nextID
            nextID += 1
            computedDeadline = now + duration
        }
        let waiterID = generatedID
        let deadline = computedDeadline
        var readyContinuation: CheckedContinuation<Void, Error>?

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if deadline <= now {
                        readyContinuation = continuation
                    } else {
                        waiters.append(Waiter(id: waiterID, deadline: deadline, continuation: continuation))
                    }
                }
            }
            readyContinuation?.resume()
        } onCancel: {
            var continuation: CheckedContinuation<Void, Error>?
            lock.withLock {
                if let index = waiters.firstIndex(where: { $0.id == waiterID }) {
                    continuation = waiters.remove(at: index).continuation
                }
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by delta: TimeInterval) {
        var due: [CheckedContinuation<Void, Error>] = []
        lock.withLock {
            now += delta
            var remaining: [Waiter] = []
            for waiter in waiters {
                if waiter.deadline <= now {
                    due.append(waiter.continuation)
                } else {
                    remaining.append(waiter)
                }
            }
            waiters = remaining
        }
        due.forEach { $0.resume() }
    }
}

/// Stub analyzer that always returns `.complete` with probability 0.95.
/// Used to test the SmartTurn "complete → direct commit" path
/// without depending on real ML inference or audio content.
private final class StubCompleteTurnAnalyzer: BaseTurnAnalyzerProtocol {
    var sampleRate: Int = 16000

    func setSampleRate(_ rate: Int) { sampleRate = rate }
    func appendAudio(_ audio: Data, isSpeech: Bool) -> EndOfTurnState { .complete }
    func analyzeEndOfTurn() async -> (EndOfTurnState, TurnMetricsData?) {
        (.complete, TurnMetricsData(isComplete: true, probability: 0.95, e2eProcessingTimeMs: 1.0))
    }
    func updateVADStartSecs(_ secs: Float) {}
    func clear() {}
    func cleanup() async {}
}

/// Stub analyzer that always returns `.incomplete` with probability 0.1.
/// Used to test the strategy's incomplete → hold branch.
private final class StubIncompleteTurnAnalyzer: BaseTurnAnalyzerProtocol {
    var sampleRate: Int = 16000

    func setSampleRate(_ rate: Int) { sampleRate = rate }
    func appendAudio(_ audio: Data, isSpeech: Bool) -> EndOfTurnState { .incomplete }
    func analyzeEndOfTurn() async -> (EndOfTurnState, TurnMetricsData?) {
        (.incomplete, TurnMetricsData(isComplete: false, probability: 0.1, e2eProcessingTimeMs: 1.0))
    }
    func updateVADStartSecs(_ secs: Float) {}
    func clear() {}
    func cleanup() async {}
}

final class PipecatRuntimeTests: XCTestCase {
    func testPipelineRoutesDownstreamThroughProcessorsInOrder() async throws {
        let recorder = Recorder()
        let pipeline = Pipeline([
            RecordingProcessor(name: "p1", recorder: recorder),
            RecordingProcessor(name: "p2", recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(TranscriptionFrame(text: "hello"))
        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.count == 2 ? snapshot : nil
        }

        XCTAssertEqual(events, ["p1:hello", "p2:hello"])
    }

    func testPipelineStartedObserverFiresAfterStartFrameReachesSink() async throws {
        let recorder = Recorder()
        let observer = RecordingObserver(recorder: recorder)
        let task = PipelineTask(
            pipeline: Pipeline([FrameProcessor(name: "passthrough")]),
            observers: [observer]
        )

        await task.start()

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.contains("pipeline-started") ? snapshot : nil
        }

        XCTAssertEqual(events, ["process:passthrough:StartFrame", "pipeline-started"])
    }

    func testPushObserverSeesProcessorToProcessorTransfer() async throws {
        let recorder = Recorder()
        let observer = RecordingObserver(recorder: recorder)
        let task = PipelineTask(
            pipeline: Pipeline([
                FrameProcessor(name: "p1"),
                FrameProcessor(name: "p2")
            ]),
            observers: [observer]
        )

        await task.start()
        await recorder.clear()
        await task.enqueue(TranscriptionFrame(text: "hello"))

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.contains("push:p1->p2:TranscriptionFrame") ? snapshot : nil
        }

        XCTAssertTrue(events.contains("process:p1:TranscriptionFrame"))
        XCTAssertTrue(events.contains("push:p1->p2:TranscriptionFrame"))
        XCTAssertTrue(events.contains("process:p2:TranscriptionFrame"))
    }

    func testPipelineTaskEmitsHeartbeatsWhenEnabled() async throws {
        let recorder = Recorder()
        let task = PipelineTask(
            pipeline: Pipeline([FrameNameRecordingProcessor(recorder: recorder)]),
            params: PipelineTaskParams(
                enableHeartbeats: true,
                heartbeatsPeriodSecs: 0.05,
                heartbeatsMonitorSecs: 0.2,
                idleTimeoutSecs: nil
            )
        )

        await task.start()

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.contains("HeartbeatFrame") ? snapshot : nil
        }

        XCTAssertTrue(events.contains("HeartbeatFrame"))
        await task.stop()
    }

    func testPipelineTaskCancelsOnIdleTimeout() async throws {
        let recorder = Recorder()
        let observer = RecordingObserver(recorder: recorder)
        let task = PipelineTask(
            pipeline: Pipeline([FrameProcessor(name: "passthrough")]),
            params: PipelineTaskParams(
                idleTimeoutSecs: 0.05,
                cancelOnIdleTimeout: true
            ),
            observers: [observer]
        )
        await task.setOnIdleTimeout {
            await recorder.append("idle-timeout")
        }

        await task.start()
        try? await Task.sleep(nanoseconds: 500_000_000)
        let events = await recorder.snapshot()
        XCTAssertTrue(events.contains("idle-timeout"))
        var state = await task.state
        for _ in 0..<200 where state != .stopped {
            try? await Task.sleep(nanoseconds: 10_000_000)
            state = await task.state
        }
        XCTAssertEqual(state, .stopped)
    }

    func testPipelineTaskFatalErrorCancelsPipeline() async throws {
        let recorder = Recorder()
        let observer = RecordingObserver(recorder: recorder)
        let task = PipelineTask(
            pipeline: Pipeline([
                TaskFrameEmittingProcessor(
                    emittedDirection: .upstream,
                    emittedFrame: { ErrorFrame(message: "fatal", fatal: true) }
                ),
                FrameNameRecordingProcessor(recorder: recorder)
            ]),
            observers: [observer]
        )
        await task.setOnPipelineError { frame in
            await recorder.append("error:\(frame.message):fatal=\(frame.fatal)")
        }

        await task.start()
        await task.enqueue(TranscriptionFrame(text: "trigger"))

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.contains("pipeline-finished:CancelFrame") ? snapshot : nil
        }

        XCTAssertTrue(events.contains("error:fatal:fatal=true"))
        XCTAssertTrue(events.contains("CancelFrame"))
        XCTAssertTrue(events.contains("pipeline-finished:CancelFrame"))
        let finished = await task.hasFinished
        XCTAssertTrue(finished)
    }

    func testPipelineTaskStopWhenDoneEndsWithEndFrame() async throws {
        let recorder = Recorder()
        let observer = RecordingObserver(recorder: recorder)
        let task = PipelineTask(
            pipeline: Pipeline([FrameNameRecordingProcessor(recorder: recorder)]),
            observers: [observer]
        )

        await task.start()
        await task.stopWhenDone(reason: "done")

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.contains("pipeline-finished:EndFrame") ? snapshot : nil
        }

        XCTAssertTrue(events.contains("EndFrame"))
        XCTAssertTrue(events.contains("pipeline-finished:EndFrame"))
        let finished = await task.hasFinished
        XCTAssertTrue(finished)
    }

    func testPipelineTaskAddReachedDownstreamFilterTriggersHandler() async throws {
        let recorder = Recorder()
        let task = PipelineTask(
            pipeline: Pipeline([FrameNameRecordingProcessor(recorder: recorder)])
        )

        await task.addReachedDownstreamFilter([TranscriptionFrame.self])
        await task.setOnFrameReachedDownstream { frame in
            await recorder.append("reached-downstream:\(frame.name)")
        }

        await task.start()
        await task.enqueue(TranscriptionFrame(text: "hello"))

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.contains("reached-downstream:TranscriptionFrame") ? snapshot : nil
        }

        XCTAssertTrue(events.contains("reached-downstream:TranscriptionFrame"))
    }

    func testInterruptionDropsQueuedInterruptibleFramesFromProcessorBacklog() async throws {
        let recorder = Recorder()
        let pipeline = Pipeline([
            SlowCancelableProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(TranscriptionFrame(text: "first"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        await task.enqueue(TranscriptionFrame(text: "second"))
        await task.enqueue(InterruptionFrame())

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            let required = ["first-entered", "interruption"]
            return required.allSatisfy(snapshot.contains) ? snapshot : nil
        }

        XCTAssertTrue(events.contains("first-entered"))
        XCTAssertTrue(events.contains("interruption"))
        XCTAssertFalse(events.contains("second"))
    }

    func testUrgentPauseAndResumeFramesGateProcessorBacklog() async throws {
        let recorder = Recorder()
        let processor = FrameNameRecordingProcessor(recorder: recorder)
        let task = PipelineTask(pipeline: Pipeline([processor]))

        await task.start()
        await task.enqueue(FrameProcessorPauseUrgentFrame(processor: processor))
        await task.enqueue(TranscriptionFrame(text: "hello"))

        try? await Task.sleep(nanoseconds: 50_000_000)
        let pausedSnapshot = await recorder.snapshot()
        XCTAssertFalse(pausedSnapshot.contains("TranscriptionFrame"))

        await task.enqueue(FrameProcessorResumeUrgentFrame(processor: processor))

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.contains("TranscriptionFrame") ? snapshot : nil
        }

        XCTAssertTrue(events.contains("FrameProcessorPauseUrgentFrame"))
        XCTAssertTrue(events.contains("FrameProcessorResumeUrgentFrame"))
        XCTAssertTrue(events.contains("TranscriptionFrame"))
    }

    func testLiveStateObserverMapsStreamingFramesIntoObservableState() async throws {
        typealias StateSnapshot = (
            stage: LiveSessionState.Stage,
            isUserSpeaking: Bool,
            isBotSpeaking: Bool,
            interimTranscript: String,
            transcript: String,
            assistantReply: String,
            caption: String,
            lastFrameName: String
        )

        let state = await MainActor.run { LiveSessionState() }
        let observer = await MainActor.run { LiveStateObserver(state: state) }
        let pipeline = Pipeline([FrameProcessor(name: "passthrough")])
        let task = PipelineTask(pipeline: pipeline, observers: [observer])

        await task.start()
        await task.enqueue(UserStartedSpeakingFrame())
        await task.enqueue(InterimTranscriptionFrame(text: "你好"))
        await task.enqueue(TranscriptionFrame(text: "你好世界"))
        await task.enqueue(LLMFullResponseStartFrame())
        await task.enqueue(LLMTextFrame(text: "✓", skipTTS: true))
        await task.enqueue(LLMTextFrame(text: "早上好"))
        await task.enqueue(BotStartedSpeakingFrame())
        await task.enqueue(BotStoppedSpeakingFrame())
        await task.stop()

        let snapshot: StateSnapshot = try await eventually {
            await MainActor.run { () -> StateSnapshot? in
                guard state.assistantReply == "早上好",
                      state.transcript == "你好世界",
                      state.caption == "早上好",
                      state.lastFrameName == "StopFrame"
                else {
                    return nil
                }
                return (
                    state.stage,
                    state.isUserSpeaking,
                    state.isBotSpeaking,
                    state.interimTranscript,
                    state.transcript,
                    state.assistantReply,
                    state.caption,
                    state.lastFrameName
                )
            }
        }

        XCTAssertEqual(snapshot.stage, .idle)
        XCTAssertFalse(snapshot.isUserSpeaking)
        XCTAssertFalse(snapshot.isBotSpeaking)
        XCTAssertEqual(snapshot.interimTranscript, "")
        XCTAssertEqual(snapshot.transcript, "你好世界")
        XCTAssertEqual(snapshot.assistantReply, "早上好")
        XCTAssertEqual(snapshot.caption, "早上好")
        XCTAssertEqual(snapshot.lastFrameName, "StopFrame")
    }

    func testFrameProcessorLifecycleHooksFireForControlFrames() async throws {
        let stopRecorder = Recorder()
        let stopTask = PipelineTask(pipeline: Pipeline([LifecycleHookProcessor(recorder: stopRecorder)]))

        await stopTask.start()
        await stopTask.stop()

        let stopEvents = try await eventually {
            let snapshot = await stopRecorder.snapshot()
            return snapshot.count >= 2 ? snapshot : nil
        }

        XCTAssertEqual(Array(stopEvents.prefix(2)), ["start", "stop"])

        let cancelRecorder = Recorder()
        let cancelTask = PipelineTask(pipeline: Pipeline([LifecycleHookProcessor(recorder: cancelRecorder)]))

        await cancelTask.start()
        await cancelTask.cancel()

        let cancelEvents = try await eventually {
            let snapshot = await cancelRecorder.snapshot()
            return snapshot.count >= 2 ? snapshot : nil
        }

        XCTAssertEqual(Array(cancelEvents.prefix(2)), ["start", "cancel"])
    }

    func testUpstreamEndTaskFrameBecomesDownstreamEndFrame() async throws {
        let recorder = Recorder()
        let pipeline = Pipeline([
            TaskFrameEmittingProcessor(
                emittedDirection: .upstream,
                emittedFrame: { EndTaskFrame(reason: "finished") }
            ),
            FrameNameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(TranscriptionFrame(text: "trigger"))

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.contains("EndFrame") ? snapshot : nil
        }

        XCTAssertTrue(events.contains("EndFrame"))
        XCTAssertFalse(events.contains("EndTaskFrame"))
    }

    func testDownstreamStopTaskFrameLoopsUpstreamThenBecomesStopFrame() async throws {
        let recorder = Recorder()
        let pipeline = Pipeline([
            FrameNameRecordingProcessor(recorder: recorder),
            TaskFrameEmittingProcessor(
                emittedDirection: .downstream,
                emittedFrame: { StopTaskFrame() }
            ),
            FrameNameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(TranscriptionFrame(text: "trigger"))

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.contains("StopFrame") ? snapshot : nil
        }

        XCTAssertTrue(events.contains("StopTaskFrame"))
        XCTAssertTrue(events.contains("StopFrame"))
        XCTAssertLessThan(
            events.firstIndex(of: "StopTaskFrame") ?? .max,
            events.firstIndex(of: "StopFrame") ?? .max
        )
    }

    func testIOSLiveInputTransportInjectsAudioFramesIntoPipeline() async throws {
        let recorder = Recorder()
        let transport = IOSLiveInputTransport(
            audioIO: LiveAudioIO(),
            autoManageEngine: false,
            transportSource: "mic-main"
        )
        let pipeline = Pipeline([
            transport,
            FrameNameRecordingProcessor(recorder: recorder),
            TransportMetadataRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        let startFrame = transport.makeStartFrame()
        XCTAssertEqual(startFrame.audioMetadata?.input, AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1))
        XCTAssertEqual(startFrame.audioMetadata?.output, AudioFormatDescriptor(sampleRate: 22_050, channelCount: 1))

        await task.start(with: startFrame)
        transport.ingestAudioBuffer(makeMonoBuffer(frameCount: 160), time: nil)

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            let required = [
                "InputAudioRawFrame",
                "InputAudioRawFrame:src=mic-main:dst=nil"
            ]
            return required.allSatisfy(snapshot.contains) ? snapshot : nil
        }

        XCTAssertTrue(events.contains("InputAudioRawFrame"))
        XCTAssertTrue(events.contains("InputAudioRawFrame:src=mic-main:dst=nil"))
    }

    func testBotSpeechGateConvertsSpeechStartIntoInterruptionCandidateWhileBotSpeaking() async throws {
        let recorder = Recorder()
        let pipeline = Pipeline([
            BotSpeechGateProcessor(),
            FrameNameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(BotStartedSpeakingFrame())
        await task.enqueue(InputAudioRawFrame(chunk: AudioChunk(buffer: makeMonoBuffer(frameCount: 160))))
        await task.enqueue(VADUserStartedSpeakingFrame())
        await task.enqueue(VADUserStoppedSpeakingFrame())
        await task.enqueue(BotStoppedSpeakingFrame())
        await task.enqueue(VADUserStartedSpeakingFrame())

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.count >= 6 ? snapshot : nil
        }

        // BotSpeechGateProcessor converts VAD frames to Start/StopInterruptionFrame while bot speaking.
        // It does NOT emit InterruptionCandidateFrame (that's SherpaSTTServiceAdapter's job).
        XCTAssertEqual(
            Array(events.prefix(6)),
            [
                "BotStartedSpeakingFrame",
                "InputAudioRawFrame",
                "StartInterruptionFrame",
                "StopInterruptionFrame",
                "BotStoppedSpeakingFrame",
                "VADUserStartedSpeakingFrame"
            ]
        )
    }

    func testVADProcessorEmitsUserSpeakingFramesWithoutBlockingAudioFrame() async throws {
        let recorder = Recorder()
        let stubService = StreamingStubVADService()
        let pipeline = Pipeline([
            VADProcessor(service: stubService),
            FrameNameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(InputAudioRawFrame(chunk: AudioChunk(buffer: makeMonoBuffer(frameCount: VadManager.chunkSize))))
        _ = await waitForRecorder(recorder) { snapshot in
            snapshot.contains("UserSpeakingFrame")
        }

        stubService.finishSpeaking()
        await task.stop()

        let events = await waitForRecorder(recorder) { snapshot in
            snapshot.contains("VADUserStoppedSpeakingFrame") && snapshot.contains("StopFrame")
        }

        XCTAssertEqual(Array(events.prefix(4)), [
            "InputAudioRawFrame",
            "VADUserStartedSpeakingFrame",
            "UserSpeakingFrame",
            "VADUserStoppedSpeakingFrame"
        ])
        XCTAssertEqual(stubService.processedChunks.count, 1)
    }

    func testVADProcessorEmitsUserSpeakingFramePerSpeechChunkLikePipecatSource() async throws {
        let recorder = Recorder()
        let stubService = StreamingStubVADService()
        let pipeline = Pipeline([
            VADProcessor(service: stubService, speechActivityPeriod: 0.2),
            FrameNameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(
            InputAudioRawFrame(chunk: AudioChunk(buffer: makeMonoBuffer(frameCount: VadManager.chunkSize)))
        )
        _ = await waitForRecorder(recorder) { snapshot in
            snapshot.filter { $0 == "UserSpeakingFrame" }.count == 1
        }
        await task.enqueue(
            InputAudioRawFrame(chunk: AudioChunk(buffer: makeMonoBuffer(frameCount: VadManager.chunkSize)))
        )
        _ = await waitForRecorder(recorder) { snapshot in
            snapshot.filter { $0 == "UserSpeakingFrame" }.count == 2
        }
        stubService.finishSpeaking()

        let events = await waitForRecorder(recorder) { snapshot in
            snapshot.contains("VADUserStoppedSpeakingFrame")
        }

        XCTAssertEqual(events.filter { $0 == "InputAudioRawFrame" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "VADUserStartedSpeakingFrame" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "UserSpeakingFrame" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "VADUserStoppedSpeakingFrame" }.count, 1)
    }

    func testIOSLiveOutputTransportBroadcastsBotSpeakingFramesBothDirections() async throws {
        let recorder = Recorder()
        let audioIO = StubLiveAudioIO()
        let outputTransport = IOSLiveOutputTransport(
            audioIO: audioIO,
            botSpeakingFramePeriod: 0,
            transportDestination: "speaker-main"
        )
        let pipeline = Pipeline([
            BroadcastMetadataRecordingProcessor(tag: "upstream", recorder: recorder),
            outputTransport,
            BroadcastMetadataRecordingProcessor(tag: "downstream", recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(
            TTSAudioRawFrame(
                chunk: AudioChunk(buffer: makeMonoBuffer(frameCount: 160)),
                contextID: "ctx-1"
            )
        )
        await task.enqueue(TTSStoppedFrame(contextID: "ctx-1"))

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.count >= 6 ? snapshot : nil
        }

        assertBroadcastPair(named: "BotStartedSpeakingFrame", in: events, expectedDestination: "speaker-main")
        assertBroadcastPair(named: "BotSpeakingFrame", in: events, expectedDestination: "speaker-main")
        assertBroadcastPair(named: "BotStoppedSpeakingFrame", in: events, expectedDestination: "speaker-main")
    }

    func testVADProcessorBroadcastsVADFramesBothDirections() async throws {
        let recorder = Recorder()
        let stubService = StubVADService()
        let pipeline = Pipeline([
            BroadcastMetadataRecordingProcessor(tag: "upstream", recorder: recorder),
            VADProcessor(service: stubService),
            BroadcastMetadataRecordingProcessor(tag: "downstream", recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(
            InputAudioRawFrame(
                chunk: AudioChunk(buffer: makeMonoBuffer(frameCount: VadManager.chunkSize))
            )
        )
        await task.stop()

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.count >= 6 ? snapshot : nil
        }

        // Broadcast events arrive in non-deterministic order across Tasks.
        // Group by frame name and validate each pair.
        let parsed = events.map { $0.split(separator: ":").map(String.init) }

        func assertPair(_ frameName: String) {
            let pair = parsed.filter { $0[1] == frameName }
            XCTAssertEqual(pair.count, 2, "Expected 2 events for \(frameName), got \(pair.count)")
            guard pair.count == 2 else { return }
            XCTAssertEqual(Set(pair.map { $0[0] }), Set(["downstream", "upstream"]),
                           "\(frameName) should appear in both directions")
            XCTAssertNotEqual(pair[0][2], pair[1][2],
                              "\(frameName) broadcast siblings should have different IDs")
            XCTAssertEqual(pair[0][3], pair[1][2],
                           "\(frameName) broadcastSiblingID cross-link broken (0→1)")
            XCTAssertEqual(pair[1][3], pair[0][2],
                           "\(frameName) broadcastSiblingID cross-link broken (1→0)")
        }

        assertPair("VADUserStartedSpeakingFrame")
        assertPair("UserSpeakingFrame")
        assertPair("VADUserStoppedSpeakingFrame")
    }

    func testVADProcessorBroadcastsSpeechControlParamsOnStartAndUpdate() async throws {
        let recorder = Recorder()
        let stubService = StubVADService()
        let pipeline = Pipeline([
            VADProcessor(service: stubService),
            SpeechControlRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(
            VADParamsUpdateFrame(
                params: VADParams(
                    confidence: 0.9,
                    startSecs: 0.3,
                    stopSecs: 1.25,
                    minVolume: 0.4
                )
            )
        )

        let events = await waitForRecorder(recorder) { snapshot in
            snapshot.count >= 2
        }

        XCTAssertEqual(events[0], "speech-control:0.7:0.2:0.2:0.6")
        XCTAssertEqual(events[1], "speech-control:0.9:0.3:1.25:0.4")
        XCTAssertEqual(stubService.liveConfig.minSilenceDuration, 1.25)
    }

    func testVADProcessorForcesSpeechStopWhenAudioGoesIdle() async throws {
        let recorder = Recorder()
        let stubService = StreamingStubVADService()
        let pipeline = Pipeline([
            VADProcessor(service: stubService, audioIdleTimeout: 0.05),
            FrameNameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(
            InputAudioRawFrame(chunk: AudioChunk(buffer: makeMonoBuffer(frameCount: VadManager.chunkSize)))
        )

        _ = await waitForRecorder(recorder) { snapshot in
            snapshot.contains("UserSpeakingFrame")
        }

        let events = await waitForRecorder(
            recorder,
            timeoutNanoseconds: 500_000_000
        ) { snapshot in
            snapshot.contains("VADUserStoppedSpeakingFrame")
        }

        XCTAssertEqual(Array(events.prefix(4)), [
            "InputAudioRawFrame",
            "VADUserStartedSpeakingFrame",
            "UserSpeakingFrame",
            "VADUserStoppedSpeakingFrame"
        ])

        await task.cancel()
    }

    func testUserTurnControllerCommitsOnUserTurnStopped() async throws {
        // Use SpeechTimeoutUserTurnStopStrategy (not SmartTurn) so tests can run
        // without the .onnx model resource in the test bundle.
        let recorder = Recorder()
        let stopStrategy = SpeechTimeoutUserTurnStopStrategy()
        stopStrategy.userSpeechTimeout = 0.05  // fast for test
        let strategies = UserTurnStrategies(
            start: UserTurnStrategies.defaultStart(),
            stop: [stopStrategy]
        )
        let controller = UserTurnController(strategies: strategies)
        let processor = UserTurnProcessor(controller: controller)
        let pipeline = Pipeline([
            processor,
            FrameNameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(VADUserStartedSpeakingFrame())
        await task.enqueue(TranscriptionFrame(text: "你好"))
        await task.enqueue(VADUserStoppedSpeakingFrame())

        // SpeechTimeoutUserTurnStopStrategy fires after 0.05s silence → commit
        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.contains("UserTurnCommittedFrame") ? snapshot : nil
        }

        XCTAssertTrue(events.contains("VADUserStartedSpeakingFrame"))
        XCTAssertTrue(events.contains("UserStartedSpeakingFrame"))
        XCTAssertTrue(events.contains("VADUserStoppedSpeakingFrame"))
        XCTAssertTrue(events.contains("UserStoppedSpeakingFrame"))
        XCTAssertTrue(events.contains("UserTurnCommittedFrame"))
    }

    func testUserTurnProcessorEmitsIdleAfterBotStopsSpeaking() async throws {
        let idleRecorder = Recorder()
        let sleeper = ManualSleeper()
        let processor = UserTurnProcessor(
            userIdleController: UserIdleController(
                userIdleTimeout: 0.2,
                sleeper: sleeper
            )
        )
        processor.onUserTurnIdle = {
            await idleRecorder.append("idle")
        }
        let pipeline = Pipeline([
            processor,
            FrameProcessor(name: "passthrough")
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(BotStoppedSpeakingFrame())
        try await waitForWaiters(1, on: sleeper)
        sleeper.advance(by: 0.21)

        let events = try await eventually {
            let snapshot = await idleRecorder.snapshot()
            return snapshot.count == 1 ? snapshot : nil
        }

        XCTAssertEqual(events, ["idle"])
    }

    func testInterruptionFrameRoutingThroughSTTAdapter() async throws {
        // Simplified: test that StartInterruptionFrame → STT streaming → StopInterruptionFrame
        // produces the expected frame sequence. Strategy-driven controller handles turn commit.
        let recorder = Recorder()
        let stopStrategy = SpeechTimeoutUserTurnStopStrategy()
        stopStrategy.userSpeechTimeout = 0.05
        let strategies = UserTurnStrategies(
            start: UserTurnStrategies.defaultStart(),
            stop: [stopStrategy]
        )
        let controller = UserTurnController(strategies: strategies)
        let processor = UserTurnProcessor(controller: controller)

        let stt = StubSTTService()
        stt.streamingResults = [
            STTStreamingResult(text: "你好啊", unitCount: 3),
            STTStreamingResult(text: "你好啊", unitCount: 3)
        ]
        stt.transcribeResult = "你好啊"

        let pipeline = Pipeline([
            TaggedFrameRecordingProcessor(tag: "upstream", recorder: recorder),
            processor,
            SherpaSTTServiceAdapter(service: stt),
            TaggedFrameRecordingProcessor(tag: "downstream", recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(StartInterruptionFrame())
        await task.enqueue(InputAudioRawFrame(chunk: AudioChunk(buffer: makeMonoBuffer(frameCount: 160))))
        await task.enqueue(StopInterruptionFrame())

        // StopInterruptionFrame triggers emitInterruptionUpdates (InterimTranscriptionFrame),
        // NOT handleCommittedTurn (TranscriptionFrame). Final transcription only happens
        // when UserTurnCommittedFrame arrives.
        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.contains("downstream:InterimTranscriptionFrame:你好啊") ? snapshot : nil
        }

        XCTAssertTrue(events.contains("downstream:InterimTranscriptionFrame:你好啊"))
        XCTAssertTrue(stt.didBeginStreaming)
        XCTAssertTrue(stt.didEndStreaming)
        // StopInterruption does streaming endStreamingResult, NOT batch transcribe
        XCTAssertEqual(stt.transcribeCallCount, 0)
    }

    func testLLMUserAggregatorPushesContextFrameAfterCommittedTurn() async throws {
        let recorder = ContextRecorder()
        let sharedContext = LLMContext()
        // Explicit non-SmartTurn strategies to avoid LocalSmartTurnAnalyzer fatalError
        // when .onnx resource is not in test bundle.
        let controller = UserTurnController(
            strategies: UserTurnStrategies(
                start: UserTurnStrategies.defaultStart(),
                stop: [SpeechTimeoutUserTurnStopStrategy()]
            )
        )
        let pipeline = Pipeline([
            LLMUserAggregator(context: sharedContext, turnController: controller),
            ContextFrameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        // Current LLMUserAggregator: aggregation is triggered by internal onUserTurnStopped
        // callback, not by external UserTurnCommittedFrame. Must feed VAD flow:
        await task.enqueue(VADUserStartedSpeakingFrame())
        await task.enqueue(TranscriptionFrame(text: "你好"))
        await task.enqueue(VADUserStoppedSpeakingFrame())

        // SpeechTimeoutUserTurnStopStrategy fires → onUserTurnStopped → maybePushAggregation
        let snapshot = try await eventually {
            let frames = await recorder.snapshot()
            return frames.count == 1 ? frames[0] : nil
        }

        XCTAssertEqual(snapshot.direction, .downstream)
        XCTAssertEqual(
            snapshot.messages,
            [
                LLMContextMessage(
                    role: .user,
                    content: "你好"
                )
            ]
        )
        XCTAssertEqual(sharedContext.messages, snapshot.messages)
    }

    func testLLMUserAggregatorCommitsAfterInternalTurnStop() async throws {
        // Explicit SpeechTimeoutUserTurnStopStrategy (non-default, resource-independent).
        // Default SmartTurn path tests will be added after .onnx enters Copy Bundle Resources.
        // We feed VAD start → transcription → VAD stop → UserTurnCommitted
        // and verify context message is pushed.
        let recorder = ContextRecorder()
        let sharedContext = LLMContext()
        let stopStrategy = SpeechTimeoutUserTurnStopStrategy()
        stopStrategy.userSpeechTimeout = 0.05
        let controller = UserTurnController(
            strategies: UserTurnStrategies(
                start: UserTurnStrategies.defaultStart(),
                stop: [stopStrategy]
            ),
            userTurnStopTimeout: 0.1
        )

        let pipeline = Pipeline([
            LLMUserAggregator(
                context: sharedContext,
                turnController: controller
            ),
            ContextFrameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(VADUserStartedSpeakingFrame())
        await task.enqueue(TranscriptionFrame(text: "你好"))
        await task.enqueue(VADUserStoppedSpeakingFrame())

        // With short stopTimeout, the controller will commit after timeout elapses
        let snapshot = try await eventually {
            let frames = await recorder.snapshot()
            return frames.count == 1 ? frames[0] : nil
        }

        XCTAssertEqual(snapshot.direction, .downstream)
        XCTAssertEqual(
            snapshot.messages,
            [
                LLMContextMessage(
                    role: .user,
                    content: "你好"
                )
            ]
        )
        XCTAssertEqual(sharedContext.messages, snapshot.messages)
    }

    func testLLMUserAggregatorEmitsIdleAfterBotStopsSpeaking() async throws {
        let idleRecorder = Recorder()
        let sleeper = ManualSleeper()
        let aggregator = LLMUserAggregator(
            context: LLMContext(),
            turnController: UserTurnController(
                strategies: UserTurnStrategies(
                    start: UserTurnStrategies.defaultStart(),
                    stop: [SpeechTimeoutUserTurnStopStrategy()]
                )
            ),
            userIdleController: UserIdleController(
                userIdleTimeout: 0.2,
                sleeper: sleeper
            )
        )
        aggregator.onUserTurnIdle = {
            await idleRecorder.append("idle")
        }

        let pipeline = Pipeline([
            aggregator,
            FrameProcessor(name: "passthrough")
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(BotStoppedSpeakingFrame())
        try await waitForWaiters(1, on: sleeper)
        sleeper.advance(by: 0.21)

        let events = try await eventually {
            let snapshot = await idleRecorder.snapshot()
            return snapshot.count == 1 ? snapshot : nil
        }

        XCTAssertEqual(events, ["idle"])
    }

    func testLLMUserAggregatorSuppressesUserFramesWhileMuted() async throws {
        let recorder = Recorder()
        let aggregator = LLMUserAggregator(
            params: LLMUserAggregatorParams(
                userMuteStrategies: [AlwaysUserMuteStrategy()]
            ),
            turnController: UserTurnController(
                strategies: UserTurnStrategies(
                    start: UserTurnStrategies.defaultStart(),
                    stop: [SpeechTimeoutUserTurnStopStrategy()]
                )
            )
        )
        let pipeline = Pipeline([
            aggregator,
            FrameNameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        // Current LLMUserAggregator: VAD frames route to turn controller, not pushed downstream.
        // During bot speaking, VADUserStarted triggers turn start → UserStartedSpeakingFrame + InterruptionFrame.
        // After bot stops, next VADUserStarted also triggers turn start.
        await task.enqueue(BotStartedSpeakingFrame())
        await task.enqueue(VADUserStartedSpeakingFrame())
        await task.enqueue(BotStoppedSpeakingFrame())

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            let required: [String] = [
                "BotStartedSpeakingFrame",
                "BotStoppedSpeakingFrame",
            ]
            return required.allSatisfy(snapshot.contains) ? snapshot : nil
        }

        // VADUserStartedSpeakingFrame during bot speech is consumed by turn controller,
        // not passed downstream, so it should NOT appear in recorder.
        // BotStarted/BotStopped pass through normally.
        XCTAssertTrue(events.contains("BotStartedSpeakingFrame"))
        XCTAssertTrue(events.contains("BotStoppedSpeakingFrame"))
    }

    func testLLMUserAggregatorEmitsLLMUpdateSettingsFrameOnStartWhenFilteringEnabled() async throws {
        let recorder = Recorder()
        let pipeline = Pipeline([
            LLMUserAggregator(
                params: LLMUserAggregatorParams(
                    filterIncompleteUserTurns: true
                ),
                turnController: UserTurnController(
                    strategies: UserTurnStrategies(
                        start: UserTurnStrategies.defaultStart(),
                        stop: [SpeechTimeoutUserTurnStopStrategy()]
                    )
                )
            ),
            FrameNameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.contains("LLMUpdateSettingsFrame") ? snapshot : nil
        }

        XCTAssertTrue(events.contains("LLMUpdateSettingsFrame"))
    }

    func testLLMSettingsApplyUpdateOnlyChangesGivenFields() {
        let store = LLMSettings.defaultStore()
        store.systemInstruction = .value("base prompt")

        let delta = LLMSettings(filterIncompleteUserTurns: true)
        let changed = store.applyUpdate(delta)

        XCTAssertEqual(Set(changed.keys), ["filter_incomplete_user_turns"])
        XCTAssertEqual(store.resolvedSystemInstruction, "base prompt")
        XCTAssertTrue(store.resolvedFilterIncompleteUserTurns)
    }

    func testLLMSettingsFromMappingBuildsSparseDeltaAndKeepsExtra() {
        let delta = LLMSettings.fromMapping([
            "filter_incomplete_user_turns": true,
            "user_turn_completion_config": [
                "incomplete_short_timeout": 1.5,
                "incomplete_short_prompt": "✓ Continue."
            ],
            "custom_flag": 7
        ])

        XCTAssertTrue(delta.filterIncompleteUserTurns.isGiven)
        XCTAssertTrue(delta.userTurnCompletionConfig.isGiven)
        XCTAssertFalse(delta.systemInstruction.isGiven)
        XCTAssertEqual(delta.extra["custom_flag"] as? Int, 7)
        XCTAssertTrue(delta.resolvedFilterIncompleteUserTurns)
        XCTAssertEqual(delta.resolvedUserTurnCompletionConfig?.incompleteShortTimeout, 1.5)
        XCTAssertEqual(delta.resolvedUserTurnCompletionConfig?.shortPrompt, "✓ Continue.")
    }

    func testTTSSettingsFromMappingSupportsVoiceIDAlias() {
        let delta = TTSSettings.fromMapping([
            "voice_id": "keqing",
            "language": "zh-CN"
        ])

        XCTAssertEqual(delta.resolvedVoice, "keqing")
        XCTAssertEqual(delta.resolvedLanguage, "zh-CN")
        XCTAssertFalse(delta.model.isGiven)
    }

    func testSTTSettingsApplyUpdateOnlyChangesGivenFields() {
        let store = STTSettings.defaultStore()
        store.model = .value("base-model")

        let delta = STTSettings(language: "zh-CN")
        let changed = store.applyUpdate(delta)

        XCTAssertEqual(Set(changed.keys), ["language"])
        XCTAssertEqual(store.resolvedModel, "base-model")
        XCTAssertEqual(store.resolvedLanguage, "zh-CN")
    }

    func testLLMAssistantAggregatorCommitsAfterLLMResponseEndAndPushesContextFrame() async throws {
        let context = LLMContext()
        let recorder = ContextRecorder()
        let pipeline = Pipeline([
            LLMAssistantAggregator(context: context),
            ContextFrameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(LLMFullResponseStartFrame())
        await task.enqueue(TTSTextFrame(text: "早上好"))
        await task.enqueue(LLMFullResponseEndFrame())

        let messages = try await eventually {
            let snapshot = context.messages
            return snapshot.count == 1 ? snapshot : nil
        }
        let contextFrame = try await eventually {
            let frames = await recorder.snapshot()
            return frames.count == 1 ? frames[0] : nil
        }

        XCTAssertEqual(
            messages,
            [
                LLMContextMessage(
                    role: .assistant,
                    content: "早上好"
                )
            ]
        )
        XCTAssertEqual(contextFrame.direction, .downstream)
        XCTAssertEqual(contextFrame.messages, messages)
    }

    func testLLMAssistantAggregatorCommitsSkipTTSMarkerToContext() async throws {
        let context = LLMContext()
        let pipeline = Pipeline([
            LLMAssistantAggregator(context: context)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(LLMFullResponseStartFrame())
        await task.enqueue(LLMTextFrame(text: "✓", skipTTS: true))
        await task.enqueue(TTSTextFrame(text: "早上好"))
        await task.enqueue(LLMFullResponseEndFrame())

        let messages = try await eventually {
            let snapshot = context.messages
            return snapshot.count == 1 ? snapshot : nil
        }

        XCTAssertEqual(
            messages,
            [
                LLMContextMessage(
                    role: .assistant,
                    content: "✓ 早上好"
                )
            ]
        )
    }

    func testLLMAssistantPushAggregationFrameCommitsStandaloneTTSText() async throws {
        let recorder = ContextRecorder()
        let context = LLMContext()
        let pipeline = Pipeline([
            LLMAssistantAggregator(context: context),
            ContextFrameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(TTSTextFrame(text: "独立播报"))
        await task.enqueue(LLMAssistantPushAggregationFrame())

        let messages = try await eventually {
            let snapshot = context.messages
            return snapshot.count == 1 ? snapshot : nil
        }
        let contextFrame = try await eventually {
            let frames = await recorder.snapshot()
            return frames.count == 1 ? frames[0] : nil
        }

        XCTAssertEqual(
            messages,
            [
                LLMContextMessage(
                    role: .assistant,
                    content: "独立播报"
                )
            ]
        )
        XCTAssertEqual(contextFrame.direction, .downstream)
        XCTAssertEqual(contextFrame.messages, messages)
    }

    func testLLMAssistantAggregatorDefersFunctionResultContextPushUntilBotStops() async throws {
        let recorder = ContextRecorder()
        let context = LLMContext()
        let pipeline = Pipeline([
            ContextFrameRecordingProcessor(recorder: recorder),
            LLMAssistantAggregator(context: context)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(BotStartedSpeakingFrame())
        await task.enqueue(
            FunctionCallInProgressFrame(
                callID: "call-1",
                payload: FunctionCallPayload(name: "weather", arguments: "{\"city\":\"上海\"}")
            )
        )
        await task.enqueue(
            FunctionCallResultFrame(
                callID: "call-1",
                result: "{\"forecast\":\"晴\"}",
                runLLM: true
            )
        )

        try? await Task.sleep(nanoseconds: 50_000_000)
        let framesBeforeBotStopped = await recorder.snapshot()
        XCTAssertTrue(framesBeforeBotStopped.isEmpty)

        await task.enqueue(BotStoppedSpeakingFrame())

        let snapshot = try await eventually {
            let frames = await recorder.snapshot()
            return frames.count == 1 ? frames[0] : nil
        }

        XCTAssertEqual(snapshot.direction, .upstream)
        XCTAssertEqual(snapshot.messages.count, 2)
        XCTAssertEqual(snapshot.messages[0].role, .assistant)
        XCTAssertEqual(
            snapshot.messages[0].toolCalls,
            [
                LLMToolCall(
                    id: "call-1",
                    name: "weather",
                    arguments: "{\"city\":\"上海\"}"
                )
            ]
        )
        XCTAssertEqual(
            snapshot.messages[1],
            LLMContextMessage(
                role: .tool,
                content: "{\"forecast\":\"晴\"}",
                toolCallID: "call-1"
            )
        )
    }

    func testMLXLLMServiceAdapterSanitizesAndStreamsCompleteResponse() async throws {
        let recorder = Recorder()
        let llm = StubLLMService()
        llm.isLoaded = false
        llm.streamedTokens = [
            "✓ model\n你好",
            "<tool_call>{\"name\":\"ignored\"}</tool_call>",
            "，世界。"
        ]

        let context = LLMContext()
        context.addMessage(LLMContextMessage(role: .system, content: "你是语音助手"))
        context.addMessage(LLMContextMessage(role: .user, content: "你好"))

        let pipeline = Pipeline([
            MLXLLMServiceAdapter(service: llm, warmupOnFirstLoad: true),
            LLMOutputRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(
            LLMUpdateSettingsFrame(
                delta: LLMSettings(filterIncompleteUserTurns: true)
            )
        )
        await task.enqueue(LLMContextFrame(context: context))

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.count == 5 ? snapshot : nil
        }

        XCTAssertEqual(events, [
            "llm-start",
            "llm-text:✓:skip=true",
            "llm-text:你好:skip=false",
            "llm-text:，世界。:skip=false",
            "llm-end"
        ])
        XCTAssertEqual(llm.loadCallCount, 1)
        XCTAssertEqual(llm.warmupCallCount, 1)
        XCTAssertEqual(llm.generatedChats.first?.count, 2)
        XCTAssertTrue(
            llm.generatedChats.first?[0]
                .hasPrefix("system:你是语音助手\n\nCRITICAL INSTRUCTION - MANDATORY RESPONSE FORMAT:") == true
        )
        XCTAssertEqual(llm.generatedChats.first?[1], "user:你好")
    }

    func testMLXLLMServiceAdapterSuppressesIncompleteTurnOutput() async throws {
        let recorder = Recorder()
        let llm = StubLLMService()
        llm.streamedTokens = ["○"]

        let context = LLMContext()
        context.addMessage(LLMContextMessage(role: .user, content: "继续"))

        let pipeline = Pipeline([
            MLXLLMServiceAdapter(service: llm),
            LLMOutputRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(
            LLMUpdateSettingsFrame(
                delta: LLMSettings(filterIncompleteUserTurns: true)
            )
        )
        await task.enqueue(LLMContextFrame(context: context))

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.count == 3 ? snapshot : nil
        }

        XCTAssertEqual(events, [
            "llm-start",
            "llm-text:○:skip=true",
            "llm-end"
        ])
        // startGeneration() calls cancelGeneration() first, so cancel fires once per generation.
        XCTAssertEqual(llm.cancelCallCount, 1)
    }

    func testMLXLLMServiceAdapterSchedulesIncompleteTimeoutFollowUp() async throws {
        let recorder = Recorder()
        let sleeper = ManualSleeper()
        let llm = StubLLMService()
        llm.streamedTokens = ["○"]

        let context = LLMContext()
        context.addMessage(LLMContextMessage(role: .user, content: "继续"))

        let pipeline = Pipeline([
            MLXLLMServiceAdapter(service: llm, sleeper: sleeper),
            LLMOutputRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(
            LLMUpdateSettingsFrame(
                delta: LLMSettings(
                    filterIncompleteUserTurns: true,
                    userTurnCompletionConfig: UserTurnCompletionConfig(
                        incompleteShortTimeout: 0.2,
                        incompleteShortPrompt: "✓ Go ahead, I'm listening."
                    )
                )
            )
        )
        await task.enqueue(LLMContextFrame(context: context))
        try await waitForWaiters(1, on: sleeper)
        sleeper.advance(by: 0.21)

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            let required = [
                "llm-start",
                "llm-text:○:skip=true",
                "llm-end",
                "llm-append:✓ Go ahead, I'm listening.",
                "llm-run"
            ]
            return required.allSatisfy(snapshot.contains) ? snapshot : nil
        }

        XCTAssertTrue(events.contains("llm-append:✓ Go ahead, I'm listening."))
        XCTAssertTrue(events.contains("llm-run"))
    }

    func testSherpaTTSServiceAdapterSynthesizesSentenceSegmentsInOrder() async throws {
        let recorder = Recorder()
        let tts = StubTTSService {
            AudioChunk(buffer: self.makeMonoBuffer(frameCount: 160, sampleRate: 22_050))
        }
        let pipeline = Pipeline([
            SherpaTTSServiceAdapter(service: tts, transportDestination: "speaker-main"),
            LLMOutputRecordingProcessor(recorder: recorder),
            TransportMetadataRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(LLMFullResponseStartFrame())
        await task.enqueue(LLMTextFrame(text: "✓", skipTTS: true))
        await task.enqueue(LLMTextFrame(text: "你好，"))
        await task.enqueue(LLMTextFrame(text: "世界。今天天气"))
        await task.enqueue(LLMTextFrame(text: "不错。"))
        await task.enqueue(LLMFullResponseEndFrame())

        let synthesized = try await eventually {
            let snapshot = tts.snapshot()
            return snapshot.count == 2 ? snapshot : nil
        }
        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            let audioCount = snapshot.filter { $0 == "tts-audio" }.count
            let startCount = snapshot.filter { $0 == "tts-start" }.count
            let stopCount = snapshot.filter { $0 == "tts-stop" }.count
            let textCount = snapshot.filter { $0.hasPrefix("tts-text:") }.count
            let metadataCount = snapshot.filter { $0.contains(":src=nil:dst=speaker-main") }.count
            return audioCount == 2 && startCount == 2 && stopCount == 2 && textCount == 2 && metadataCount == 8
                ? snapshot
                : nil
        }

        XCTAssertEqual(synthesized, [
            "你好，世界。",
            "今天天气不错。"
        ])
        XCTAssertEqual(events.filter { $0 == "tts-audio" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "tts-start" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "tts-stop" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "TTSStartedFrame:src=nil:dst=speaker-main" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "TTSAudioRawFrame:src=nil:dst=speaker-main" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "TTSTextFrame:src=nil:dst=speaker-main" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "TTSStoppedFrame:src=nil:dst=speaker-main" }.count, 2)
        XCTAssertTrue(events.contains("tts-text:你好，世界。"))
        XCTAssertTrue(events.contains("tts-text:今天天气不错。"))
        XCTAssertTrue(events.contains("llm-text:✓:skip=true"))
    }

    func testSherpaTTSServiceAdapterConsumesTargetedSettingsUpdateAndAppliesStore() async throws {
        let recorder = Recorder()
        let tts = StubTTSService {
            AudioChunk(buffer: self.makeMonoBuffer(frameCount: 160, sampleRate: 22_050))
        }
        let adapter = SherpaTTSServiceAdapter(service: tts)
        let pipeline = Pipeline([
            adapter,
            FrameNameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(
            TTSUpdateSettingsFrame(
                settings: [
                    "voice_id": "keqing",
                    "language": "zh-CN"
                ],
                service: adapter
            )
        )

        let snapshots = try await eventually {
            let values = tts.appliedSettings()
            return values.count == 1 ? values : nil
        }
        let events = await recorder.snapshot()

        XCTAssertEqual(
            snapshots,
            [
                StubTTSService.AppliedSettingsSnapshot(
                    model: nil,
                    voice: "keqing",
                    language: "zh-CN",
                    changedKeys: ["language", "voice"]
                )
            ]
        )
        XCTAssertFalse(events.contains("TTSUpdateSettingsFrame"))
    }

    func testSherpaSTTServiceAdapterForwardsNonTargetedSettingsUpdate() async throws {
        let recorder = Recorder()
        let stt = StubSTTService()
        let adapter = SherpaSTTServiceAdapter(service: stt)
        let other = FrameProcessor(name: "other")
        let pipeline = Pipeline([
            adapter,
            FrameNameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(
            STTUpdateSettingsFrame(
                delta: STTSettings(language: "zh-CN"),
                service: other
            )
        )

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.contains("STTUpdateSettingsFrame") ? snapshot : nil
        }

        XCTAssertTrue(events.contains("STTUpdateSettingsFrame"))
        XCTAssertTrue(stt.appliedSettings().isEmpty)
    }

    func testIOSLiveOutputTransportStopsPlaybackOnInterruption() async throws {
        let audioIO = StubLiveAudioIO()
        let outputTransport = IOSLiveOutputTransport(audioIO: audioIO)
        let task = PipelineTask(pipeline: Pipeline([outputTransport]))

        await task.start()
        await task.enqueue(InterruptionFrame())

        _ = try await eventually {
            audioIO.stopPlaybackCallCount == 1 ? true : nil
        }
    }

    private struct EventuallyTimeoutError: Error, CustomStringConvertible {
        let file: StaticString
        let line: UInt
        var description: String { "eventually() timed out at \(file):\(line)" }
    }

    private func eventually<T>(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: @escaping @Sendable () async -> T?
    ) async throws -> T {
        let deadline = ContinuousClock.now + .nanoseconds(timeoutNanoseconds)
        while ContinuousClock.now < deadline {
            if let value = await body() {
                return value
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        // One final attempt after timeout
        if let value = await body() {
            return value
        }
        // Throwing lets XCTest record a clean failure without crashing the runner
        throw EventuallyTimeoutError(file: file, line: line)
    }

    private func waitForRecorder(
        _ recorder: Recorder,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        _ predicate: @escaping @Sendable ([String]) -> Bool
    ) async -> [String] {
        let deadline = ContinuousClock.now + .nanoseconds(timeoutNanoseconds)
        var lastSnapshot: [String] = []

        while ContinuousClock.now < deadline {
            let snapshot = await recorder.snapshot()
            lastSnapshot = snapshot
            if predicate(snapshot) {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Recorder condition was not satisfied before timeout. Last snapshot: \(lastSnapshot)")
        return lastSnapshot
    }

    private func waitForWaiters(
        _ expectedCount: Int,
        on sleeper: ManualSleeper,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if sleeper.waiterCount >= expectedCount {
                return
            }
            await Task.yield()
        }

        XCTFail(
            "Expected at least \(expectedCount) pending sleeper waiters, got \(sleeper.waiterCount)",
            file: file,
            line: line
        )
    }

    private func makeMonoBuffer(frameCount: Int, sampleRate: Double = 16_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        )!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channel = buffer.floatChannelData![0]
        for index in 0..<frameCount {
            channel[index] = Float(index % 8) / 8.0
        }
        return buffer
    }

    private func assertBroadcastPair(
        named frameName: String,
        in events: [String],
        expectedDestination: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matching = events
            .filter { $0.contains(":\(frameName):") }
            .map { $0.split(separator: ":").map(String.init) }

        XCTAssertEqual(matching.count, 2, file: file, line: line)
        XCTAssertEqual(Set(matching.map { $0[0] }), Set(["upstream", "downstream"]), file: file, line: line)
        XCTAssertEqual(Set(matching.map { $0[1] }), Set([frameName]), file: file, line: line)

        guard
            let upstream = matching.first(where: { $0[0] == "upstream" }),
            let downstream = matching.first(where: { $0[0] == "downstream" })
        else {
            XCTFail("Missing upstream/downstream pair for \(frameName)", file: file, line: line)
            return
        }

        XCTAssertNotEqual(upstream[2], downstream[2], file: file, line: line)
        XCTAssertEqual(upstream[3], downstream[2], file: file, line: line)
        XCTAssertEqual(downstream[3], upstream[2], file: file, line: line)
        if let expectedDestination {
            XCTAssertEqual(upstream[4], expectedDestination, file: file, line: line)
            XCTAssertEqual(downstream[4], expectedDestination, file: file, line: line)
        }
    }

    // MARK: - SmartTurn Default Path Tests
    // These tests exercise the default TurnAnalyzerUserTurnStopStrategy(LocalSmartTurnAnalyzer())
    // with the real .onnx model resource in Copy Bundle Resources.

    func testLocalSmartTurnAnalyzerInitializesFromBundle() async throws {
        let analyzer = LocalSmartTurnAnalyzer()
        analyzer.setSampleRate(16000)
        await analyzer.cleanup()
    }

    func testLocalSmartTurnAnalyzerPredictEndpointReturnsValidProbability() async throws {
        let analyzer = LocalSmartTurnAnalyzer()
        analyzer.setSampleRate(16000)
        let silentSamples = [Float](repeating: 0.0, count: 32000)
        let result = analyzer.predictEndpoint(silentSamples)
        XCTAssertTrue(result.probability >= 0.0 && result.probability <= 1.0,
                      "probability \(result.probability) out of [0,1] range")
        XCTAssertTrue(result.prediction == 0 || result.prediction == 1,
                      "prediction must be 0 or 1, got \(result.prediction)")
        await analyzer.cleanup()
    }

    func testStubIncompleteHoldsTurnOpen() async throws {
        // Strategy-layer test: when analyzer returns .incomplete, commit is BLOCKED.
        // Uses StubIncompleteTurnAnalyzer + long fallback to prove the hold behavior.
        // (The real v3.2 model returns complete on almost any input, so this test
        //  uses a stub to cover the incomplete branch of the strategy.)
        let recorder = Recorder()
        let stubAnalyzer = StubIncompleteTurnAnalyzer()
        let controller = UserTurnController(
            strategies: UserTurnStrategies(
                start: UserTurnStrategies.defaultStart(),
                stop: [TurnAnalyzerUserTurnStopStrategy(turnAnalyzer: stubAnalyzer)]
            ),
            userTurnStopTimeout: 30.0  // effectively infinite
        )
        let processor = UserTurnProcessor(controller: controller)
        let pipeline = Pipeline([
            processor,
            FrameNameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(VADUserStartedSpeakingFrame())
        for _ in 0..<5 {
            await task.enqueue(
                InputAudioRawFrame(chunk: AudioChunk(buffer: makeMonoBuffer(frameCount: 160)))
            )
        }
        await task.enqueue(TranscriptionFrame(text: "你好"))
        await task.enqueue(VADUserStoppedSpeakingFrame())

        try? await Task.sleep(nanoseconds: 300_000_000)
        let events = await recorder.snapshot()

        XCTAssertTrue(events.contains("UserStartedSpeakingFrame"))
        XCTAssertFalse(events.contains("UserTurnCommittedFrame"),
                       "Incomplete analyzer should hold turn open")
        await task.cancel()
    }

    func testStubCompleteTriggersDirectCommit() async throws {
        // Strategy-layer test: when analyzer returns .complete, commit fires immediately
        // WITHOUT waiting for controller fallback.
        let recorder = Recorder()
        let stubAnalyzer = StubCompleteTurnAnalyzer()
        let controller = UserTurnController(
            strategies: UserTurnStrategies(
                start: UserTurnStrategies.defaultStart(),
                stop: [TurnAnalyzerUserTurnStopStrategy(turnAnalyzer: stubAnalyzer)]
            ),
            userTurnStopTimeout: 30.0
        )
        let processor = UserTurnProcessor(controller: controller)
        let pipeline = Pipeline([
            processor,
            FrameNameRecordingProcessor(recorder: recorder)
        ])
        let task = PipelineTask(pipeline: pipeline)

        await task.start()
        await task.enqueue(VADUserStartedSpeakingFrame())
        for _ in 0..<3 {
            await task.enqueue(
                InputAudioRawFrame(chunk: AudioChunk(buffer: makeMonoBuffer(frameCount: 160)))
            )
        }
        await task.enqueue(TranscriptionFrame(text: "你好"))
        await task.enqueue(VADUserStoppedSpeakingFrame())

        let events = try await eventually {
            let snapshot = await recorder.snapshot()
            return snapshot.contains("UserTurnCommittedFrame") ? snapshot : nil
        }

        XCTAssertTrue(events.contains("UserStartedSpeakingFrame"))
        XCTAssertTrue(events.contains("UserTurnCommittedFrame"),
                      "Complete analyzer should directly trigger commit without waiting for fallback")
    }
}
