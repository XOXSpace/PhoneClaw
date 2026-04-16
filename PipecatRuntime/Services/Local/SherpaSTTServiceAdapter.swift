import AVFoundation
import Foundation

struct STTStreamingResult: Equatable, Sendable {
    let text: String
    let unitCount: Int

    static let empty = STTStreamingResult(text: "", unitCount: 0)
}

protocol STTServicing: AnyObject {
    var isAvailable: Bool { get }
    func initialize()
    func transcribe(samples: [Float], sampleRate: Int) -> String
    func beginStreaming()
    func appendStreamingResult(samples: [Float], sampleRate: Int) -> STTStreamingResult
    func endStreamingResult(sampleRate: Int) -> STTStreamingResult
    func cancelStreaming()
    func canonicalizeRuntimeSettings(_ delta: STTSettings) -> STTSettings
    func applyRuntimeSettings(_ settings: STTSettings, changed: [String: Any]) async
}

extension STTServicing {
    func canonicalizeRuntimeSettings(_ delta: STTSettings) -> STTSettings {
        delta
    }

    func applyRuntimeSettings(_ settings: STTSettings, changed: [String: Any]) async {}
}

extension ASRService: STTServicing {
    func appendStreamingResult(samples: [Float], sampleRate: Int) -> STTStreamingResult {
        let result = appendStreaming(samples: samples, sampleRate: sampleRate)
        return STTStreamingResult(text: result.text, unitCount: result.unitCount)
    }

    func endStreamingResult(sampleRate: Int) -> STTStreamingResult {
        let result = endStreaming(sampleRate: sampleRate)
        return STTStreamingResult(text: result.text, unitCount: result.unitCount)
    }
}

final class SherpaSTTServiceAdapter: FrameProcessor, @unchecked Sendable {
    private let service: STTServicing
    private let settings = STTSettings.defaultStore()
    private var currentTurnSamples: [Float] = []
    private var isBufferingTurnAudio = false
    private var interruptionStreamingActive = false
    private var interruptionPromoted = false
    private var lastInterimTranscript = ""
    private var sampleRate = 16_000

    init(service: STTServicing = ASRService()) {
        self.service = service
        super.init(name: "SherpaSTTServiceAdapter")
    }

