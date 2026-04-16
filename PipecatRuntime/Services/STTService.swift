import Foundation

// Mirrors Pipecat `pipecat/services/stt_service.py:STTService` (line 45).
//
// Source-iso boundary: this is the abstract base for all STT services in the
// Swift port. Subclasses override `runSTT(audio:)` to provide actual speech
// recognition. The base class handles:
//
//   - mute (STTMuteFrame)
//   - audio passthrough toggle
//   - VAD start/stop tracking + TTFB metrics scaffolding
//   - InterruptionFrame reset
//   - STTMetadataFrame broadcast at startup
//   - settings update via STTUpdateSettingsFrame
//   - finalize_pending/requested state (used by streaming subclasses)
//   - keepalive scaffolding (used by network-backed subclasses; local STT no-op)
//
// Skipped from pipecat:
//   - process_generator: pipecat uses Python AsyncGenerator; Swift returns
//     `[Frame]` from runSTT and the base loops to push.
//
// Language abstraction: minimal `Language` enum + `languageToServiceLanguage`
// hook is provided so future cloud-STT subclasses can map Pipecat-canonical
// codes to service-specific identifiers (e.g. Deepgram "zh-CN" vs Google "cmn-Hans-CN").
//
// Concrete metrics infra (TTFB upload to dashboard etc) is a no-op in this
// port — methods are placeholders subclasses can override when metrics
// infrastructure is added.

class STTService: FrameProcessor, @unchecked Sendable {

    // MARK: - Configuration (mirrors py:80-114 init params)

    let serviceName: String
    let audioPassthrough: Bool
    let initSampleRate: Int?
    let sttTtfbTimeout: TimeInterval
    let ttfsP99Latency: Double
    let keepaliveTimeout: TimeInterval?
    let keepaliveInterval: TimeInterval

    /// Current language (mirrors pipecat `_settings.language`). Subclasses may
    /// resolve this through `languageToServiceLanguage(_:)` to obtain the
    /// service-specific identifier when calling the underlying STT engine.
    var language: Language?

    // MARK: - State (mirrors py:144-164)

    private(set) var sampleRate: Int = 0

    /// py:148. Set via STTMuteFrame; subclass `processAudioFrame` should
    /// short-circuit when true.
    private(set) var muted: Bool = false

    /// py:149. Carried for forward-compat with multi-user transports
    /// (Daily, Livekit). PhoneClaw is single-user — always "".
    private(set) var userID: String = ""

    /// py:155. Set true between VADUserStartedSpeakingFrame and
    /// VADUserStoppedSpeakingFrame.
    private(set) var userSpeaking: Bool = false

    /// py:156-157. For streaming STT services with explicit finalize protocol.
    /// SegmentedSTT does not use these; preserved for streaming-STT subclasses.
    var finalizePending: Bool = false
    var finalizeRequested: Bool = false

    /// py:158. Time of last TranscriptionFrame push (TTFB calc).
    var lastTranscriptTime: TimeInterval = 0

    /// py:164. Last audio time, used by keepalive task.
    private(set) var lastAudioTime: TimeInterval = 0

    /// py:154. TTFB timeout task (no-op default; streaming subclass schedules).
    var ttfbTimeoutTask: Task<Void, Never>?

    /// py:163. Keepalive task (no-op default; network subclass schedules).
    private var keepaliveTask: Task<Void, Never>?

    // MARK: - Init

    init(
        name: String,
        audioPassthrough: Bool = true,
        sampleRate: Int? = nil,
        sttTtfbTimeout: TimeInterval = 2.0,
        ttfsP99Latency: Double = 1.5,
        keepaliveTimeout: TimeInterval? = nil,
        keepaliveInterval: TimeInterval = 5.0,
        language: Language? = nil
    ) {
        self.serviceName = name
        self.audioPassthrough = audioPassthrough
        self.initSampleRate = sampleRate
        self.sttTtfbTimeout = sttTtfbTimeout
        self.ttfsP99Latency = ttfsP99Latency
        self.keepaliveTimeout = keepaliveTimeout
        self.keepaliveInterval = keepaliveInterval
        self.language = language
        super.init(name: "STTService:\(name)")
    }

