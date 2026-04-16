import Foundation

struct AudioFormatDescriptor: Sendable, Equatable {
    let sampleRate: Double
    let channelCount: Int

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

struct StartFrameAudioMetadata: Sendable, Equatable {
    let input: AudioFormatDescriptor?
    let output: AudioFormatDescriptor?

    init(input: AudioFormatDescriptor? = nil, output: AudioFormatDescriptor? = nil) {
        self.input = input
        self.output = output
    }
}

struct VADParams: Sendable, Equatable {
    let confidence: Double
    let startSecs: Double
    let stopSecs: Double
    let minVolume: Double

    init(
        confidence: Double = 0.7,
        startSecs: Double = 0.2,
        stopSecs: Double = 0.2,
        minVolume: Double = 0.6
    ) {
        self.confidence = confidence
        self.startSecs = startSecs
        self.stopSecs = stopSecs
        self.minVolume = minVolume
    }
}

final class StartFrame: SystemFrame, @unchecked Sendable {
    let audioMetadata: StartFrameAudioMetadata?

    init(audioMetadata: StartFrameAudioMetadata? = nil) {
        self.audioMetadata = audioMetadata
        super.init()
    }
}

class TaskFrame: ControlFrame, @unchecked Sendable {}

class TaskSystemFrame: SystemFrame, @unchecked Sendable {}

final class EndTaskFrame: TaskFrame, UninterruptibleFrame, @unchecked Sendable {
    let reason: Any?

    init(reason: Any? = nil) {
        self.reason = reason
        super.init()
    }
}

final class StopTaskFrame: TaskFrame, UninterruptibleFrame, @unchecked Sendable {}

final class CancelTaskFrame: TaskSystemFrame, @unchecked Sendable {
    let reason: Any?

    init(reason: Any? = nil) {
        self.reason = reason
        super.init()
    }
}

final class InterruptionTaskFrame: TaskSystemFrame, @unchecked Sendable {}

final class EndFrame: ControlFrame, UninterruptibleFrame, @unchecked Sendable {
    let reason: Any?

    init(reason: Any? = nil) {
        self.reason = reason
        super.init()
    }
}

final class StopFrame: ControlFrame, UninterruptibleFrame, @unchecked Sendable {}

final class CancelFrame: SystemFrame, @unchecked Sendable {
    let reason: Any?

    init(reason: Any? = nil) {
        self.reason = reason
        super.init()
    }
}

final class HeartbeatFrame: ControlFrame, @unchecked Sendable {
    let timestamp: UInt64

    init(timestamp: UInt64 = 0) {
        self.timestamp = timestamp
        super.init()
    }
}

final class FrameProcessorPauseUrgentFrame: SystemFrame, @unchecked Sendable {
    let processor: FrameProcessor

    init(processor: FrameProcessor) {
        self.processor = processor
        super.init()
    }
}

final class FrameProcessorResumeUrgentFrame: SystemFrame, @unchecked Sendable {
    let processor: FrameProcessor

    init(processor: FrameProcessor) {
        self.processor = processor
        super.init()
    }
}

// PhoneClaw-specific extension — NOT part of Pipecat's frame surface.
// Pipecat only has `InterruptionFrame` (frames.py:873).
// These gate signals are required for local STT (SherpaASR) lifecycle control:
//   BotSpeechGateProcessor → [pipeline] → SherpaSTTServiceAdapter
// They are structurally unavoidable when two separate FrameProcessor nodes
// need to coordinate over the pipeline. Cloud-based Pipecat has no equivalent
// because cloud STT does not require intra-pipeline gate control.
final class StartInterruptionFrame: SystemFrame, @unchecked Sendable {}

final class StopInterruptionFrame: SystemFrame, @unchecked Sendable {}

// Pipecat-native frame (frames.py:873). Emitted by PipelineTask on barge-in.
final class InterruptionFrame: SystemFrame, @unchecked Sendable {}

// Mirrors Pipecat `STTMuteFrame` (frames.py:1063).
// SystemFrame so it bypasses normal queue and reaches STT immediately.
// Set `mute=true` to make STTService skip audio processing; `mute=false` resumes.
final class STTMuteFrame: SystemFrame, @unchecked Sendable {
    let mute: Bool
    init(mute: Bool) {
        self.mute = mute
        super.init()
    }
}

// Mirrors Pipecat `STTMetadataFrame` (frames.py).
// Broadcast by STTService at startup so downstream processors (e.g.
// TurnAnalyzerUserTurnStopStrategy) can compute timeouts based on STT P99 latency.
final class STTMetadataFrame: SystemFrame, @unchecked Sendable {
    let serviceName: String
    let ttfsP99Latency: Double
    init(serviceName: String, ttfsP99Latency: Double) {
        self.serviceName = serviceName
        self.ttfsP99Latency = ttfsP99Latency
        super.init()
    }
}

final class FrameProcessorPauseFrame: ControlFrame, @unchecked Sendable {
    let processor: FrameProcessor