    override func didReceiveStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        if let inputSampleRate = frame.audioMetadata?.input?.sampleRate {
            sampleRate = Int(inputSampleRate.rounded())
        }
        if !service.isAvailable {
            service.initialize()
        }
        reset()
    }

    override func didReceiveStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        reset()
    }

    override func didReceiveCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        reset()
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        switch frame {
        case let frame as InputAudioRawFrame:
            await handleInputAudio(frame, direction: direction, context: context)

        // pipecat-iso: with STT placed upstream of LLMUserAggregator (matching
        // `06a-voice-agent-local.py` pipeline order), aggregator-emitted frames
        // (UserStartedSpeakingFrame / UserTurnCommittedFrame) flow downstream
        // and never reach STT. Use VAD broadcast frames instead — they are
        // pushed both directions by VADController, so upstream STT receives
        // them. This mirrors how pipecat's streaming STTs operate on raw
        // audio + VAD signals (not on aggregator-level turn frames).
        case is VADUserStartedSpeakingFrame:
            print("[SherpaSTT] VADUserStartedSpeaking — begin turn buffer")
            if !interruptionStreamingActive {
                currentTurnSamples = []
            }
            isBufferingTurnAudio = true
            await context.push(frame, direction: direction)

        case is VADUserStoppedSpeakingFrame:
            print("[SherpaSTT] VADUserStoppedSpeaking — running batch transcribe")
            await handleBatchTranscribe(direction: direction, context: context)
            await context.push(frame, direction: direction)

        case is StartInterruptionFrame:
            print("[SherpaSTT] StartInterruption — beginStreaming")
            service.beginStreaming()
            interruptionStreamingActive = true
            interruptionPromoted = false
            lastInterimTranscript = ""
            currentTurnSamples = []
            isBufferingTurnAudio = true
            await context.push(frame, direction: direction)

        case is InterruptionFrame:
            interruptionPromoted = true
            await context.push(frame, direction: direction)

        case is StopInterruptionFrame:
            if interruptionStreamingActive {
                let result = service.endStreamingResult(sampleRate: sampleRate)
                await emitInterruptionUpdates(result, context: context)
            }
            interruptionStreamingActive = false
            lastInterimTranscript = ""

            if !interruptionPromoted {
                currentTurnSamples = []
                isBufferingTurnAudio = false
            }

            await context.push(frame, direction: direction)

        case let frame as UserTurnCommittedFrame:
            // Legacy compat path — UserTurnCommittedFrame is still emitted by
            // aggregator's onUserTurnStopped, but with STT now upstream the
            // batch transcribe has already run on VADUserStoppedSpeakingFrame.
            // This handler is a no-op pass-through under the new pipeline.
            await context.push(frame, direction: direction)

        case let frame as STTUpdateSettingsFrame:
            if let target = frame.service, target !== self {
                await context.push(frame, direction: direction)
            } else if let delta = frame.sttDelta {
                await applySettings(delta)
            } else if !frame.settings.isEmpty {
                await applySettings(STTSettings.fromMapping(frame.settings))
            }

        default:
            await context.push(frame, direction: direction)
        }
    }

    private func handleInputAudio(
        _ frame: InputAudioRawFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        let samples = frame.chunk.extractMonoSamples()
        guard !samples.isEmpty else {
            await context.push(frame, direction: direction)
            return
        }

        if isBufferingTurnAudio {
            currentTurnSamples.append(contentsOf: samples)
        }

        if interruptionStreamingActive {
            let result = service.appendStreamingResult(samples: samples, sampleRate: sampleRate)
            await emitInterruptionUpdates(result, context: context)
        }

        await context.push(frame, direction: direction)
    }

    private func handleCommittedTurn(
        _ frame: UserTurnCommittedFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        // Retained for backward compatibility (test paths that drive the
        // adapter via the old UserTurnCommittedFrame contract). Under the
        // current pipecat-iso pipeline this is unreachable — see the
        // VADUserStoppedSpeakingFrame branch which calls handleBatchTranscribe.
        await handleBatchTranscribe(direction: direction, context: context)
        await context.push(frame, direction: direction)
    }

    /// Mirrors pipecat's streaming-STT contract emitting TranscriptionFrame
    /// downstream the moment a turn ends. Triggered by VADUserStoppedSpeakingFrame
    /// in the new pipeline order (STT upstream of LLMUserAggregator).
    private func handleBatchTranscribe(
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        defer {
            currentTurnSamples = []
            isBufferingTurnAudio = false
            interruptionPromoted = false
            interruptionStreamingActive = false
            lastInterimTranscript = ""
        }

        guard !currentTurnSamples.isEmpty else { return }

        let transcript = service.transcribe(samples: currentTurnSamples, sampleRate: sampleRate)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print("[SherpaSTT] committed samples=\(currentTurnSamples.count) transcript=\"\(transcript)\"")

        if !transcript.isEmpty {
            await context.push(TranscriptionFrame(text: transcript), direction: .downstream)
        }
    }

    private func emitInterruptionUpdates(
        _ result: STTStreamingResult,
        context: FrameProcessorContext
    ) async {
        await context.push(
            InterruptionCandidateFrame(
                transcript: result.text,
                unitCount: result.unitCount
            ),
            direction: .upstream
        )

        guard !result.text.isEmpty, result.text != lastInterimTranscript else { return }
        lastInterimTranscript = result.text
        await context.push(InterimTranscriptionFrame(text: result.text), direction: .downstream)
    }

    private func reset() {
        service.cancelStreaming()
        currentTurnSamples = []
        isBufferingTurnAudio = false
        interruptionStreamingActive = false
        interruptionPromoted = false
        lastInterimTranscript = ""
    }

    private func applySettings(_ delta: STTSettings) async {
        let normalized = service.canonicalizeRuntimeSettings(delta.copy())
        let changed = settings.applyUpdate(normalized)
        await service.applyRuntimeSettings(settings.copy(), changed: changed)
    }
}
