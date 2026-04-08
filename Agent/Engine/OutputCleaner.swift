import Foundation

// 与 PromptBuilder / ChatModels 中的常量保持一致。
// 仅供 OutputCleaner 内部使用，外部使用方分别在自己的文件里维护副本。
private let thinkingOpenMarker = "[[PHONECLAW_THINK]]"
private let thinkingCloseMarker = "[[/PHONECLAW_THINK]]"

extension AgentEngine {

    // MARK: - 中间输出/Prompt 回声识别

    func looksLikeStructuredIntermediateOutput(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("```json") || trimmed.hasPrefix("```") {
            return true
        }

        if let regex = try? NSRegularExpression(
            pattern: "\"[A-Za-z_][A-Za-z0-9_]*\"\\s*:",
            options: []
        ) {
            let matchCount = regex.numberOfMatches(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
            )
            if matchCount >= 2 && !trimmed.hasPrefix("{") {
                return true
            }
        }

        let suspiciousFragments = [
            "tool_name\":",
            "result_for_user_name\":",
            "text_for_display\":",
            "tool_operation_success\":",
            "arguments_for_tool_no_skill\":",
            "memory_user_power_conversion\":"
        ]
        if suspiciousFragments.filter({ trimmed.contains($0) }).count >= 2 {
            return true
        }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }

        if let dict = json as? [String: Any] {
            if dict["name"] != nil {
                return false
            }

            let suspiciousKeys = [
                "final_answer", "tool_call", "arguments", "device_call",
                "next_action", "action", "tool"
            ]
            return suspiciousKeys.contains { dict[$0] != nil }
        }

        return false
    }

    func looksLikePromptEcho(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("user\n") || trimmed == "user" {
            return true
        }

        let suspiciousPhrases = [
            "根据已加载的 Skill",
            "不要将任何关于工具、系统或该请求的描述变成 Markdown 代码或 JSON 模板",
            "如果需要，请直接调用",
            "package_name",
            "text_for_user"
        ]

        let hitCount = suspiciousPhrases.reduce(into: 0) { count, phrase in
            if trimmed.contains(phrase) { count += 1 }
        }
        return hitCount >= 2
    }

    // MARK: - 输出清洗

    func cleanOutputStreaming(_ text: String) -> String {
        var result = preserveThinkingChannels(in: text)

        if let tcRange = result.range(of: "<tool_call>") {
            result = String(result[result.startIndex..<tcRange.lowerBound])
        }

        let endPatterns = ["<turn|>", "<end_of_turn>", "<eos>"]
        for pat in endPatterns {
            if let range = result.range(of: pat) {
                result = String(result[result.startIndex..<range.lowerBound])
                break
            }
        }

        if let regex = try? NSRegularExpression(pattern: "<tool_call>.*?</tool_call>", options: .dotMatchesLineSeparators) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        result = result.replacingOccurrences(
            of: "<\\|?[/a-z_]+\\|?>",
            with: "",
            options: .regularExpression
        )

        if result.hasPrefix("model\n") {
            result = String(result.dropFirst(6))
        } else if result == "model" {
            return ""
        } else if result.hasPrefix("user\n") {
            result = String(result.dropFirst(5))
        } else if result == "user" {
            return ""
        }

        result = String(result.drop(while: { $0.isWhitespace || $0.isNewline }))
        return normalizeSafetyTruncation(in: result)
    }

    func cleanOutput(_ text: String) -> String {
        var result = preserveThinkingChannels(in: text)

        if let regex = try? NSRegularExpression(pattern: "<tool_call>.*?</tool_call>", options: .dotMatchesLineSeparators) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        if let tcRange = result.range(of: "<tool_call>") {
            result = String(result[result.startIndex..<tcRange.lowerBound])
        }

        let endPatterns = ["<turn|>", "<end_of_turn>", "<eos>"]
        for pat in endPatterns {
            if let range = result.range(of: pat) {
                result = String(result[result.startIndex..<range.lowerBound])
                break
            }
        }

        result = result.replacingOccurrences(
            of: "<\\|?[/a-z_]+\\|?>",
            with: "",
            options: .regularExpression
        )

        if let lastOpen = result.lastIndex(of: "<") {
            let tail = String(result[lastOpen...])
            let tailBody = tail.dropFirst()
            if !tailBody.isEmpty && tailBody.allSatisfy({ $0.isLetter || $0 == "_" || $0 == "/" || $0 == "|" }) {
                result = String(result[result.startIndex..<lastOpen])
            }
        }

        if result.hasPrefix("model\n") {
            result = String(result.dropFirst(6))
        } else if result == "model" {
            result = ""
        } else if result.hasPrefix("user\n") {
            result = String(result.dropFirst(5))
        } else if result == "user" {
            result = ""
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizeSafetyTruncation(in: result)
    }

    // MARK: - 安全截断保留 / 句子边界

    private func normalizeSafetyTruncation(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let warningRange = trimmed.range(of: "> ⚠️ ") else {
            return trimmed
        }

        let body = String(trimmed[..<warningRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let warning = String(trimmed[warningRange.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty else { return warning }

        let normalizedBody = trimIncompleteTrailingBlock(in: body)
        guard !normalizedBody.isEmpty else { return warning }
        return normalizedBody + "\n\n" + warning
    }

    private func trimIncompleteTrailingBlock(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if let paragraphBreak = trimmed.range(of: "\n\n", options: .backwards) {
            let tailLength = trimmed.distance(from: paragraphBreak.upperBound, to: trimmed.endIndex)
            if tailLength > 0 && tailLength <= 280 {
                return String(trimmed[..<paragraphBreak.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let sentenceBoundary = lastSentenceBoundary(in: trimmed) {
            let tailLength = trimmed.distance(from: sentenceBoundary, to: trimmed.endIndex)
            if tailLength > 0 && tailLength <= 220 {
                return String(trimmed[..<sentenceBoundary])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return trimmed
    }

    private func lastSentenceBoundary(in text: String) -> String.Index? {
        let sentenceEndings: Set<Character> = ["。", "！", "？", ".", "!", "?"]
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            if sentenceEndings.contains(text[index]) {
                return text.index(after: index)
            }
        }
        return nil
    }

    // MARK: - Thinking 通道保留

    private func preserveThinkingChannels(in text: String) -> String {
        let openTokens = ["<|channel|>thought\n", "<|channel>thought\n"]
        let closeToken = "<channel|>"

        var result = ""
        var cursor = text.startIndex

        while cursor < text.endIndex {
            let nextOpen = openTokens
                .compactMap { token -> (Range<String.Index>, String)? in
                    guard let range = text.range(of: token, range: cursor..<text.endIndex) else {
                        return nil
                    }
                    return (range, token)
                }
                .min(by: { $0.0.lowerBound < $1.0.lowerBound })

            guard let (openRange, token) = nextOpen else {
                result += text[cursor..<text.endIndex]
                break
            }

            result += text[cursor..<openRange.lowerBound]
            result += thinkingOpenMarker

            let thoughtStart = openRange.lowerBound
            let contentStart = text.index(thoughtStart, offsetBy: token.count)
            if let closeRange = text.range(of: closeToken, range: contentStart..<text.endIndex) {
                result += text[contentStart..<closeRange.lowerBound]
                result += thinkingCloseMarker
                cursor = closeRange.upperBound
            } else {
                result += text[contentStart..<text.endIndex]
                break
            }
        }

        return result
    }
}
