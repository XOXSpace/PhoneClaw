import Foundation

final class InputAudioRawFrame: SystemFrame, @unchecked Sendable {
    let chunk: AudioChunk

    init(chunk: AudioChunk) {
        self.chunk = chunk
        super.init()
    }
}

class OutputAudioRawFrame: DataFrame, @unchecked Sendable {
    let chunk: AudioChunk

    init(chunk: AudioChunk) {
        self.chunk = chunk
        super.init()
    }
}

final class TTSAudioRawFrame: OutputAudioRawFrame, @unchecked Sendable {
    let contextID: String?

    init(chunk: AudioChunk, contextID: String? = nil) {
        self.contextID = contextID
        super.init(chunk: chunk)
    }
}

class BaseTranscriptionFrame: TextFrame, @unchecked Sendable {
    let language: String?
    /// Mirrors pipecat `TranscriptionFrame.finalized` (frames.py).
    /// - true (default): final transcript for a complete utterance.
    /// - false: streaming partial — equivalent to InterimTranscriptionFrame
    ///   semantics but unified on TranscriptionFrame per pipecat's modern
    ///   convention (stt_service.py:431-444 promotes finalize_pending → frame.finalized).
    /// Aggregator/turn strategies treat finalized=true as commit-ready signal.
    var finalized: Bool

    init(text: String, language: String? = nil, finalized: Bool = true) {
        self.language = language
        self.finalized = finalized
        super.init(text: text)
    }
}

final class InterimTranscriptionFrame: BaseTranscriptionFrame, @unchecked Sendable {}

final class TranscriptionFrame: BaseTranscriptionFrame, @unchecked Sendable {}

// PhoneClaw-specific extension — NOT part of Pipecat's frame surface.
// Carries the partial barge-in transcript from SherpaSTT's streaming pass (upstream direction).
// OBSERVABILITY-ONLY / FUTURE-USE: no current consumer exists in PipecatRuntime or Agent/.
// Emitted by SherpaSTTServiceAdapter during interruption streaming; currently observed in tests only.
// The empty-payload variant from BotSpeechGateProcessor was removed as dead code.
// Pipecat cloud STT has no equivalent; barge-in transcript state is internal to the STT service.
final class InterruptionCandidateFrame: DataFrame, @unchecked Sendable {
    let transcript: String
    let unitCount: Int

    init(transcript: String, unitCount: Int) {
        self.transcript = transcript
        self.unitCount = unitCount
        super.init()
    }
}
