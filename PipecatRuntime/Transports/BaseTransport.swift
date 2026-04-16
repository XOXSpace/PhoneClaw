import Foundation

class BaseTransport: FrameProcessor, @unchecked Sendable {
    typealias FrameInjector = @Sendable (Frame, FrameDirection) async -> Void

    private let injectorLock = NSLock()
    private var injector: FrameInjector?

    override func didReceiveStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        setInjector(context: context)
        await transportDidStart(frame, direction: direction, context: context)
    }

    override func didReceiveStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await transportDidStop(frame, direction: direction, context: context)
        clearInjector()
    }

    override func didReceiveCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await transportDidCancel(frame, direction: direction, context: context)
        clearInjector()
    }

    func transportDidStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {}

    func transportDidStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {}

    func transportDidCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {}

    func emit(_ frame: Frame, direction: FrameDirection = .downstream) {
        let injector = injectorLock.withLock { self.injector }
        guard let injector else { return }

        Task {
            await injector(frame, direction)
        }
    }

    func emitAsync(_ frame: Frame, direction: FrameDirection = .downstream) async {
        let injector = injectorLock.withLock { self.injector }
        guard let injector else { return }
        await injector(frame, direction)
    }

    func emitBroadcast(_ frame: @autoclosure @escaping () -> Frame) {
        let injector = injectorLock.withLock { self.injector }
        guard let injector else { return }

        Task {
            let downstreamFrame = frame()
            let upstreamFrame = frame()
            downstreamFrame.broadcastSiblingID = upstreamFrame.id
            upstreamFrame.broadcastSiblingID = downstreamFrame.id

            await injector(downstreamFrame, .downstream)
            await injector(upstreamFrame, .upstream)
        }
    }

    func emitBroadcastAsync(_ frame: @autoclosure () -> Frame) async {
        let injector = injectorLock.withLock { self.injector }
        guard let injector else { return }

        let downstreamFrame = frame()
        let upstreamFrame = frame()
        downstreamFrame.broadcastSiblingID = upstreamFrame.id
        upstreamFrame.broadcastSiblingID = downstreamFrame.id

        await injector(downstreamFrame, .downstream)
        await injector(upstreamFrame, .upstream)
    }

    func stampTransportMetadata(
        _ frame: Frame,
        transportSource: String? = nil,
        transportDestination: String? = nil,
        overwrite: Bool = false
    ) {
        if overwrite || frame.transportSource == nil {
            frame.transportSource = transportSource
        }
        if overwrite || frame.transportDestination == nil {
            frame.transportDestination = transportDestination
        }
    }

    private func setInjector(context: FrameProcessorContext) {
        let injector: FrameInjector = { frame, direction in
            await context.push(frame, direction: direction)
        }
        injectorLock.withLock {
            self.injector = injector
        }
    }

    private func clearInjector() {
        injectorLock.withLock {
            self.injector = nil
        }
    }
}
