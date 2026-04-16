import AVFoundation
import Foundation

private actor IOSLivePlaybackQueue {
    private enum Item {
        case audio(AudioChunk)
        case ttsStopped
    }

    private let botSpeakingFramePeriod: TimeInterval
    private weak var audioIO: LiveAudioIO?
    private let emitBotStarted: @Sendable () async -> Void
    private let emitBotSpeaking: @Sendable () async -> Void
    private let emitBotStopped: @Sendable () async -> Void
    private var pending: [Item] = []
    private var isDraining = false
    private var botSpeaking = false
    private var ttsAudioReceived = false
    private var lastBotSpeakingFrameAt: UInt64 = 0

    init(
        audioIO: LiveAudioIO,
        botSpeakingFramePeriod: TimeInterval,
        emitBotStarted: @escaping @Sendable () async -> Void,
        emitBotSpeaking: @escaping @Sendable () async -> Void,
        emitBotStopped: @escaping @Sendable () async -> Void
    ) {
        self.audioIO = audioIO
        self.botSpeakingFramePeriod = botSpeakingFramePeriod
        self.emitBotStarted = emitBotStarted
        self.emitBotSpeaking = emitBotSpeaking
        self.emitBotStopped = emitBotStopped
    }

    func enqueueAudio(_ chunk: AudioChunk, isTTS: Bool) {
        if isTTS {
            ttsAudioReceived = true
        }
        print("[PlaybackQueue] enqueueAudio: \(chunk.buffer.frameLength) frames, isTTS=\(isTTS)")
        pending.append(.audio(chunk))
        guard !isDraining else { return }

        isDraining = true
        Task {
            await self.drain()
        }
    }

    func enqueueTTSStopped() {
        pending.append(.ttsStopped)
        guard !isDraining else { return }

        isDraining = true
        Task {
            await self.drain()
        }
    }

    func stop() async {
        pending.removeAll()
        isDraining = false
        let wasSpeaking = botSpeaking
        botSpeaking = false
        ttsAudioReceived = false
        lastBotSpeakingFrameAt = 0
        audioIO?.stopPlayback()
        if wasSpeaking {
            await emitBotStopped()
        }
    }

    private func drain() async {
        while let item = pending.first {
            pending.removeFirst()

            switch item {
            case let .audio(chunk):
                guard let audioIO else {
                    print("[PlaybackQueue] drain: audioIO is nil, skipping playback")
                    continue
                }
                if !botSpeaking {
                    botSpeaking = true
                    await emitBotStarted()
                    lastBotSpeakingFrameAt = 0
                }
                await maybeEmitBotSpeakingFrame()
                print("[PlaybackQueue] drain: playing \(chunk.buffer.frameLength) frames, engine.isRunning=\(audioIO.engine.isRunning)")
                await audioIO.playBuffer(chunk.buffer)

            case .ttsStopped:
                if ttsAudioReceived, botSpeaking {
                    botSpeaking = false
                    ttsAudioReceived = false
                    lastBotSpeakingFrameAt = 0
                    await emitBotStopped()
                } else {
                    ttsAudioReceived = false
                }
            }
        }

        isDraining = false
        if !pending.isEmpty {
            isDraining = true
            await drain()
        }
    }

    private func maybeEmitBotSpeakingFrame() async {
        let now = DispatchTime.now().uptimeNanoseconds
        let periodNanos = UInt64(botSpeakingFramePeriod * 1_000_000_000)
        if lastBotSpeakingFrameAt == 0 || periodNanos == 0 || now - lastBotSpeakingFrameAt >= periodNanos {
            lastBotSpeakingFrameAt = now
            await emitBotSpeaking()
        }
    }
}

final class IOSLiveTransport {
    let audioIO: LiveAudioIO
    private let inputSource: String?
    private let outputDestination: String?

    private lazy var inputTransport = IOSLiveInputTransport(
        audioIO: audioIO,
        transportSource: inputSource
    )
    private lazy var outputTransport = IOSLiveOutputTransport(
        audioIO: audioIO,
        transportDestination: outputDestination
    )

    init(
        audioIO: LiveAudioIO = LiveAudioIO(),
        inputSource: String? = nil,
        outputDestination: String? = nil
    ) {
        self.audioIO = audioIO
        self.inputSource = inputSource
        self.outputDestination = outputDestination
    }

    func input() -> IOSLiveInputTransport {
        inputTransport
    }

    func output() -> IOSLiveOutputTransport {
        outputTransport
    }
}

final class IOSLiveInputTransport: BaseInputTransport, @unchecked Sendable {
    private let audioIO: LiveAudioIO
    private let autoManageEngine: Bool
    private let transportSource: String?

    init(
        audioIO: LiveAudioIO,
        autoManageEngine: Bool = true,
        transportSource: String? = nil
    ) {
        self.audioIO = audioIO
        self.autoManageEngine = autoManageEngine
        self.transportSource = transportSource
        super.init(name: "IOSLiveInputTransport")
    }

