import Foundation

final class BotSpeechGateProcessor: FrameProcessor, @unchecked Sendable {
    private var isBotSpeaking = false
    private var pendingInterruption = false

    init() {
        super.init(name: "BotSpeechGateProcessor")
    }

    override func didReceiveStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
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
        case is BotStartedSpeakingFrame:
            isBotSpeaking = true
            pendingInterruption = false
            await context.push(frame, direction: direction)

        case is BotStoppedSpeakingFrame:
            isBotSpeaking = false
            pendingInterruption = false
            await context.push(frame, direction: direction)

        case is VADUserStartedSpeakingFrame where isBotSpeaking:
            guard !pendingInterruption else { return }
            pendingInterruption = true
            await context.push(StartInterruptionFrame(), direction: direction)

        case is VADUserStoppedSpeakingFrame where pendingInterruption:
            pendingInterruption = false
            await context.push(StopInterruptionFrame(), direction: direction)

        case is UserStartedSpeakingFrame where isBotSpeaking:
            guard !pendingInterruption else { return }
            pendingInterruption = true
            await context.push(StartInterruptionFrame(), direction: direction)

        case is UserStoppedSpeakingFrame where pendingInterruption:
            pendingInterruption = false
            await context.push(StopInterruptionFrame(), direction: direction)

        default:
            await context.push(frame, direction: direction)
        }
    }

    private func reset() {
        isBotSpeaking = false
        pendingInterruption = false
    }
}
