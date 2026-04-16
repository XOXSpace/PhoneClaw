import Foundation

// New BaseTextFilter implementation specific to local-TTS backends with
// limited lexicons (e.g. sherpa-onnx Chinese VITS).
//
// Pipecat itself has no emoji filter — its built-in TTS services are all
// cloud (OpenAI / Cartesia / ElevenLabs) and tolerate emoji input. With a
// local batch TTS whose character lexicon raises OOV on emoji and crashes
// the wrapper on empty token sequences, we add a dedicated filter and chain
// it after MarkdownTextFilter via the same `text_filters` mechanism pipecat
// already provides (TTSService.text_filters → applied in _push_tts_frames,
// segments that filter to empty are dropped).
//
// This is the pipecat-iso way to extend the system: add a new filter that
// conforms to BaseTextFilter, register it in the chain. Don't reach into
// the TTS wrapper for defensive nil-checks.

final class RemoveEmojiTextFilter: BaseTextFilter {

    /// Matches Unicode "Extended_Pictographic" property — the canonical class
    /// covering all emoji codepoints (incl. supplementary plane symbols),
    /// plus zero-width joiner and variation selector that appear inside
    /// composite emoji sequences.
    private static let pattern = #"[\p{Extended_Pictographic}\x{200D}\x{FE0F}]"#
    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: pattern, options: [])
    }()

    func filter(_ text: String) async -> String {
        guard let regex = Self.regex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
    }
}
