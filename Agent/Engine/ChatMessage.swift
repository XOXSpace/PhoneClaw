import Foundation

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    var role: Role
    var content: String
    var images: [ChatImageAttachment]
    var audios: [ChatAudioAttachment]
    let timestamp: Date
    var skillName: String? = nil

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        images: [ChatImageAttachment] = [],
        audios: [ChatAudioAttachment] = [],
        timestamp: Date = Date(),
        skillName: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.images = images
        self.audios = audios
        self.timestamp = timestamp
        self.skillName = skillName
    }

    mutating func update(content: String) {
        guard self.content != content else { return }
        self.content = content
    }

    mutating func update(role: Role, content: String, skillName: String? = nil) {
        self.role = role
        self.content = content
        self.skillName = skillName
    }

    enum Role: String, Codable {
        case user, assistant, system, skillResult
    }
}

struct ChatSessionSummary: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var preview: String
    var updatedAt: Date
}
