import Foundation

protocol FrameProcessorContext: Sendable {
    func push(_ frame: Frame, direction: FrameDirection) async
}

private struct ProcessorContext: FrameProcessorContext {
    let processor: FrameProcessor

    func push(_ frame: Frame, direction: FrameDirection) async {
        await processor.pushFrame(frame, direction: direction)
    }
}

private actor ProcessorRuntimeMailbox {
    private var inputQueue = PriorityFrameQueue()
    private var processQueue: [QueuedFrame] = []

    private var nextWaiterID = 0
    private var inputWaiters: [Int: CheckedContinuation<QueuedFrame, Never>] = [:]
    private var inputWaiterOrder: [Int] = []
    private var processWaiters: [Int: CheckedContinuation<QueuedFrame, Never>] = [:]
    private var processWaiterOrder: [Int] = []

    private var systemResumeWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var systemResumeWaiterOrder: [Int] = []
    private var frameResumeWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var frameResumeWaiterOrder: [Int] = []

    private var blockSystemFrames = false
    private var blockFrames = false
    private var currentProcessFrame: Frame?

    func enqueueInput(_ item: QueuedFrame) {
        if let waiterID = inputWaiterOrder.first {
            inputWaiterOrder.removeFirst()
            let waiter = inputWaiters.removeValue(forKey: waiterID)
            waiter?.resume(returning: item)
            return
        }

        inputQueue.enqueue(item)
    }

    func dequeueInput() async -> QueuedFrame {
        if let item = inputQueue.dequeue() {
            return item
        }

        let waiterID = nextID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                inputWaiters[waiterID] = continuation
                inputWaiterOrder.append(waiterID)
            }
        } onCancel: {
            Task {
                await self.cancelInputWaiter(waiterID)
            }
        }
    }

    func enqueueProcess(_ item: QueuedFrame) {
        if let waiterID = processWaiterOrder.first {
            processWaiterOrder.removeFirst()
            let waiter = processWaiters.removeValue(forKey: waiterID)
            waiter?.resume(returning: item)
            return
        }

        processQueue.append(item)
    }

    func dequeueProcess() async -> QueuedFrame {
        if !processQueue.isEmpty {
            return processQueue.removeFirst()
        }

        let waiterID = nextID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                processWaiters[waiterID] = continuation
                processWaiterOrder.append(waiterID)
            }
        } onCancel: {
            Task {
                await self.cancelProcessWaiter(waiterID)
            }
        }
    }

    func pauseProcessingFrames() {
        blockFrames = true
    }

    func pauseProcessingSystemFrames() {
        blockSystemFrames = true
    }

    func resumeProcessingFrames() {
        blockFrames = false
        let waiterIDs = frameResumeWaiterOrder
        frameResumeWaiterOrder.removeAll(keepingCapacity: false)
        for waiterID in waiterIDs {
            frameResumeWaiters.removeValue(forKey: waiterID)?.resume()
        }
    }

    func resumeProcessingSystemFrames() {
        blockSystemFrames = false
        let waiterIDs = systemResumeWaiterOrder
        systemResumeWaiterOrder.removeAll(keepingCapacity: false)
        for waiterID in waiterIDs {
            systemResumeWaiters.removeValue(forKey: waiterID)?.resume()
        }
    }

    func waitIfProcessingFramesPaused() async {
        guard blockFrames else { return }

        let waiterID = nextID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                frameResumeWaiters[waiterID] = continuation
                frameResumeWaiterOrder.append(waiterID)
            }
        } onCancel: {
            Task {
                await self.cancelFrameResumeWaiter(waiterID)
            }
        }
    }

    func waitIfProcessingSystemFramesPaused() async {
        guard blockSystemFrames else { return }

        let waiterID = nextID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                systemResumeWaiters[waiterID] = continuation
                systemResumeWaiterOrder.append(waiterID)
            }
        } onCancel: {
            Task {
                await self.cancelSystemResumeWaiter(waiterID)
            }
        }
    }

    func setCurrentProcessFrame(_ frame: Frame?) {
        currentProcessFrame = frame
    }

    func currentProcessFrameIsUninterruptible() -> Bool {
        currentProcessFrame is UninterruptibleFrame
    }

    func hasQueuedUninterruptibleProcessFrames() -> Bool {
        processQueue.contains { $0.frame is UninterruptibleFrame }
    }

    func resetProcessQueue(keepingUninterruptible: Bool) {
        if keepingUninterruptible {
            processQueue.removeAll { !($0.frame is UninterruptibleFrame) }
        } else {
            processQueue.removeAll(keepingCapacity: false)
        }
    }

    func resetAllQueues() {
        inputQueue = PriorityFrameQueue()
        processQueue.removeAll(keepingCapacity: false)
    }

    private func nextID() -> Int {
        defer { nextWaiterID += 1 }
        return nextWaiterID
    }

    private func cancelInputWaiter(_ id: Int) {
        let waiter = inputWaiters.removeValue(forKey: id)
        inputWaiterOrder.removeAll { $0 == id }
        waiter?.resume(returning: cancellationItem())
    }

    private func cancelProcessWaiter(_ id: Int) {
        let waiter = processWaiters.removeValue(forKey: id)
        processWaiterOrder.removeAll { $0 == id }
        waiter?.resume(returning: cancellationItem())
    }

    private func cancelSystemResumeWaiter(_ id: Int) {
        let waiter = systemResumeWaiters.removeValue(forKey: id)
        systemResumeWaiterOrder.removeAll { $0 == id }
        waiter?.resume()
    }

    private func cancelFrameResumeWaiter(_ id: Int) {
        let waiter = frameResumeWaiters.removeValue(forKey: id)
        frameResumeWaiterOrder.removeAll { $0 == id }
        waiter?.resume()
    }

    private func cancellationItem() -> QueuedFrame {
        QueuedFrame(
            frame: CancelFrame(reason: "ProcessorRuntimeMailbox cancelled waiter"),
            direction: .downstream,
            sourceProcessorIndex: nil
        )
    }
}

