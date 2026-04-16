import AVFoundation
import FluidAudio
import Foundation

final class VADProcessor: FrameProcessor, @unchecked Sendable {
    private enum PendingEvent {
        case speechStarted(startSecs: Double)
        case speechStopped(stopSecs: Double)
        case speechActivity
    }

    private let service: VADService
    private let speechActivityPeriod: TimeInterval
    private let audioIdleTimeout: TimeInterval
    private var vadParams = VADParams()
    private var pendingSamples: [Float] = []
    private let chunkSize = VadManager.chunkSize

    private let eventStateLock = NSLock()
    private var pendingEvents: [PendingEvent] = []
    private var isHandlingChunk = false
    private var outOfBandDrainScheduled = false
    private var outOfBandDrainTask: Task<Void, Never>?
    private var outOfBandDrainTaskID = 0
    private var eventsEnabled = false
    private var isSpeaking = false
    private var lastAudioTimeNanos: UInt64 = 0
    private var audioIdleTask: Task<Void, Never>?

    init(
        service: VADService = VADService(),
        speechActivityPeriod: TimeInterval = 0.2,
        audioIdleTimeout: TimeInterval = 1.0
    ) {
        self.service = service
        self.speechActivityPeriod = speechActivityPeriod
        self.audioIdleTimeout = audioIdleTimeout
        super.init(name: "VADProcessor")
    }

