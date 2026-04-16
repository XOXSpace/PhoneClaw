import Foundation

final class UserTurnProcessor: FrameProcessor, @unchecked Sendable {
    let controller: UserTurnController
    let userIdleController: UserIdleController

    var onUserTurnIdle: (@Sendable () async -> Void)?

    init(
        controller: UserTurnController = UserTurnController(),
        userIdleController: UserIdleController = UserIdleController()
    ) {
        self.controller = controller
        self.userIdleController = userIdleController
        super.init(name: "UserTurnProcessor")
    }

    override func didReceiveStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        // Mirrors Pipecat llm_response_universal.py:566
        // `await self._user_turn_controller.setup(self.task_manager)`
        await controller.setup()
        userIdleController.start()
    }

    override func didReceiveStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        // Mirrors Pipecat _cleanup(): await self._user_turn_controller.cleanup()
        await controller.cleanup()
        controller.clearHandlers()
        userIdleController.stop()
    }

    override func didReceiveCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await controller.cleanup()
        controller.clearHandlers()
        userIdleController.cancel()
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        bindController(to: context)
        bindUserIdleController()

        switch frame {
        case is StartFrame, is StopFrame, is CancelFrame:
            await super.process(frame, direction: direction, context: context)
        default:
            let push: @Sendable (Frame, FrameDirection) async -> Void = { frame, direction in
                await context.push(frame, direction: direction)
            }
            await controller.processFrame(frame, direction: direction, push: push)
            // Default pass-through — processFrame does not push frames by itself
            await context.push(frame, direction: direction)
        }

        await userIdleController.process(frame)
    }

    private func bindController(to context: FrameProcessorContext) {
        controller.onUserTurnStarted = { [weak self] _, params in
            guard let self else { return }

            if params.enableUserSpeakingFrames {
                await self.broadcast(UserStartedSpeakingFrame(), context: context)
                await self.userIdleController.process(UserStartedSpeakingFrame())
            }
            if params.enableInterruptions {
                await self.broadcast(InterruptionFrame(), context: context)
            }
        }

        controller.onUserTurnStopped = { [weak self] _, params in
            guard let self else { return }

            if params.enableUserSpeakingFrames {
                await self.broadcast(UserStoppedSpeakingFrame(), context: context)
                await self.userIdleController.process(UserStoppedSpeakingFrame())
            }
            await context.push(
                UserTurnCommittedFrame(wasInterruptedTurn: false),
                direction: .downstream
            )
        }
    }

    private func bindUserIdleController() {
        userIdleController.onUserTurnIdle = { [weak self] in
            guard let self else { return }
            await self.onUserTurnIdle?()
        }
    }

    private func broadcast(
        _ frame: @autoclosure () -> Frame,
        context: FrameProcessorContext
    ) async {
        let downstreamFrame = frame()
        let upstreamFrame = frame()
        downstreamFrame.broadcastSiblingID = upstreamFrame.id
        upstreamFrame.broadcastSiblingID = downstreamFrame.id

        await context.push(downstreamFrame, direction: .downstream)
        await context.push(upstreamFrame, direction: .upstream)
    }
}
