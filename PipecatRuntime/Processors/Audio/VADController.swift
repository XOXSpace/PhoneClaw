import Foundation

// Mirrors Pipecat `audio/vad/vad_controller.py:32`
// Manages VAD state transitions and emits speech events.
// Lives inside LLMUserAggregator (replaces standalone VADProcessor node in pipeline).

final class VADController {

    // MARK: - Event callbacks (mirrors Pipecat event_handler pattern)

    var onSpeechStarted: (() async -> Void)?
    var onSpeechStopped: (() async -> Void)?
    var onSpeechActivity: (() async -> Void)?
    var onPushFrame: ((Frame, FrameDirection) async -> Void)?
    var onBroadcastFrame: ((() -> Frame) async -> Void)?

    // MARK: - State (mirrors py:91-104)

    private let vadAnalyzer: VADAnalyzerProtocol
    private var vadState: VADState = .quiet          // mirrors _vad_state

    private let speechActivityPeriod: TimeInterval   // mirrors _speech_activity_period
    private var speechActivityTime: TimeInterval = 0 // mirrors _speech_activity_time

    private let audioIdleTimeout: TimeInterval       // mirrors _audio_idle_timeout
    private var lastAudioTime: TimeInterval = 0      // mirrors _last_audio_time
    private var audioIdleTask: Task<Void, Never>?    // mirrors _audio_idle_task

    // MARK: - Init (mirrors py:71)

    init(
        vadAnalyzer: VADAnalyzerProtocol,
        speechActivityPeriod: TimeInterval = 0.2,
        audioIdleTimeout: TimeInterval = 1.0
    ) {
        self.vadAnalyzer = vadAnalyzer
        self.speechActivityPeriod = speechActivityPeriod
        self.audioIdleTimeout = audioIdleTimeout
    }

    // MARK: - Lifecycle

    /// Mirrors `setup(task_manager)` → py:113
    func setup(sampleRate: Int) async {
        vadAnalyzer.setSampleRate(sampleRate)
        lastAudioTime = Date().timeIntervalSince1970
        if audioIdleTimeout > 0 {
            startAudioIdleTask()
        }
    }

    /// Mirrors `cleanup()` → py:149
    func cleanup() async {
        audioIdleTask?.cancel()
        audioIdleTask = nil
        await vadAnalyzer.cleanup()
    }

    // MARK: - Frame processing

    /// Mirrors `process_frame(frame)` → py:127
    func processFrame(_ frame: Frame) async {
        if let f = frame as? StartFrame {
            await handleStart(f)
        } else if let f = frame as? InputAudioRawFrame {
            await handleAudio(f)
        } else if let f = frame as? VADParamsUpdateFrame {
            vadAnalyzer.setParams(f.params)
            await onBroadcastFrame?({ SpeechControlParamsFrame(vadParams: f.params) })
        }
    }

    // MARK: - Private handlers

    /// Mirrors `_start(frame)` → py:144
    private func handleStart(_ frame: StartFrame) async {
        vadAnalyzer.setSampleRate(Int(frame.audioMetadata?.input?.sampleRate ?? 16000))
        // Broadcast initial VAD params (mirrors py:147 broadcast_frame SpeechControlParamsFrame)
        let p = vadAnalyzer.params
        await onBroadcastFrame?({ SpeechControlParamsFrame(vadParams: p) })
    }

    /// Mirrors `_handle_audio(frame)` → py:163
    private func handleAudio(_ frame: InputAudioRawFrame) async {
        lastAudioTime = Date().timeIntervalSince1970
        let samples = frame.chunk.extractMonoSamples()
        vadState = await handleVAD(samples: samples, currentState: vadState)

        if vadState == .speaking {
            await maybeSpeechActivity()
        }
    }

    /// Mirrors `_handle_vad(audio, vad_state)` → py:179
    private func handleVAD(samples: [Float], currentState: VADState) async -> VADState {
        let newState = await vadAnalyzer.analyzeAudio(samples)

        // DEBUG(P0-probe): log every state return from analyzer so we can
        // see whether hysteresis in the analyzer ever yields a transition.
        if newState != currentState {
            print("[VADController] state \(currentState) -> \(newState)")
        }

        // Only fire events on stable transitions (STARTING / STOPPING are transient)
        if newState != currentState &&
           newState != .starting &&
           newState != .stopping {
            if newState == .speaking {
                print("[VADController] fire onSpeechStarted")
                await onSpeechStarted?()
            } else if newState == .quiet {
                print("[VADController] fire onSpeechStopped")
                await onSpeechStopped?()
            }
            return newState
        }
        return currentState
    }

    /// Mirrors `_maybe_speech_activity()` → py:218
    private func maybeSpeechActivity() async {
        let now = Date().timeIntervalSince1970
        if now - speechActivityTime >= speechActivityPeriod {
            speechActivityTime = now
            await onSpeechActivity?()
        }
    }

    /// Mirrors `_audio_idle_handler()` → py:195
    /// Forces speech stop when no audio frames arrive (e.g. mic muted mid-speech).
    private func startAudioIdleTask() {
        audioIdleTask?.cancel()
        audioIdleTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let deadline = self.lastAudioTime + self.audioIdleTimeout
                let remaining = deadline - Date().timeIntervalSince1970
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    continue
                }
                if self.vadState == .speaking {
                    self.vadState = .quiet
                    await self.onSpeechStopped?()
                }
                try? await Task.sleep(nanoseconds: UInt64(self.audioIdleTimeout * 1_000_000_000))
            }
        }
    }
}