    override func transportDidStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        print("[IOSLiveInput] transportDidStart called, installing audioInputBufferHandler")
        audioIO.audioInputBufferHandler = { [weak self] buffer, time in
            self?.ingestAudioBuffer(buffer, time: time)
        }
        print("[IOSLiveInput] audioInputBufferHandler installed: \(audioIO.audioInputBufferHandler != nil)")

        guard autoManageEngine else {
            print("[IOSLiveInput] autoManageEngine=false, skipping engine start")
            return
        }

        do {
            try audioIO.start()
        } catch {
            emit(ErrorFrame(message: "IOSLiveTransport failed to start audio engine", underlyingError: error))
        }
    }

    override func transportDidStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        audioIO.audioInputBufferHandler = nil
        guard autoManageEngine else { return }
        audioIO.stop()
    }

    override func transportDidCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        audioIO.audioInputBufferHandler = nil
        guard autoManageEngine else { return }
        audioIO.stop()
    }

    private var audioFrameCount = 0

    func ingestAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime?) {
        audioFrameCount += 1
        if audioFrameCount <= 3 || audioFrameCount % 100 == 0 {
            print("[IOSLiveInput] ingestAudioBuffer #\(audioFrameCount) frames=\(buffer.frameLength)")
        }
        let chunk = AudioChunk(
            buffer: buffer,
            sampleTime: time?.sampleTime,
            hostTime: time?.hostTime
        )
        let frame = InputAudioRawFrame(chunk: chunk)
        stampTransportMetadata(frame, transportSource: transportSource)
        emit(frame)
    }

    func makeStartFrame() -> StartFrame {
        StartFrame(
            audioMetadata: StartFrameAudioMetadata(
                input: AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1),
                output: AudioFormatDescriptor(sampleRate: 22_050, channelCount: 1)
            )
        )
    }
}

final class IOSLiveOutputTransport: BaseOutputTransport, @unchecked Sendable {
    private let audioIO: LiveAudioIO
    private let botSpeakingFramePeriod: TimeInterval
    private let transportDestination: String?
    private lazy var playbackQueue = IOSLivePlaybackQueue(
        audioIO: audioIO,
        botSpeakingFramePeriod: botSpeakingFramePeriod,
        emitBotStarted: { [weak self] in
            guard let self else { return }
            await self.emitBroadcastFrame(BotStartedSpeakingFrame())
        },
        emitBotSpeaking: { [weak self] in
            guard let self else { return }
            await self.emitBroadcastFrame(BotSpeakingFrame())
        },
        emitBotStopped: { [weak self] in
            guard let self else { return }
            await self.emitBroadcastFrame(BotStoppedSpeakingFrame())
        }
    )

    init(
        audioIO: LiveAudioIO,
        botSpeakingFramePeriod: TimeInterval = 0.2,
        transportDestination: String? = nil
    ) {
        self.audioIO = audioIO
        self.botSpeakingFramePeriod = botSpeakingFramePeriod
        self.transportDestination = transportDestination
        super.init(name: "IOSLiveOutputTransport")
    }

    override func transportDidStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {}

    override func transportDidStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await playbackQueue.stop()
    }

    override func transportDidCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await playbackQueue.stop()
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        switch frame {
        case let frame as TTSAudioRawFrame:
            stampOutputDestination(frame)
            await playbackQueue.enqueueAudio(frame.chunk, isTTS: true)
        case let frame as OutputAudioRawFrame:
            stampOutputDestination(frame)
            await playbackQueue.enqueueAudio(frame.chunk, isTTS: false)
        case let frame as TTSStoppedFrame:
            stampOutputDestination(frame)
            await playbackQueue.enqueueTTSStopped()
            await context.push(frame, direction: direction)
        case is InterruptionFrame:
            print("[IOSLiveOutput] received InterruptionFrame — stopping playback")
            await playbackQueue.stop()
            await context.push(frame, direction: direction)
        default:
            await super.process(frame, direction: direction, context: context)
        }
    }

    private func emitBroadcastFrame(_ frame: @autoclosure () -> Frame) async {
        let downstreamFrame = frame()
        let upstreamFrame = frame()
        stampOutputDestination(downstreamFrame, overwrite: true)
        stampOutputDestination(upstreamFrame, overwrite: true)
        downstreamFrame.broadcastSiblingID = upstreamFrame.id
        upstreamFrame.broadcastSiblingID = downstreamFrame.id
        await emitAsync(downstreamFrame, direction: .downstream)
        await emitAsync(upstreamFrame, direction: .upstream)
    }

    private func stampOutputDestination(_ frame: Frame, overwrite: Bool = true) {
        stampTransportMetadata(
            frame,
            transportDestination: transportDestination ?? frame.transportDestination,
            overwrite: overwrite
        )
    }
}
