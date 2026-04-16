import Foundation

final class AlwaysUserMuteStrategy: BaseUserMuteStrategy, @unchecked Sendable {
    private var botSpeaking = false

    override func reset() async {
        botSpeaking = false
    }

    override func processFrame(_ frame: Frame) async -> Bool {
        switch frame {
        case is BotStartedSpeakingFrame:
            botSpeaking = true
        case is BotStoppedSpeakingFrame:
            botSpeaking = false
        default:
            break
        }

        return botSpeaking
    }
}