class FrameProcessor: @unchecked Sendable {
    typealias ProcessObserver = @Sendable (FrameProcessed) async -> Void
    typealias PushObserver = @Sendable (FramePushed) async -> Void
    typealias BoundaryHandler = @Sendable (Frame, FrameDirection, Int?) async -> Void

    let name: String

    private weak var previousProcessor: FrameProcessor?
    private weak var nextProcessor: FrameProcessor?
    private var pipelineIndex: Int?

    private let runtimeMailbox = ProcessorRuntimeMailbox()
    private let stateLock = NSLock()
    private var started = false
    private var cancelling = false

    private var inputTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?

    private var onProcess: ProcessObserver?
    private var onPush: PushObserver?
    private var onBoundary: BoundaryHandler?

    init(name: String? = nil) {
        self.name = name ?? String(describing: Self.self)
    }

    func prepareRuntime(
        index: Int,
        previous: FrameProcessor?,
        next: FrameProcessor?,
        onProcess: @escaping ProcessObserver,
        onPush: @escaping PushObserver,
        onBoundary: @escaping BoundaryHandler
    ) {
        stateLock.withLock {
            pipelineIndex = index
            previousProcessor = previous
            nextProcessor = next
            self.onProcess = onProcess
            self.onPush = onPush
            self.onBoundary = onBoundary
        }

        createInputTaskIfNeeded()
    }

    func cleanupRuntime() async {
        let tasks = stateLock.withLock { () -> [Task<Void, Never>] in
            let tasks = [inputTask, processTask].compactMap { $0 }
            inputTask = nil
            processTask = nil
            return tasks
        }

        for task in tasks {
            task.cancel()
            _ = await task.result
        }

        await runtimeMailbox.resetAllQueues()
        await runtimeMailbox.resumeProcessingFrames()
        await runtimeMailbox.resumeProcessingSystemFrames()

        stateLock.withLock {
            started = false
            cancelling = false
        }
    }