    // MARK: - Language conversion (mirrors py:253)

    /// Default impl returns BCP-47 raw value. Subclasses override to map
    /// pipecat-canonical Language to service-specific identifier (e.g.
    /// Google STT uses "cmn-Hans-CN" for Chinese while pipecat canonical
    /// is "zh-CN"). Mirrors pipecat `language_to_service_language(language)`.
    func languageToServiceLanguage(_ language: Language) -> String? {
        return language.rawValue
    }

    // MARK: - Abstract (subclasses must override)

    /// Mirrors `run_stt(audio: bytes) -> AsyncGenerator[Frame]` (py:264).
    /// Swift adapts to `[Float]` samples (no WAV byte round-trip needed —
    /// sherpa-onnx etc. consume `[Float]` directly) and returns a `[Frame]`
    /// array (no Python AsyncGenerator equivalent in Swift; subclass collects
    /// all frames from one inference and returns them).
    func runSTT(audio: [Float]) async -> [Frame] {
        fatalError("\(type(of: self)).runSTT must be overridden")
    }

    // MARK: - Lifecycle (mirrors py:279, 288)

    override func didReceiveStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        sampleRate = initSampleRate ?? Int(frame.audioMetadata?.input?.sampleRate ?? 16000)
        await pushSTTMetadata(context: context)
        startKeepaliveIfNeeded()
    }

    override func didReceiveStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await cancelTTFBTimeout()
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    override func didReceiveCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await cancelTTFBTimeout()
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    // MARK: - Frame routing (mirrors py:364)

    override func process(
        _ frame: Frame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        switch frame {
        case let f as InputAudioRawFrame:
            await processAudioFrame(f, direction: direction, context: context)
            if audioPassthrough {
                await context.push(frame, direction: direction)
            }

        case let f as VADUserStartedSpeakingFrame:
            await handleVADUserStartedSpeaking(f, context: context)
            await context.push(frame, direction: direction)

        case let f as VADUserStoppedSpeakingFrame:
            await handleVADUserStoppedSpeaking(f, context: context)
            await context.push(frame, direction: direction)

        case let f as STTMuteFrame:
            muted = f.mute
            print("[\(serviceName)] \(f.mute ? "muted" : "unmuted")")
            await context.push(frame, direction: direction)

        case is InterruptionFrame:
            await resetSTTTtfbState()
            await context.push(frame, direction: direction)

        case let f as STTUpdateSettingsFrame:
            if let target = f.service, target !== self {
                await context.push(frame, direction: direction)
            } else {
                await handleSettingsUpdate(f)
            }

        default:
            await super.process(frame, direction: direction, context: context)
        }
    }

    // MARK: - Audio processing (mirrors py:331)

    /// Default base implementation: skip if muted, otherwise no-op.
    /// Subclasses (SegmentedSTTService, streaming subclasses) override.
    func processAudioFrame(
        _ frame: InputAudioRawFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        if muted { return }
        lastAudioTime = nowSeconds()
        if let userIDFrame = frame as? UserAudioRawFrameProtocol {
            userID = userIDFrame.userID
        } else {
            userID = ""
        }
        // Subclass adds actual processing.
    }

    // MARK: - VAD handlers (mirrors py:475, 490)

    func handleVADUserStartedSpeaking(
        _ frame: VADUserStartedSpeakingFrame,
        context: FrameProcessorContext
    ) async {
        await resetSTTTtfbState()
        userSpeaking = true
        finalizeRequested = false
        finalizePending = false
        lastTranscriptTime = 0
    }

    func handleVADUserStoppedSpeaking(
        _ frame: VADUserStoppedSpeakingFrame,
        context: FrameProcessorContext
    ) async {
        userSpeaking = false
        // Streaming subclass would schedule TTFB timeout here based on
        // sttTtfbTimeout. SegmentedSTT runs transcribe in its own override.
    }

    // MARK: - Push override (mirrors py:419)

    /// Tracks transcript time for TTFB metrics; auto-promotes finalize_pending
    /// to TranscriptionFrame.finalized.
    func pushTranscript(
        _ frame: TranscriptionFrame,
        direction: FrameDirection = .downstream,
        context: FrameProcessorContext
    ) async {
        lastTranscriptTime = nowSeconds()
        if finalizePending {
            // pipecat sets frame.finalized = true; PhoneClaw TranscriptionFrame
            // does not yet expose this field — TODO: add `finalized: Bool` to
            // TranscriptionFrame mirroring pipecat for full TurnAnalyzer compat.
            finalizePending = false
        }
        await stopTTFBMetrics()
        await cancelTTFBTimeout()
        await context.push(frame, direction: direction)
    }

    // MARK: - Metadata (mirrors py:448)

    private func pushSTTMetadata(context: FrameProcessorContext) async {
        let frame = STTMetadataFrame(serviceName: serviceName, ttfsP99Latency: ttfsP99Latency)
        let upstreamFrame = STTMetadataFrame(serviceName: serviceName, ttfsP99Latency: ttfsP99Latency)
        frame.broadcastSiblingID = upstreamFrame.id
        upstreamFrame.broadcastSiblingID = frame.id
        await context.push(frame, direction: .downstream)
        await context.push(upstreamFrame, direction: .upstream)
    }

    // MARK: - TTFB metrics scaffolding (mirrors py:456, 462)

    /// Placeholder hook. Override when metrics infra is added.
    func startTTFBMetrics() async {}

    /// Placeholder hook. Override when metrics infra is added.
    func stopTTFBMetrics() async {}

    func cancelTTFBTimeout() async {
        ttfbTimeoutTask?.cancel()
        ttfbTimeoutTask = nil
    }

    func resetSTTTtfbState() async {
        await cancelTTFBTimeout()
    }

    // MARK: - Settings update (mirrors py:294)

    /// Placeholder hook. Subclasses override to apply STT-specific settings.
    func handleSettingsUpdate(_ frame: STTUpdateSettingsFrame) async {}

    // MARK: - Keepalive scaffolding (mirrors py:160-163)

    /// Local STT services pass `keepaliveTimeout=nil` and skip the task.
    /// Network subclasses pass a value to enable periodic activity.
    private func startKeepaliveIfNeeded() {
        guard let timeout = keepaliveTimeout, timeout > 0 else { return }
        keepaliveTask = Task { [weak self] in
            await self?.keepaliveLoop(timeout: timeout)
        }
    }

    /// Default no-op loop. Network subclasses override to send keepalive frames.
    func keepaliveLoop(timeout: TimeInterval) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(keepaliveInterval * 1_000_000_000))
            // Subclass override: if (now - lastAudioTime) >= timeout, send silence.
        }
    }

    // MARK: - Helpers

    private func nowSeconds() -> TimeInterval {
        CFAbsoluteTimeGetCurrent()
    }
}

// Mirrors Pipecat `UserAudioRawFrame`'s user_id field. PhoneClaw's
// InputAudioRawFrame does not currently carry user_id (single-user app),
// but the protocol exists for future Daily/LiveKit-style multi-user transports.
protocol UserAudioRawFrameProtocol {
    var userID: String { get }
}

// Mirrors Pipecat `Language` enum (transcriptions/language.py).
//
// Sparse intentionally — add cases as cloud STT subclasses are ported. The
// enum's raw values are pipecat-canonical BCP-47 codes; subclasses that need
// service-specific identifiers override `STTService.languageToServiceLanguage(_:)`.
//
// Current cases cover the languages PhoneClaw's local sherpa-onnx model
// supports plus the most common cloud STT targets. Extend freely.
enum Language: String, Sendable, CaseIterable {
    case zhCN = "zh-CN"   // 简体中文（PhoneClaw 当前默认）
    case zhTW = "zh-TW"   // 繁体中文
    case enUS = "en-US"
    case enGB = "en-GB"
    case jaJP = "ja-JP"
    case koKR = "ko-KR"
    case esES = "es-ES"
    case frFR = "fr-FR"
    case deDE = "de-DE"
}
