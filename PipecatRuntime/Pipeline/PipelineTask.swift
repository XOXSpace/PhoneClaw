import Foundation

struct PipelineTaskParams {
    let enableHeartbeats: Bool
    let heartbeatsPeriodSecs: TimeInterval
    let heartbeatsMonitorSecs: TimeInterval
    let idleTimeoutSecs: TimeInterval?
    let cancelOnIdleTimeout: Bool
    let idleTimeoutFrames: [Frame.Type]
    let reachedUpstreamTypes: [Frame.Type]
    let reachedDownstreamTypes: [Frame.Type]

    init(
        enableHeartbeats: Bool = false,
        heartbeatsPeriodSecs: TimeInterval = 1.0,
        heartbeatsMonitorSecs: TimeInterval = 10.0,
        idleTimeoutSecs: TimeInterval? = 300.0,
        cancelOnIdleTimeout: Bool = true,
        idleTimeoutFrames: [Frame.Type] = [BotSpeakingFrame.self, UserSpeakingFrame.self],
        reachedUpstreamTypes: [Frame.Type] = [],
        reachedDownstreamTypes: [Frame.Type] = []
    ) {
        self.enableHeartbeats = enableHeartbeats
        self.heartbeatsPeriodSecs = heartbeatsPeriodSecs
        self.heartbeatsMonitorSecs = heartbeatsMonitorSecs
        self.idleTimeoutSecs = idleTimeoutSecs
        self.cancelOnIdleTimeout = cancelOnIdleTimeout
        self.idleTimeoutFrames = idleTimeoutFrames
        self.reachedUpstreamTypes = reachedUpstreamTypes
        self.reachedDownstreamTypes = reachedDownstreamTypes
    }
}