    func queueFrame(
        _ frame: Frame,
        direction: FrameDirection = .downstream,
        sourceProcessorIndex: Int? = nil
    ) async {
        if isCancelling(), !(frame is StartFrame || frame is CancelFrame) {
            return
        }

        await runtimeMailbox.enqueueInput(
            QueuedFrame(
                frame: frame,
                direction: direction,
                sourceProcessorIndex: sourceProcessorIndex
            )
        )
    }

    func pushFrame(_ frame: Frame, direction: FrameDirection = .downstream) async {
        if !checkStarted(frame) {
            return
        }

        switch direction {
        case .downstream:
            if let next = stateLock.withLock({ nextProcessor }) {
                await notifyPush(frame, direction: direction, destination: next)
                await next.queueFrame(frame, direction: direction, sourceProcessorIndex: currentPipelineIndex())
            } else {
                await onBoundary?(frame, direction, currentPipelineIndex())
            }
        case .upstream:
            if let previous = stateLock.withLock({ previousProcessor }) {
                await notifyPush(frame, direction: direction, destination: previous)
                await previous.queueFrame(frame, direction: direction, sourceProcessorIndex: currentPipelineIndex())
            } else {
                await onBoundary?(frame, direction, currentPipelineIndex())
            }
        }
    }

    func broadcastFrame(_ makeFrame: @escaping @Sendable () -> Frame) async {
        let downstreamFrame = makeFrame()
        let upstreamFrame = makeFrame()
        downstreamFrame.broadcastSiblingID = upstreamFrame.id
        upstreamFrame.broadcastSiblingID = downstreamFrame.id
        await pushFrame(downstreamFrame, direction: .downstream)
        await pushFrame(upstreamFrame, direction: .upstream)
    }

    func pauseProcessingFrames() async {
        await runtimeMailbox.pauseProcessingFrames()
    }

    func pauseProcessingSystemFrames() async {
        await runtimeMailbox.pauseProcessingSystemFrames()
    }

    func resumeProcessingFrames() async {
        await runtimeMailbox.resumeProcessingFrames()
    }

    func resumeProcessingSystemFrames() async {
        await runtimeMailbox.resumeProcessingSystemFrames()
    }

    func didReceiveStart(_ frame: StartFrame, direction: FrameDirection, context: FrameProcessorContext) async {}

    func didReceiveStop(_ frame: StopFrame, direction: FrameDirection, context: FrameProcessorContext) async {}

    func didReceiveCancel(_ frame: CancelFrame, direction: FrameDirection, context: FrameProcessorContext) async {}

