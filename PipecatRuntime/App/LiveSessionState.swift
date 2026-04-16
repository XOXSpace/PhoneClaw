import Foundation
import Observation

@Observable
final class LiveSessionState {
    enum Stage: String {
        case idle
        case starting
        case listening
        case userSpeaking
        case assistantSpeaking
        case stopping
        case error
    }

    var stage: Stage = .idle
    var transcript: String = ""
    var interimTranscript: String = ""
    var assistantReply: String = ""
    var caption: String = ""
    var isUserSpeaking = false
    var isBotSpeaking = false
    var lastFrameName = ""
    var lastError = ""
    // Note: incomplete-turn markers (○/◐) are delivered via LiveStateObserver.onIncompleteTurn
    // callback, NOT via a field here, to avoid the LLMFullResponseStartFrame clear-before-consume race.
}
