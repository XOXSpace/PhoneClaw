import Foundation

struct TextPartForConcatenation {
    let text: String
    let includesInterPartSpaces: Bool
}

func concatenateAggregatedText(_ textParts: [TextPartForConcatenation]) -> String {
    var result = ""
    var lastIncludesInterPartSpaces = false

    guard !textParts.isEmpty else { return result }

    func appendPart(_ part: TextPartForConcatenation) {
        result += part.text
        lastIncludesInterPartSpaces = part.includesInterPartSpaces
    }

    for part in textParts where !part.text.isEmpty {
        if result.isEmpty {
            appendPart(part)
            continue
        }

        if part.includesInterPartSpaces, lastIncludesInterPartSpaces {
            appendPart(part)
        } else if !part.includesInterPartSpaces, !lastIncludesInterPartSpaces {
            result += " "
            appendPart(part)
        } else {
            if let lastCharacter = result.last,
               let firstCharacter = part.text.first,
               !lastCharacter.isWhitespace,
               !firstCharacter.isWhitespace {
                result += " "
            }
            appendPart(part)
        }
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

class LLMContextAggregator: FrameProcessor, @unchecked Sendable {
    let llmContext: LLMContext
    let role: LLMContextRole

    private(set) var aggregation: [TextPartForConcatenation] = []

    init(context: LLMContext, role: LLMContextRole, name: String) {
        self.llmContext = context
        self.role = role
        super.init(name: name)
    }

    var messages: [LLMContextMessage] {
        llmContext.getMessages()
    }

    func addMessages(_ messages: [LLMContextMessage]) {
        llmContext.addMessages(messages)
    }

    func setMessages(_ messages: [LLMContextMessage]) {
        llmContext.setMessages(messages)
    }

    func transformMessages(
        _ transform: @escaping @Sendable ([LLMContextMessage]) -> [LLMContextMessage]
    ) {
        llmContext.transformMessages(transform)
    }

    func appendAggregation(_ text: String, includesInterFrameSpaces: Bool = false) {
        aggregation.append(
            TextPartForConcatenation(
                text: text,
                includesInterPartSpaces: includesInterFrameSpaces
            )
        )
    }

    func aggregationString() -> String {
        concatenateAggregatedText(aggregation)
    }

    func resetAggregation() {
        aggregation.removeAll(keepingCapacity: true)
    }

    func pushContextFrame(
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await context.push(LLMContextFrame(context: llmContext), direction: direction)
    }
}
