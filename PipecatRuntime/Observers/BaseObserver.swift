import Foundation

struct FrameProcessed: Sendable {
    let processor: FrameProcessor
    let frame: Frame
    let direction: FrameDirection
    let timestamp: UInt64
}

struct FramePushed: Sendable {
    let source: FrameProcessor
    let destination: FrameProcessor
    let frame: Frame
    let direction: FrameDirection
    let timestamp: UInt64
}

protocol BaseObserver: AnyObject {
    func onProcessFrame(_ data: FrameProcessed) async
    func onPushFrame(_ data: FramePushed) async
    func onPipelineStarted() async
    func onPipelineFinished(_ frame: Frame) async
}

extension BaseObserver {
    func onProcessFrame(_ data: FrameProcessed) async {}
    func onPushFrame(_ data: FramePushed) async {}
    func onPipelineStarted() async {}
    func onPipelineFinished(_ frame: Frame) async {}
}