    init(processor: FrameProcessor) {
        self.processor = processor
        super.init()
    }
}

final class FrameProcessorResumeFrame: ControlFrame, @unchecked Sendable {
    let processor: FrameProcessor

    init(processor: FrameProcessor) {
        self.processor = processor
        super.init()
    }
}

final class UserSpeakingFrame: SystemFrame, @unchecked Sendable {}

final class UserIdleTimeoutUpdateFrame: SystemFrame, @unchecked Sendable {
    let timeout: TimeInterval

    init(timeout: TimeInterval) {
        self.timeout = timeout
        super.init()
    }
}

final class SpeechControlParamsFrame: SystemFrame, @unchecked Sendable {
    let vadParams: VADParams?
    let turnParams: (any Sendable)?

    init(vadParams: VADParams? = nil, turnParams: (any Sendable)? = nil) {
        self.vadParams = vadParams
        self.turnParams = turnParams
        super.init()
    }
}

final class VADParamsUpdateFrame: ControlFrame, @unchecked Sendable {
    let params: VADParams

    init(params: VADParams) {
        self.params = params
        super.init()
    }
}

final class VADUserStartedSpeakingFrame: SystemFrame, @unchecked Sendable {
    let startSecs: Double
    let timestamp: TimeInterval

    init(startSecs: Double = 0.0, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.startSecs = startSecs
        self.timestamp = timestamp
        super.init()
    }
}

final class VADUserStoppedSpeakingFrame: SystemFrame, @unchecked Sendable {
    let stopSecs: Double
    let timestamp: TimeInterval

    init(stopSecs: Double = 0.0, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.stopSecs = stopSecs
        self.timestamp = timestamp
        super.init()
    }
}

// Pipecat-native frames (frames.py:885, 896).
final class UserStartedSpeakingFrame: SystemFrame, @unchecked Sendable {}

final class UserStoppedSpeakingFrame: SystemFrame, @unchecked Sendable {}

// PhoneClaw-specific extension — NOT part of Pipecat's frame surface.
// Required for batch-mode local STT (SherpaASR): Pipecat uses real-time cloud STT
// that streams transcriptions as speech occurs. SherpaASR runs batch transcription
// over the full turn audio after the turn ends, so it needs this committed signal
// to know when to call transcribe(). There is no Pipecat equivalent.
final class UserTurnCommittedFrame: DataFrame, @unchecked Sendable {
    let wasInterruptedTurn: Bool

    init(wasInterruptedTurn: Bool) {
        self.wasInterruptedTurn = wasInterruptedTurn
        super.init()
    }
}

final class BotStartedSpeakingFrame: SystemFrame, @unchecked Sendable {}

final class BotStoppedSpeakingFrame: SystemFrame, @unchecked Sendable {}

final class BotSpeakingFrame: SystemFrame, @unchecked Sendable {}

final class UserMuteStartedFrame: SystemFrame, @unchecked Sendable {}

final class UserMuteStoppedFrame: SystemFrame, @unchecked Sendable {}

final class TTSStartedFrame: ControlFrame, @unchecked Sendable {
    let contextID: String?

    init(contextID: String? = nil) {
        self.contextID = contextID
        super.init()
    }
}

final class TTSStoppedFrame: ControlFrame, @unchecked Sendable {
    let contextID: String?

    init(contextID: String? = nil) {
        self.contextID = contextID
        super.init()
    }
}

final class ErrorFrame: SystemFrame, @unchecked Sendable {
    let message: String
    let fatal: Bool
    let underlyingErrorDescription: String?

    init(message: String, fatal: Bool = false, underlyingError: Error? = nil) {
        self.message = message
        self.fatal = fatal
        self.underlyingErrorDescription = underlyingError.map { String(describing: $0) }
        super.init()
    }
}
