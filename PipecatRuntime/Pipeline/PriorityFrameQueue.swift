import Foundation

struct QueuedFrame: Sendable {
    let frame: Frame
    let direction: FrameDirection
    let sourceProcessorIndex: Int?
}

struct PriorityFrameQueue: Sendable {
    private var systemFrames: [QueuedFrame] = []
    private var regularFrames: [QueuedFrame] = []

    var isEmpty: Bool {
        systemFrames.isEmpty && regularFrames.isEmpty
    }

    var count: Int {
        systemFrames.count + regularFrames.count
    }

    mutating func enqueue(_ item: QueuedFrame) {
        if item.frame.isSystemFrame {
            systemFrames.append(item)
        } else {
            regularFrames.append(item)
        }
    }

    mutating func dequeue() -> QueuedFrame? {
        if !systemFrames.isEmpty {
            return systemFrames.removeFirst()
        }
        guard !regularFrames.isEmpty else {
            return nil
        }
        return regularFrames.removeFirst()
    }
}