actor PipelineTask {
    typealias FrameHandler = @Sendable (Frame) async -> Void
    typealias IdleTimeoutHandler = @Sendable () async -> Void
    typealias ErrorHandler = @Sendable (ErrorFrame) async -> Void

    enum State: Sendable {
        case idle
        case starting
        case running
        case stopped
    }

    private let pipeline: Pipeline
    private let params: PipelineTaskParams
    private var observers: [BaseObserver]
    private var runtimePrepared = false
    private var finished = false
    private var pipelineStarted = false
    private var cancellationRequested = false
    private var pipelineStartWaiters: [CheckedContinuation<Void, Never>] = []
    // Mirrors Pipecat _pipeline_finished_event: unblocks run() after EndFrame/StopFrame/CancelFrame.
    private var pipelineFinishedWaiters: [CheckedContinuation<Void, Never>] = []
    private var runtimeCleanupTask: Task<Void, Never>?
    private var heartbeatPushTask: Task<Void, Never>?
    private var heartbeatMonitorTask: Task<Void, Never>?
    private var idleMonitorTask: Task<Void, Never>?
    private var lastProcessedHeartbeatAt: UInt64 = 0
    private var lastIdleActivityAt: UInt64 = 0
    private var reachedUpstreamTypes: [Frame.Type]
    private var reachedDownstreamTypes: [Frame.Type]

    private var onFrameReachedUpstreamHandler: FrameHandler?
    private var onFrameReachedDownstreamHandler: FrameHandler?
    private var onIdleTimeoutHandler: IdleTimeoutHandler?
    private var onPipelineStartedHandler: FrameHandler?
    private var onPipelineFinishedHandler: FrameHandler?
    private var onPipelineErrorHandler: ErrorHandler?

    private(set) var state: State = .idle
    var hasFinished: Bool { finished }

    init(
        pipeline: Pipeline,
        params: PipelineTaskParams = PipelineTaskParams(),
        observers: [BaseObserver] = []
    ) {
        self.pipeline = pipeline
        self.params = params
        self.observers = observers
        self.reachedUpstreamTypes = params.reachedUpstreamTypes
        self.reachedDownstreamTypes = params.reachedDownstreamTypes
    }

    func addObserver(_ observer: BaseObserver) {
        observers.append(observer)
    }

    func setReachedUpstreamFilter(_ types: [Frame.Type]) {
        reachedUpstreamTypes = types
    }

    func setReachedDownstreamFilter(_ types: [Frame.Type]) {
        reachedDownstreamTypes = types
    }

    func addReachedUpstreamFilter(_ types: [Frame.Type]) {
        appendUniqueTypes(types, to: &reachedUpstreamTypes)
    }

    func addReachedDownstreamFilter(_ types: [Frame.Type]) {
        appendUniqueTypes(types, to: &reachedDownstreamTypes)
    }

    func setOnFrameReachedUpstream(_ handler: @escaping FrameHandler) {
        onFrameReachedUpstreamHandler = handler
    }

    func setOnFrameReachedDownstream(_ handler: @escaping FrameHandler) {
        onFrameReachedDownstreamHandler = handler
    }

    func setOnIdleTimeout(_ handler: @escaping IdleTimeoutHandler) {
        onIdleTimeoutHandler = handler
    }

    func setOnPipelineStarted(_ handler: @escaping FrameHandler) {
        onPipelineStartedHandler = handler
    }

    func setOnPipelineFinished(_ handler: @escaping FrameHandler) {
        onPipelineFinishedHandler = handler
    }

    func setOnPipelineError(_ handler: @escaping ErrorHandler) {
        onPipelineErrorHandler = handler
    }

    /// Mirrors Pipecat task.py:521 `async def run(params)`.
    /// Suspends until EndFrame / StopFrame / CancelFrame exits the pipeline.
    /// On resume: calls cancelAuxiliaryTasks() (mirrors Python `finally: _cancel_tasks()`).
    /// Processor cleanup is handled inside performPipelineCleanup, not here.
    func run(with frame: StartFrame = StartFrame()) async {
        guard state == .idle else { return }
        await prepareRuntimeIfNeeded()
        finished = false
        pipelineStarted = false
        cancellationRequested = false
        lastIdleActivityAt = nowNanos()
        lastProcessedHeartbeatAt = lastIdleActivityAt
        state = .starting
        startIdleMonitorIfNeeded()
        await inject(frame, direction: .downstream)
        await waitForPipelineStart()

        // Mirrors `await self._wait_for_pipeline_finished()`.
        await withCheckedContinuation { continuation in
            pipelineFinishedWaiters.append(continuation)
        }

        // Mirrors `finally: await self._cancel_tasks()`.
        // Idempotent: performPipelineCleanup already called cancelAuxiliaryTasks.
        // This second call handles the case where the enclosing Task is cancelled
        // externally before handleBoundary runs (equivalent to CancelledError path).
        cancelAuxiliaryTasks()
    }

    func run() async {
        await run(with: StartFrame())
    }

    // Kept for callers that do not need to await pipeline completion.
    func start(with frame: StartFrame = StartFrame()) async {
        guard state == .idle else { return }
        await prepareRuntimeIfNeeded()
        finished = false
        pipelineStarted = false
        cancellationRequested = false
        lastIdleActivityAt = nowNanos()
        lastProcessedHeartbeatAt = lastIdleActivityAt
        state = .starting
        startIdleMonitorIfNeeded()
        await inject(frame, direction: .downstream)
        await waitForPipelineStart()
    }

    func start() async {
        await start(with: StartFrame())
    }

    func stop() async {
        guard state == .running else { return }
        await inject(StopFrame(), direction: .downstream)
    }

    func end(reason: Any? = nil) async {
        guard state == .running else { return }
        await inject(EndFrame(reason: reason), direction: .downstream)
    }

    func cancel() async {
        guard state == .running || state == .starting else { return }
        cancellationRequested = true
        await inject(CancelFrame(), direction: .downstream)
    }

    func interrupt() async {
        guard state == .running else { return }
        await inject(InterruptionFrame(), direction: .downstream)
    }

    func stopWhenDone(reason: Any? = nil) async {
        guard state == .running || state == .starting else { return }
        await inject(EndFrame(reason: reason), direction: .downstream)
    }

    func enqueue(
        _ frame: Frame,
        direction: FrameDirection = .downstream,
        sourceProcessorIndex: Int? = nil
    ) async {
        guard state == .running else { return }
        await inject(frame, direction: direction, sourceProcessorIndex: sourceProcessorIndex)
    }

    func enqueue(
        _ frames: [Frame],
        direction: FrameDirection = .downstream,
        sourceProcessorIndex: Int? = nil
    ) async {
        guard state == .running else { return }
        for frame in frames {
            await inject(frame, direction: direction, sourceProcessorIndex: sourceProcessorIndex)
        }
    }

    private func inject(
        _ frame: Frame,
        direction: FrameDirection,
        sourceProcessorIndex: Int? = nil
    ) async {
        if pipeline.processors.isEmpty {
            await handleBoundary(frame, direction: direction, sourceProcessorIndex: sourceProcessorIndex)
            return
        }

        let entryProcessor: FrameProcessor
        switch direction {
        case .downstream:
            entryProcessor = pipeline.processors[0]
        case .upstream:
            entryProcessor = pipeline.processors[pipeline.processors.count - 1]
        }

        await entryProcessor.queueFrame(
            frame,
            direction: direction,
            sourceProcessorIndex: sourceProcessorIndex
        )
    }

    /// Suspends until the pipeline enters `.running` state.
    /// Safe to call after run() has been dispatched in a separate Task.
    func waitUntilRunning() async {
        guard !pipelineStarted else { return }

        await withCheckedContinuation { continuation in
            pipelineStartWaiters.append(continuation)
        }
    }

    private func waitForPipelineStart() async {
        await waitUntilRunning()
    }

    private func prepareRuntimeIfNeeded() async {
        guard !runtimePrepared else { return }

        for index in pipeline.processors.indices {
            let previous = index > 0 ? pipeline.processors[index - 1] : nil
            let next = index + 1 < pipeline.processors.count ? pipeline.processors[index + 1] : nil
            pipeline.processors[index].prepareRuntime(
                index: index,
                previous: previous,
                next: next,
                onProcess: { [weak self] data in
                    await self?.notifyProcessFrame(data)
                },
                onPush: { [weak self] data in
                    await self?.notifyPushFrame(data)
                },
                onBoundary: { [weak self] frame, direction, sourceProcessorIndex in
                    await self?.handleBoundary(
                        frame,
                        direction: direction,
                        sourceProcessorIndex: sourceProcessorIndex
                    )
                }
            )
        }

        runtimePrepared = true
    }

    private func handleBoundary(
        _ frame: Frame,
        direction: FrameDirection,
        sourceProcessorIndex: Int?
    ) async {
        recordIdleActivityIfNeeded(frame)

        switch direction {
        case .upstream:
            if matchesConfiguredType(frame, types: reachedUpstreamTypes) {
                await onFrameReachedUpstreamHandler?(frame)
            }

            switch frame {
            case let frame as ErrorFrame:
                await onPipelineErrorHandler?(frame)
                if frame.fatal {
                    cancellationRequested = true
                    await inject(CancelFrame(reason: frame.message), direction: .downstream)
                }
                return
            case let frame as EndTaskFrame:
                await inject(EndFrame(reason: frame.reason), direction: .downstream)
                return
            case let frame as CancelTaskFrame:
                cancellationRequested = true
                await inject(CancelFrame(reason: frame.reason), direction: .downstream)
                return
            case is StopTaskFrame:
                await inject(StopFrame(), direction: .downstream)
                return
            case is InterruptionTaskFrame:
                await inject(InterruptionFrame(), direction: .downstream)
                return
            default:
                break
            }

        case .downstream:
            if matchesConfiguredType(frame, types: reachedDownstreamTypes) {
                await onFrameReachedDownstreamHandler?(frame)
            }

            switch frame {
            case is HeartbeatFrame:
                lastProcessedHeartbeatAt = nowNanos()
                return
            case let frame as EndTaskFrame:
                await inject(
                    EndTaskFrame(reason: frame.reason),
                    direction: .upstream,
                    sourceProcessorIndex: sourceProcessorIndex
                )
                return
            case let frame as CancelTaskFrame:
                await inject(
                    CancelTaskFrame(reason: frame.reason),
                    direction: .upstream,
                    sourceProcessorIndex: sourceProcessorIndex
                )
                return
            case is StopTaskFrame:
                await inject(
                    StopTaskFrame(),
                    direction: .upstream,
                    sourceProcessorIndex: sourceProcessorIndex
                )
                return
            case is InterruptionTaskFrame:
                await inject(
                    InterruptionTaskFrame(),
                    direction: .upstream,
                    sourceProcessorIndex: sourceProcessorIndex
                )
                return
            default:
                break
            }
        }

        if direction == .downstream, let startFrame = frame as? StartFrame {
            state = .running
            pipelineStarted = true
            lastIdleActivityAt = nowNanos()
            lastProcessedHeartbeatAt = lastIdleActivityAt
            await onPipelineStartedHandler?(startFrame)
            await notifyPipelineStarted()
            startHeartbeatTasksIfNeeded()
            resumePipelineStartWaiters()
            return
        }

        if direction == .downstream, frame is EndFrame || frame is StopFrame || frame is CancelFrame {
            state = .stopped
            finished = true
            pipelineStarted = true
            resumePipelineStartWaiters()
            await onPipelineFinishedHandler?(frame)
            await notifyPipelineFinished(frame)
            // Mirrors task.py:790: `await self._cleanup(cleanup_pipeline)` at the end of
            // _process_push_queue. Also calls cancelAuxiliaryTasks() (mirrors _cancel_tasks
            // for callers that use start() instead of run()).
            await performPipelineCleanup(trigger: frame)
            // Unblocks run() continuation. No-op if caller used start().
            resumePipelineFinishedWaiters()
        }
    }

    /// Mirrors Pipecat task.py:734 `_cleanup(cleanup_pipeline)`.
    /// StopFrame  → cleanup_pipeline=False: processor tasks kept alive (session reuse).
    /// EndFrame / CancelFrame → cleanup_pipeline=True: calls cleanupRuntime on all processors
    ///   (mirrors pipeline.py:178 pipeline.cleanup() → frame_processor.py:506 processor.cleanup()).
    /// Always cancels auxiliary tasks (heartbeat / idle), covering the start() caller path.
    private func performPipelineCleanup(trigger: Frame) async {
        // Cancel auxiliary tasks regardless of frame type.
        // Mirrors _cancel_tasks() for the start() caller path;
        // run() will call it again as a no-op in its finally block.
        cancelAuxiliaryTasks()

        let cleanupPipeline = !(trigger is StopFrame)
        guard cleanupPipeline else {
            // StopFrame: processor tasks stay alive.
            // runtimePrepared remains true so the next start()/run() can reuse the runtime.
            return
        }

        // EndFrame / CancelFrame: clean up all processor runtimes.
        guard runtimeCleanupTask == nil else { return }
        let processors = pipeline.processors
        runtimeCleanupTask = Task {
            for processor in processors {
                await processor.cleanupRuntime()
            }
        }
        await runtimeCleanupTask?.value
        runtimeCleanupTask = nil
        // Force re-prepareRuntime before the next start()/run().
        runtimePrepared = false
    }

    private func startHeartbeatTasksIfNeeded() {
        guard params.enableHeartbeats else { return }
        guard heartbeatPushTask == nil, heartbeatMonitorTask == nil else { return }

        heartbeatPushTask = Task { [weak self] in
            await self?.heartbeatPushLoop()
        }
        heartbeatMonitorTask = Task { [weak self] in
            await self?.heartbeatMonitorLoop()
        }
    }

    private func startIdleMonitorIfNeeded() {
        guard params.idleTimeoutSecs != nil else { return }
        guard idleMonitorTask == nil else { return }

        idleMonitorTask = Task { [weak self] in
            await self?.idleMonitorLoop()
        }
    }

    private func cancelAuxiliaryTasks() {
        heartbeatPushTask?.cancel()
        heartbeatMonitorTask?.cancel()
        idleMonitorTask?.cancel()
        heartbeatPushTask = nil
        heartbeatMonitorTask = nil
        idleMonitorTask = nil
    }

    private func resumePipelineStartWaiters() {
        let waiters = pipelineStartWaiters
        pipelineStartWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Resumes any continuation waiting inside run().
    /// No-op when the caller used start() instead of run().
    private func resumePipelineFinishedWaiters() {
        let waiters = pipelineFinishedWaiters
        pipelineFinishedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func notifyProcessFrame(_ data: FrameProcessed) async {
        for observer in observers {
            await observer.onProcessFrame(data)
        }
    }

    private func notifyPushFrame(_ data: FramePushed) async {
        recordIdleActivityIfNeeded(data.frame)
        for observer in observers {
            await observer.onPushFrame(data)
        }
    }

    private func notifyPipelineStarted() async {
        for observer in observers {
            await observer.onPipelineStarted()
        }
    }

    private func notifyPipelineFinished(_ frame: Frame) async {
        for observer in observers {
            await observer.onPipelineFinished(frame)
        }
    }

    private func heartbeatPushLoop() async {
        let interval = params.heartbeatsPeriodSecs
        guard interval > 0 else { return }

        while !Task.isCancelled {
            await inject(HeartbeatFrame(timestamp: nowNanos()), direction: .downstream)
            do {
                try await Task.sleep(nanoseconds: secondsToNanos(interval))
            } catch {
                return
            }
        }
    }

    private func heartbeatMonitorLoop() async {
        let waitTime = params.heartbeatsMonitorSecs
        guard waitTime > 0 else { return }

        while !Task.isCancelled {
            let deadline = heartbeatDeadline(waitTime: waitTime)
            let now = nowNanos()
            if deadline > now {
                do {
                    try await Task.sleep(nanoseconds: deadline - now)
                } catch {
                    return
                }
            }

            if Task.isCancelled { return }
            if didMissHeartbeat(deadline: deadline, waitTime: waitTime) {
                lastProcessedHeartbeatAt = nowNanos()
            }
        }
    }

    private func idleMonitorLoop() async {
        guard let timeout = params.idleTimeoutSecs, timeout > 0 else { return }

        while !Task.isCancelled {
            let deadline = idleDeadline(timeout: timeout)
            let now = nowNanos()
            if deadline > now {
                do {
                    try await Task.sleep(nanoseconds: deadline - now)
                } catch {
                    return
                }
            }

            if Task.isCancelled { return }
            let timedOut = didIdleTimeout(deadline: deadline, timeout: timeout)
            if !timedOut {
                continue
            }

            await onIdleTimeoutHandler?()
            if params.cancelOnIdleTimeout {
                await cancel()
                return
            }
        }
    }

    private func heartbeatDeadline(waitTime: TimeInterval) -> UInt64 {
        lastProcessedHeartbeatAt + secondsToNanos(waitTime)
    }

    private func idleDeadline(timeout: TimeInterval) -> UInt64 {
        lastIdleActivityAt + secondsToNanos(timeout)
    }

    private func didMissHeartbeat(deadline: UInt64, waitTime: TimeInterval) -> Bool {
        guard state == .running else { return false }
        let currentDeadline = heartbeatDeadline(waitTime: waitTime)
        return currentDeadline == deadline && nowNanos() >= deadline
    }

    private func didIdleTimeout(deadline: UInt64, timeout: TimeInterval) -> Bool {
        guard state == .running || state == .starting else { return false }
        guard !cancellationRequested else { return false }
        let currentDeadline = idleDeadline(timeout: timeout)
        return currentDeadline == deadline && nowNanos() >= deadline
    }

    private func recordIdleActivityIfNeeded(_ frame: Frame) {
        if frame is StartFrame || matchesConfiguredType(frame, types: params.idleTimeoutFrames) {
            lastIdleActivityAt = nowNanos()
        }
    }

    private func matchesConfiguredType(_ frame: Frame, types: [Frame.Type]) -> Bool {
        types.contains { configuredType in
            type(of: frame) == configuredType
        }
    }

    private func appendUniqueTypes(_ types: [Frame.Type], to existing: inout [Frame.Type]) {
        for type in types where !existing.contains(where: { ObjectIdentifier($0) == ObjectIdentifier(type) }) {
            existing.append(type)
        }
    }

    private func secondsToNanos(_ seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000_000)
    }

    private func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
