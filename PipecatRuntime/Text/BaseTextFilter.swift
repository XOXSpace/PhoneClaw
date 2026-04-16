import Foundation

// Mirrors Pipecat `pipecat/utils/text/base_text_filter.py`.
//
// Source-iso boundary: text filters are responsible for modifying text as it
// flows through the pipeline (most prominently TTS service input). They
// support dynamic settings updates and interruption handling.
//
// Subclasses must implement `filter(_:)`. Other methods are optional with
// no-op defaults via protocol extension, mirroring the Python ABC's empty
// default impls of `update_settings`, `handle_interruption`, `reset_interruption`.

protocol BaseTextFilter: AnyObject {

    /// Update the filter's configuration settings.
    /// Mirrors `update_settings(settings)` (py:29).
    func updateSettings(_ settings: [String: Any]) async

    /// Apply filtering transformations to the input text.
    /// Mirrors `filter(text)` (py:41) — the only @abstractmethod.
    func filter(_ text: String) async -> String

    /// Handle interruption events. Reset internal state if any.
    /// Mirrors `handle_interruption()` (py:55).
    func handleInterruption() async

    /// Reset filter state after interruption is handled.
    /// Mirrors `reset_interruption()` (py:63).
    func resetInterruption() async
}

extension BaseTextFilter {
    func updateSettings(_ settings: [String: Any]) async {}
    func handleInterruption() async {}
    func resetInterruption() async {}
}