    func didReceivePause(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {}

    func didReceiveResume(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {}

    func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        await context.push(frame, direction: direction)
    }

    private func createInputTaskIfNeeded() {
        let shouldCreate = stateLock.withLock { () -> Bool in
            if inputTask != nil {
                return false
            }
            inputTask = Task { [weak self] in
                await self?.inputLoop()
            }
            return true
        }

        if !shouldCreate {
            return
        }
    }

    private func createProcessTaskIfNeeded() {
        stateLock.withLock {
            guard processTask == nil else { return }
            processTask = Task { [weak self] in
                await self?.processLoop()
            }
        }
    }

    private func cancelProcessTask() async {
        let task = stateLock.withLock { () -> Task<Void, Never>? in
            let task = processTask
            processTask = nil
            return task
        }

        guard let task else { return }
        task.cancel()
        _ = await task.result
        await runtimeMailbox.setCurrentProcessFrame(nil)
    }

    private func handleBaseFrame(
        _ frame: Frame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        switch frame {
        case let frame as StartFrame:
            markStarted()
            createProcessTaskIfNeeded()
            await didReceiveStart(frame, direction: direction, context: context)

        case let frame as StopFrame:
            await didReceiveStop(frame, direction: direction, context: context)

        case let frame as CancelFrame:
            markCancelling()
            await didReceiveCancel(frame, direction: direction, context: context)
            await cancelProcessTask()

        case let frame as FrameProcessorPauseFrame where frame.processor === self:
            await runtimeMailbox.pauseProcessingFrames()
            await didReceivePause(frame, direction: direction, context: context)

        case let frame as FrameProcessorPauseUrgentFrame where frame.processor === self:
            await runtimeMailbox.pauseProcessingFrames()
            await didReceivePause(frame, direction: direction, context: context)

        case let frame as FrameProcessorResumeFrame where frame.processor === self:
            await runtimeMailbox.resumeProcessingFrames()
            await didReceiveResume(frame, direction: direction, context: context)

        case let frame as FrameProcessorResumeUrgentFrame where frame.processor === self:
            await runtimeMailbox.resumeProcessingFrames()
            await didReceiveResume(frame, direction: direction, context: context)

        case is InterruptionFrame:
            await startInterruption()

        default:
            break
        }
    }

    private func startInterruption() async {
        let currentUninterruptible = await runtimeMailbox.currentProcessFrameIsUninterruptible()
        let hasQueuedUninterruptible = await runtimeMailbox.hasQueuedUninterruptibleProcessFrames()

        if currentUninterruptible || hasQueuedUninterruptible {
            await runtimeMailbox.resetProcessQueue(keepingUninterruptible: true)
        } else {
            await cancelProcessTask()
            await runtimeMailbox.resetProcessQueue(keepingUninterruptible: false)
            createProcessTaskIfNeeded()
        }
    }

    private func inputLoop() async {
        while !Task.isCancelled {
            let item = await runtimeMailbox.dequeueInput()
            if Task.isCancelled { break }

            await runtimeMailbox.waitIfProcessingSystemFramesPaused()
            if Task.isCancelled { break }

            if item.frame.isSystemFrame {
                await processQueuedFrame(item)
            } else {
                await runtimeMailbox.enqueueProcess(item)
            }
        }
    }

    private func processLoop() async {
        while !Task.isCancelled {
            let item = await runtimeMailbox.dequeueProcess()
            if Task.isCancelled { break }

            await runtimeMailbox.setCurrentProcessFrame(item.frame)
            await runtimeMailbox.waitIfProcessingFramesPaused()
            if Task.isCancelled {
                await runtimeMailbox.setCurrentProcessFrame(nil)
                break
            }

            await processQueuedFrame(item)
            await runtimeMailbox.setCurrentProcessFrame(nil)
        }
    }

    private func processQueuedFrame(_ item: QueuedFrame) async {
        let context = ProcessorContext(processor: self)
        await notifyProcess(item.frame, direction: item.direction)

        await handleBaseFrame(item.frame, direction: item.direction, context: context)

        if Task.isCancelled {
            return
        }

        await process(item.frame, direction: item.direction, context: context)
    }

    private func markStarted() {
        stateLock.withLock {
            started = true
        }
    }

    private func markCancelling() {
        stateLock.withLock {
            cancelling = true
        }
    }

    private func currentPipelineIndex() -> Int? {
        stateLock.withLock { pipelineIndex }
    }

    private func isCancelling() -> Bool {
        stateLock.withLock { cancelling }
    }

    private func checkStarted(_ frame: Frame) -> Bool {
        if frame is StartFrame {
            return true
        }
        return stateLock.withLock { started }
    }

    private func notifyProcess(_ frame: Frame, direction: FrameDirection) async {
        guard let onProcess else { return }
        await onProcess(
            FrameProcessed(
                processor: self,
                frame: frame,
                direction: direction,
                timestamp: DispatchTime.now().uptimeNanoseconds
            )
        )
    }

    private func notifyPush(
        _ frame: Frame,
        direction: FrameDirection,
        destination: FrameProcessor
    ) async {
        guard let onPush else { return }
        await onPush(
            FramePushed(
                source: self,
                destination: destination,
                frame: frame,
                direction: direction,
                timestamp: DispatchTime.now().uptimeNanoseconds
            )
        )
    }
}
