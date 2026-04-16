import Foundation

enum FrameDirection: Sendable {
    case downstream
    case upstream
}

protocol UninterruptibleFrame {}

class Frame: Identifiable, CustomStringConvertible, @unchecked Sendable {
    let id: UUID
    let createdAt: Date
    var pts: UInt64?
    var broadcastSiblingID: UUID?
    var metadata: [String: Any]
    var transportSource: String?
    var transportDestination: String?

    init(id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
        self.pts = nil
        self.broadcastSiblingID = nil
        self.metadata = [:]
        self.transportSource = nil
        self.transportDestination = nil
    }

    var isSystemFrame: Bool { false }

    var name: String {
        String(describing: type(of: self))
    }

    var description: String {
        name
    }
}

class SystemFrame: Frame, @unchecked Sendable {
    override var isSystemFrame: Bool { true }
}

class DataFrame: Frame, @unchecked Sendable {}

class ControlFrame: Frame, @unchecked Sendable {}
