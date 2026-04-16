import Foundation

enum LLMContextRole: String, Sendable {
    case system
    case user
    case assistant
    case tool
    case developer
}

struct LLMToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let arguments: String

    init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

struct LLMContextMessage: Equatable, Sendable {
    let role: LLMContextRole
    let content: String?
    let toolCalls: [LLMToolCall]
    let toolCallID: String?

    init(
        role: LLMContextRole,
        content: String? = nil,
        toolCalls: [LLMToolCall] = [],
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

final class LLMContext: @unchecked Sendable {
    private var storedMessages: [LLMContextMessage]

    init(messages: [LLMContextMessage] = []) {
        self.storedMessages = messages
    }

    var messages: [LLMContextMessage] {
        storedMessages
    }

    func getMessages() -> [LLMContextMessage] {
        storedMessages
    }

    func addMessage(_ message: LLMContextMessage) {
        storedMessages.append(message)
    }

    func addMessages(_ messages: [LLMContextMessage]) {
        storedMessages.append(contentsOf: messages)
    }

    func setMessages(_ messages: [LLMContextMessage]) {
        storedMessages = messages
    }

    func transformMessages(
        _ transform: @Sendable ([LLMContextMessage]) -> [LLMContextMessage]
    ) {
        storedMessages = transform(storedMessages)
    }

    func copy() -> LLMContext {
        LLMContext(messages: storedMessages)
    }
}
