import Foundation

// Mirrors Pipecat `pipecat/utils/text/markdown_text_filter.py`.
//
// Source-iso boundary: removes Markdown formatting from text content before
// it reaches the TTS service, so spoken output never contains "**", "*", "`",
// table pipes, HTML tags, or URL prefixes that would either be read aloud
// literally or crash backends with limited lexicons (e.g. sherpa-onnx OOV).
//
// Implementation note:
//   - Pipecat uses Python's `markdown` package to convert MD→HTML→strip.
//     Swift has no equivalent in the standard library, and pulling a
//     third-party MD parser solely for voice TTS is overkill. The voice
//     pipeline only needs the regex-driven stripping rules below — the
//     MD→HTML→strip path in pipecat exists primarily to handle exotic
//     constructs (nested links, footnotes) that voice agents rarely emit.
//
//   - Therefore this Swift port implements the regex steps verbatim
//     (mirroring py:80-138) and skips the markdown→HTML conversion.
//     The behavioural delta is: bold/italic/inline-code/tables/URLs are
//     handled identically to pipecat; obscure block constructs are
//     passed through. If full fidelity is needed later, a swift-markdown
//     dependency can replace the regex steps.
//
// References: py line numbers point at markdown_text_filter.py:67-138.

final class MarkdownTextFilter: BaseTextFilter {

    struct Params {
        /// Mirrors `enable_text_filter` (py:40).
        var enableTextFilter: Bool = true
        /// Mirrors `filter_code` (py:41).
        var filterCode: Bool = false
        /// Mirrors `filter_tables` (py:42).
        var filterTables: Bool = false
    }

    private var params: Params
    private var inCodeBlock = false
    private var inTable = false
    private var interrupted = false

    init(params: Params = Params()) {
        self.params = params
    }

    func updateSettings(_ settings: [String: Any]) async {
        if let v = settings["enable_text_filter"] as? Bool { params.enableTextFilter = v }
        if let v = settings["filter_code"]        as? Bool { params.filterCode = v }
        if let v = settings["filter_tables"]      as? Bool { params.filterTables = v }
    }

    func handleInterruption() async {
        interrupted = true
        inCodeBlock = false
        inTable = false
    }

    func resetInterruption() async {
        interrupted = false
    }

    /// Mirrors `filter(text)` py:67-142.
    func filter(_ text: String) async -> String {
        guard params.enableTextFilter else { return text }

        var t = text

        // py:78 — replace newlines that have no surrounding text with single space
        t = replace(t, pattern: #"^\s*\n"#, with: " ", options: [.anchorsMatchLines])

        // py:81 — strip backticks from inline code (not from code blocks)
        t = replace(t, pattern: #"(?<!`)`([^`\n]+)`(?!`)"#, with: "$1")

        // py:84 — remove repeated sequences of 5+ same chars
        t = replace(t, pattern: #"(\S)(\1{4,})"#, with: "")

        // py:87 — preserve numbered list markers
        t = replace(t, pattern: #"^(\d+\.)\s"#, with: "§NUM§$1 ", options: [.anchorsMatchLines])

        // py:91 — preserve leading/trailing whitespace via § placeholder.
        // This is critical for word-by-word streaming where surrounding
        // spaces affect TTS prosody.
        t = preserveLeadingTrailingSpaces(t)

        // py:97 — undo placeholder before tables so tables can be parsed
        t = t.replacingOccurrences(of: "§| ", with: "| ")

        // py:99-102 — pipecat converts markdown→HTML here; Swift skips.
        // Direct regex steps below cover the voice-TTS critical path.

        if params.filterTables {
            t = removeTables(t)
        }

        // py:109 — strip any remaining HTML tags (LLM may emit raw HTML)
        t = replace(t, pattern: "<[^<]+?>", with: "")

        // py:112-115 — common HTML entities
        t = t.replacingOccurrences(of: "&nbsp;", with: " ")
        t = t.replacingOccurrences(of: "&lt;",   with: "<")
        t = t.replacingOccurrences(of: "&gt;",   with: ">")
        t = t.replacingOccurrences(of: "&amp;",  with: "&")

        // py:118 — strip "**" globally (this is the LLM bold case)
        t = t.replacingOccurrences(of: "**", with: "")

        // py:121 — strip single "*" at word boundaries
        t = replace(t, pattern: #"(^|\s)\*|\*($|\s)"#, with: "$1$2")

        // py:124-125 — markdown table residuals
        t = t.replacingOccurrences(of: "|", with: "")
        t = replace(t, pattern: #"^\s*[-:]+\s*$"#, with: "", options: [.anchorsMatchLines])

        if params.filterCode {
            t = removeCodeBlocks(t)
        }

        // py:132 — restore numbered markers
        t = t.replacingOccurrences(of: "§NUM§", with: "")

        // py:135 — restore preserved spaces
        t = t.replacingOccurrences(of: "§", with: " ")

        // py:138 — make URLs more readable (drop scheme)
        t = replace(t, pattern: #"https?://"#, with: "")

        return t
    }

    // MARK: - Helpers

    private func replace(
        _ text: String,
        pattern: String,
        with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    /// Mirrors py:91-93: preserve leading spaces and trailing whitespace runs
    /// per line by replacing them with § placeholders of equal length, so the
    /// markdown step doesn't collapse them.
    private func preserveLeadingTrailingSpaces(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"^( +)|\s+$"#,
            options: [.anchorsMatchLines]
        ) else { return text }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: range)

        var result = text
        for match in matches.reversed() {
            guard let r = Range(match.range, in: result) else { continue }
            let length = result[r].count
            result.replaceSubrange(r, with: String(repeating: "§", count: length))
        }
        return result
    }

    // MARK: - Code blocks (py:165-225)

    private func removeCodeBlocks(_ text: String) -> String {
        if interrupted {
            inCodeBlock = false
            return text
        }
        let pattern = "```"
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matchRange = (try? NSRegularExpression(pattern: pattern))?
            .firstMatch(in: text, range: range)?.range

        if inCodeBlock {
            if let m = matchRange {
                inCodeBlock = false
                let endIndex = m.location + m.length
                return nsText.substring(from: endIndex)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }

        guard let m = matchRange else { return text }
        let prefix = nsText.substring(to: m.location)
        if m.location == 0 || prefix.allSatisfy({ $0.isWhitespace }) {
            inCodeBlock = true
            return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let parts = text.components(separatedBy: pattern)
        if parts.count > 2 {
            return (parts.first! + " " + parts.last!)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        inCodeBlock = true
        return parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Tables (py:230-269)

    private func removeTables(_ text: String) -> String {
        if interrupted {
            inTable = false
            return text
        }

        var t = text

        // py:252 — remove complete <table>…</table>
        t = replace(
            t,
            pattern: #"<table>.*?</table>"#,
            with: "",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        )

        if inTable {
            // py:256 — partial table end inside this chunk
            if let regex = try? NSRegularExpression(
                pattern: #".*</table>"#,
                options: [.dotMatchesLineSeparators, .caseInsensitive]
            ),
               let m = regex.firstMatch(
                in: t, range: NSRange(t.startIndex..<t.endIndex, in: t)
               ) {
                inTable = false
                let nsText = t as NSString
                return nsText.substring(from: m.range.location + m.range.length)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }

        // py:264 — partial table start
        if let regex = try? NSRegularExpression(
            pattern: #"<table>.*"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ),
           let m = regex.firstMatch(
            in: t, range: NSRange(t.startIndex..<t.endIndex, in: t)
           ) {
            inTable = true
            let nsText = t as NSString
            return nsText.substring(to: m.range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