    override func didReceiveStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        pendingSamples = []
        resetEventState(enabled: true)
        await service.initialize()
        applyVADParams(vadParams)
        configureCallbacks()
        startAudioIdleTaskIfNeeded()
    }

    override func didReceiveStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await waitForOutOfBandDrainIfNeeded()
        await drainPendingEvents(context: context)
        pendingSamples = []
        resetEventState(enabled: false)
        clearCallbacks()
        cancelAudioIdleTask()
        service.stopListening()
    }

    override func didReceiveCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        pendingSamples = []
        resetEventState(enabled: false)
        clearCallbacks()
        cancelAudioIdleTask()
        service.stopListening()
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        switch frame {
        case let frame as StartFrame:
            await context.push(frame, direction: direction)
            await emitBroadcast(SpeechControlParamsFrame(vadParams: self.currentVADParams()), context: context)
        case let frame as VADParamsUpdateFrame:
            await context.push(frame, direction: direction)
            applyVADParams(frame.params)
            await emitBroadcast(SpeechControlParamsFrame(vadParams: frame.params), context: context)
        case let frame as InputAudioRawFrame:
            await context.push(frame, direction: direction)
            await processInput(frame, context: context)
        default:
            await super.process(frame, direction: direction, context: context)
        }
    }

    private func configureCallbacks() {
        service.onSpeechStart = { [weak self] in
            self?.handleSpeechStarted(startSecs: 0.0)
        }
        service.onSpeechEnd = { [weak self] _ in
            self?.handleSpeechStopped()
        }
        service.onProbabilityUpdate = { _ in }
        service.onSpeechChunk = { [weak self] _ in
            self?.appendPendingEvent(.speechActivity)
        }
    }

    private func clearCallbacks() {
        service.onSpeechStart = nil
        service.onSpeechEnd = nil
        service.onProbabilityUpdate = nil
        service.onSpeechChunk = nil
    }

    private func processInput(_ frame: InputAudioRawFrame, context: FrameProcessorContext) async {
        let samples = extractSamples(from: frame.chunk.buffer)
        guard !samples.isEmpty else { return }

        recordAudioReceived()
        pendingSamples.append(contentsOf: samples)
        beginChunkHandling()
        while pendingSamples.count >= chunkSize {
            let chunk = Array(pendingSamples.prefix(chunkSize))
            pendingSamples.removeFirst(chunkSize)
            await service.processChunk(chunk)
            await drainPendingEvents(context: context)
        }
        if endChunkHandling() {
            scheduleOutOfBandDrain()
        }
    }

    private func currentVADParams() -> VADParams {
        eventStateLock.withLock { vadParams }
    }

    private func applyVADParams(_ params: VADParams) {
        eventStateLock.withLock {
            vadParams = params
        }
        service.liveConfig.minSilenceDuration = params.stopSecs
    }

    private func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channelData = buffer.floatChannelData
        else {
            return []
        }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0 else { return [] }

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        }

        var mixed = Array(repeating: Float.zero, count: frameLength)
        for channelIndex in 0..<channelCount {
            let channel = UnsafeBufferPointer(start: channelData[channelIndex], count: frameLength)
            for sampleIndex in 0..<frameLength {
                mixed[sampleIndex] += channel[sampleIndex]
            }
        }

        let scale = 1.0 / Float(channelCount)
        for index in mixed.indices {
            mixed[index] *= scale
        }
        return mixed
    }

    private func broadcast(
        _ frame: @autoclosure () -> Frame,
        context: FrameProcessorContext
    ) async {
        let downstreamFrame = frame()
        let upstreamFrame = frame()
        downstreamFrame.broadcastSiblingID = upstreamFrame.id
        upstreamFrame.broadcastSiblingID = downstreamFrame.id

        await context.push(downstreamFrame, direction: .downstream)
        await context.push(upstreamFrame, direction: .upstream)
    }

    private func appendPendingEvent(_ event: PendingEvent) {
        let shouldSchedule = eventStateLock.withLock { () -> Bool in
            guard eventsEnabled else { return false }
            pendingEvents.append(event)
            guard !isHandlingChunk, !outOfBandDrainScheduled else { return false }
            outOfBandDrainScheduled = true
            return true
        }

        if shouldSchedule {
            scheduleOutOfBandDrain()
        }
    }

    private func resetEventState(enabled: Bool) {
        eventStateLock.withLock {
            eventsEnabled = enabled
            pendingEvents.removeAll(keepingCapacity: false)
            isHandlingChunk = false
            outOfBandDrainScheduled = false
            isSpeaking = false
            lastAudioTimeNanos = enabled ? nowNanos() : 0
            if !enabled {
                outOfBandDrainTask = nil
            }
        }
    }

    private func handleSpeechStarted(startSecs: Double) {
        let shouldAppend = eventStateLock.withLock { () -> Bool in
            guard eventsEnabled, !isSpeaking else { return false }
            isSpeaking = true
            return true
        }

        guard shouldAppend else { return }
        appendPendingEvent(.speechStarted(startSecs: startSecs))
    }

    private func handleSpeechStopped() {
        let stopSecs = eventStateLock.withLock { () -> Double? in
            guard eventsEnabled, isSpeaking else { return nil }
            isSpeaking = false
            return vadParams.stopSecs
        }

        guard let stopSecs else { return }
        appendPendingEvent(.speechStopped(stopSecs: stopSecs))
    }

    private func recordAudioReceived() {
        eventStateLock.withLock {
            guard eventsEnabled else { return }
            lastAudioTimeNanos = nowNanos()
        }
    }

    private func startAudioIdleTaskIfNeeded() {
        guard audioIdleTimeout > 0 else { return }
        guard audioIdleTask == nil else { return }

        audioIdleTask = Task { [weak self] in
            await self?.audioIdleLoop()
        }
    }

    private func cancelAudioIdleTask() {
        audioIdleTask?.cancel()
        audioIdleTask = nil
    }

    private func audioIdleLoop() async {
        let timeoutNanos = secondsToNanos(audioIdleTimeout)
        guard timeoutNanos > 0 else { return }

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: timeoutNanos)
            } catch {
                return
            }

            let shouldForceStop = eventStateLock.withLock { () -> Bool in
                guard eventsEnabled, isSpeaking else { return false }
                let deadline = lastAudioTimeNanos + timeoutNanos
                guard nowNanos() >= deadline else { return false }
                isSpeaking = false
                return true
            }

            guard shouldForceStop else { continue }
            appendPendingEvent(.speechStopped(stopSecs: currentVADParams().stopSecs))
        }
    }

    private func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private func secondsToNanos(_ seconds: TimeInterval) -> UInt64 {
        guard seconds > 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000)
    }

    private func beginChunkHandling() {
        eventStateLock.withLock {
            guard eventsEnabled else { return }
            isHandlingChunk = true
        }
    }

    private func endChunkHandling() -> Bool {
        eventStateLock.withLock { () -> Bool in
            isHandlingChunk = false
            guard eventsEnabled, !outOfBandDrainScheduled, !pendingEvents.isEmpty else { return false }
            outOfBandDrainScheduled = true
            return true
        }
    }

    private func scheduleOutOfBandDrain() {
        let taskID = eventStateLock.withLock { () -> Int in
            outOfBandDrainTaskID += 1
            return outOfBandDrainTaskID
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainPendingEventsOutOfBand(taskID: taskID)
        }
        eventStateLock.withLock {
            outOfBandDrainTask = task
        }
    }

    private func takePendingEvents() -> [PendingEvent] {
        eventStateLock.withLock { () -> [PendingEvent] in
            let events = pendingEvents
            pendingEvents.removeAll(keepingCapacity: true)
            return events
        }
    }

    private func drainPendingEvents(context: FrameProcessorContext?) async {
        while true {
            let events = takePendingEvents()
            guard !events.isEmpty else { return }
            for event in events {
                await emit(event, context: context)
            }
        }
    }

    private func drainPendingEventsOutOfBand(taskID: Int) async {
        await drainPendingEvents(context: nil)

        let shouldReschedule = eventStateLock.withLock { () -> Bool in
            outOfBandDrainScheduled = false
            guard eventsEnabled, !isHandlingChunk, !pendingEvents.isEmpty else { return false }
            outOfBandDrainScheduled = true
            return true
        }

        if shouldReschedule {
            scheduleOutOfBandDrain()
        } else {
            eventStateLock.withLock {
                if outOfBandDrainTaskID == taskID {
                    outOfBandDrainTask = nil
                }
            }
        }
    }

    private func waitForOutOfBandDrainIfNeeded() async {
        let task = eventStateLock.withLock { outOfBandDrainTask }
        guard let task else { return }
        _ = await task.result
    }

    private func emit(_ event: PendingEvent, context: FrameProcessorContext?) async {
        guard eventStateLock.withLock({ eventsEnabled }) else { return }

        switch event {
        case let .speechStarted(startSecs):
            await emitBroadcast(VADUserStartedSpeakingFrame(startSecs: startSecs), context: context)
        case let .speechStopped(stopSecs):
            await emitBroadcast(VADUserStoppedSpeakingFrame(stopSecs: stopSecs), context: context)
        case .speechActivity:
            await emitUserSpeaking(context: context)
        }
    }

    private func emitUserSpeaking(context: FrameProcessorContext?) async {
        _ = speechActivityPeriod
        await emitBroadcast(UserSpeakingFrame(), context: context)
    }

    private func emitBroadcast(
        _ frame: @autoclosure @escaping () -> Frame,
        context: FrameProcessorContext?
    ) async {
        if let context {
            await broadcast(frame(), context: context)
            return
        }

        await broadcastFrame {
            frame()
        }
    }
}
