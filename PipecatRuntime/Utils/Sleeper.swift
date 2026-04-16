import Foundation

// MARK: - Sleeper Protocol (injectable time abstraction)
//
// Shared across PipecatRuntime services (MLXLLMServiceAdapter turn-completion
// timeouts) and iOS-only consumers (Agent/VoiceTurnController). Lives here
// so it compiles in both iOS app target (folder-sync) and the CLI SPM
// target (symlinked PipecatRuntime) without dragging Agent/ into CLI.
//
// Production code uses `RealSleeper`; tests inject a FakeSleeper that
// advances manually (see PhoneClawTests/VoiceTurnControllerTests.swift
// and PhoneClawTests/PipecatRuntimeTests.swift ManualSleeper).

protocol Sleeper: Sendable {
    func sleep(for duration: TimeInterval) async throws
}

struct RealSleeper: Sleeper {
    func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}
