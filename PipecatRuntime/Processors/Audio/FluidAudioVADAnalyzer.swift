import Foundation
import FluidAudio

// Mirrors Pipecat `SileroVADAnalyzer` role, bridged to FluidAudio VadManager.
//
// Source-iso boundary discussion:
//
//   pipecat layering:
//     SileroVADAnalyzer.voice_confidence(audio) -> Float
//       └─ SileroOnnxModel.__call__ (raw probability)
//     VADAnalyzer._run_analyzer (base class hysteresis: confidence vs
//       threshold + volume vs min_volume + dwell counts)
//
//   FluidAudio layering:
//     VadManager.processStreamingChunk(audio, state, config) -> VadStreamResult
//       ├─ ONNX inference (raw probability — internal)
//       └─ Streaming state machine (threshold + negativeThresholdOffset +
//          minSilenceDuration hysteresis, model-tuned for Silero v6 256ms)
//
// We treat FluidAudio's `processStreamingChunk` as the equivalent black-box
// of pipecat's whole "voice_confidence + base-class hysteresis" pair —
// because FluidAudio has already done the v6-specific tuning that pipecat's
// base hysteresis does for the 32ms variant. Re-implementing pipecat's
// dwell/threshold loop on top of v6 raw probabilities produced no speech
// detection at all in practice (probabilities never crossed pipecat's 0.7
// default, while v6 is tuned around 0.85 with negative-threshold-offset
// hysteresis).
//
// The analyzer therefore:
//   - persists `VadStreamState` (FluidAudio's state machine state) across
//     calls, advancing it via `processStreamingChunk` results
//   - maps `VadStreamEvent.Kind` -> `VADState` (.speechStart -> .speaking,
//     .speechEnd -> .quiet)
//   - holds `lastState` as the latest stable VADState until the next event
//
// VADParams.stopSecs is forwarded into `VadSegmentationConfig.minSilenceDuration`,
// preserving the pipecat parameter as the user-facing knob.

final class FluidAudioVADAnalyzer: VADAnalyzerProtocol {

    // MARK: - Protocol conformance

    private(set) var params: VADParams = VADParams()

    // MARK: - State

    private var manager: VadManager?
    private var streamState: VadStreamState?
    private var pendingSamples: [Float] = []
    /// Latest stable VAD state — updated only when FluidAudio emits a
    /// `.speechStart` / `.speechEnd` event. Mirrors the role of pipecat's
    /// `_vad_state` in the base class.
    private var lastState: VADState = .quiet

    private let chunkSamples = VadManager.chunkSize

    // MARK: - Init

    init(manager: VadManager? = nil) {
        self.manager = manager
    }

    // MARK: - Prepare (Phase 1.5 hook)

    /// Eager async load. Intended to be called from `VADController.setup()`
    /// so the first audio frame doesn't block on model init. Currently also
    /// invoked lazily from `analyzeAudio` as a fallback if setup-time wiring
    /// hasn't been added yet.
    func prepare() async {
        guard manager == nil else { return }
        do {
            let m = try await VadManager()
            manager = m
            streamState = await m.makeStreamState()
        } catch {
            print("[FluidAudioVADAnalyzer] VadManager init failed: \(error)")
        }
    }

    // MARK: - VADAnalyzerProtocol

    func setSampleRate(_ rate: Int) {
        // FluidAudio's Silero v6 model is fixed at 16 kHz. Sample-rate
        // assertions live in the upstream pipeline (StartFrame metadata).
    }

    func setParams(_ newParams: VADParams) {
        params = newParams
    }

    func analyzeAudio(_ samples: [Float]) async -> VADState {
        if manager == nil { await prepare() }
        guard let manager, var state = streamState else { return lastState }

        pendingSamples.append(contentsOf: samples)

        // Map pipecat VADParams to FluidAudio segmentation config.
        // - minSilenceDuration mirrors `params.stopSecs`
        // - other fields keep FluidAudio defaults (model-tuned for Silero v6)
        let segConfig = VadSegmentationConfig(
            minSilenceDuration: TimeInterval(params.stopSecs)
        )

        // DEBUG(P0-probe): Log every analyze call so we can see if audio
        // actually reaches this layer. TODO: remove once live TTS verified.
        print("[FluidVAD] analyze samples=\(samples.count) pending=\(pendingSamples.count) lastState=\(lastState)")

        while pendingSamples.count >= chunkSamples {
            let chunk = Array(pendingSamples.prefix(chunkSamples))
            pendingSamples.removeFirst(chunkSamples)
            do {
                let result = try await manager.processStreamingChunk(
                    chunk, state: state, config: segConfig
                )
                state = result.state
                // DEBUG(P0-probe): one line per 4096-sample chunk — tells us
                // (a) probability distribution from the v6 model on real mic
                // (b) whether FluidAudio's state machine fires speech events
                let eventTag: String
                if let ev = result.event {
                    eventTag = (ev.kind == .speechStart) ? "START" : "END"
                } else {
                    eventTag = "-"
                }
                print("[FluidVAD] chunk p=\(String(format: "%.3f", result.probability)) event=\(eventTag) triggered=\(state.triggered)")

                if let event = result.event {
                    switch event.kind {
                    case .speechStart:
                        lastState = .speaking
                    case .speechEnd:
                        lastState = .quiet
                    }
                }
            } catch {
                print("[FluidAudioVADAnalyzer] inference failed: \(error)")
            }
        }
        streamState = state
        return lastState
    }

    func cleanup() async {
        manager = nil
        streamState = nil
        pendingSamples.removeAll()
        lastState = .quiet
    }
}
