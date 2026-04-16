import Foundation

// Mirrors Pipecat `turns/user_turn_controller.py:33`
// This is a complete rewrite of the previous 6-Phase state machine.
// All logic is driven by injected strategies (UserTurnStrategies).

final class UserTurnController {

    // MARK: - Event handlers (mirrors Pipecat event_handler pattern)

    /// Mirrors `on_user_turn_started`
    var onUserTurnStarted: ((BaseUserTurnStartStrategy?, UserTurnStartedParams) async -> Void)?
    /// Mirrors `on_user_turn_stopped`
    var onUserTurnStopped: ((BaseUserTurnStopStrategy?, UserTurnStoppedParams) async -> Void)?
    /// Mirrors `on_user_turn_stop_timeout`
    var onUserTurnStopTimeout: (() async -> Void)?
    /// Push a single frame to the pipeline (mirrors `on_push_frame`)
    var onPushFrame: ((Frame, FrameDirection) async -> Void)?
    /// Broadcast a frame in both directions (mirrors `on_broadcast_frame`)
    var onBroadcastFrame: ((() -> Frame) async -> Void)?
    /// Reset aggregation state in the LLM aggregator (mirrors `on_reset_aggregation`)
    var onResetAggregation: (() async -> Void)?

    // MARK: - State (mirrors Python instance vars py:85-94)

    private let strategies: UserTurnStrategies
    private let userTurnStopTimeout: TimeInterval   // mirrors user_turn_stop_timeout = 5.0

    private var userSpeaking = false               // mirrors _user_speaking
    private var userTurn = false                   // mirrors _user_turn

    // Timeout machinery: mirrors asyncio.Event + wait_for pattern
    // Lock required because Swift Tasks can run concurrently (unlike Python asyncio).
    private let stopTimeoutLock = NSLock()
    private var stopTimeoutEventContinuation: CheckedContinuation<Bool, Never>?
    private var stopTimeoutSignalled = false
    private var stopTimeoutTask: Task<Void, Never>?

    // MARK: - Init

    init(
        strategies: UserTurnStrategies = UserTurnStrategies(),
        userTurnStopTimeout: TimeInterval = 5.0
    ) {
        self.strategies = strategies
        self.userTurnStopTimeout = userTurnStopTimeout
    }

    // MARK: - Lifecycle (called by LLMUserAggregator / UserTurnProcessor)

    /// Mirrors `setup(task_manager)` → py:110
    func setup() async {
        guard stopTimeoutTask == nil else { return }  // idempotent
        stopTimeoutTask = Task { [weak self] in
            await self?.userTurnStopTimeoutTaskHandler()
        }
        await setupStrategies()
    }

    /// Mirrors `cleanup()` → py:126
    func cleanup() async {
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        await cleanupStrategies()
    }

    func clearHandlers() {
        onUserTurnStarted = nil
        onUserTurnStopped = nil
        onUserTurnStopTimeout = nil
        onPushFrame = nil
        onBroadcastFrame = nil
        onResetAggregation = nil
    }

    // MARK: - Frame processing

    /// Mirrors `process_frame(frame)` → py:146
    func processFrame(_ frame: Frame, direction: FrameDirection,
                      push: @escaping @Sendable (Frame, FrameDirection) async -> Void) async {
        // Internal state updates first (mirrors py:157-166)
        switch frame {
        case is UserStartedSpeakingFrame, is VADUserStartedSpeakingFrame:
            userSpeaking = true
            signalStopTimeoutEvent()
        case is UserStoppedSpeakingFrame, is VADUserStoppedSpeakingFrame:
            userSpeaking = false
            signalStopTimeoutEvent()
        case is TranscriptionFrame, is InterimTranscriptionFrame:
            signalStopTimeoutEvent()
        default:
            break
        }

        // Start strategies chain (mirrors py:168-171)
        for strategy in strategies.start {
            let result = await strategy.processFrame(frame)
            if result == .stop { break }
        }

        // Stop strategies chain (mirrors py:173-176)
        for strategy in strategies.stop {
            let result = await strategy.processFrame(frame)
            if result == .stop { break }
        }
    }

    // MARK: - Internal triggers

    /// Mirrors `_trigger_user_turn_start` → py:258
    private func triggerUserTurnStart(
        _ strategy: BaseUserTurnStartStrategy?,
        _ params: UserTurnStartedParams
    ) async {
        guard !userTurn else { return }   // Prevent double-start
        userTurn = true
        signalStopTimeoutEvent()

        // Reset all strategies for the new turn
        for s in strategies.start { await s.reset() }
        for s in strategies.stop  { await s.reset() }

        await onUserTurnStarted?(strategy, params)
    }

    /// Mirrors `_trigger_user_turn_stop` → py:278
    private func triggerUserTurnStop(
        _ strategy: BaseUserTurnStopStrategy?,
        _ params: UserTurnStoppedParams
    ) async {
        guard userTurn else { return }   // Prevent double-stop
        userTurn = false
        signalStopTimeoutEvent()

        for s in strategies.stop { await s.reset() }

        await onUserTurnStopped?(strategy, params)
    }

    // MARK: - Timeout task (mirrors `_user_turn_stop_timeout_task_handler` → py:294)

    private func userTurnStopTimeoutTaskHandler() async {
        while !Task.isCancelled {
            let timedOut = await waitForStopTimeoutEvent(timeout: userTurnStopTimeout)
            if !timedOut {
                // Event was signalled before timeout: reset and wait again
                clearStopTimeoutEvent()
                continue
            }
            // Timed out
            if userTurn && !userSpeaking {
                await onUserTurnStopTimeout?()
                await triggerUserTurnStop(
                    nil,
                    UserTurnStoppedParams(enableUserSpeakingFrames: true)
                )
            }
        }
    }

    /// Returns `true` if timed out, `false` if event was signalled.
    /// Mirrors `asyncio.wait_for(event.wait(), timeout=...)`.
    private func waitForStopTimeoutEvent(timeout: TimeInterval) async -> Bool {
        let alreadySignalled = stopTimeoutLock.withLock {
            if stopTimeoutSignalled {
                stopTimeoutSignalled = false
                return true
            }
            return false
        }
        if alreadySignalled { return false }

        return await withCheckedContinuation { [weak self] continuation in
            guard let self else { continuation.resume(returning: true); return }
            self.stopTimeoutLock.withLock {
                self.stopTimeoutEventContinuation = continuation
            }
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                let cont = self.stopTimeoutLock.withLock { () -> CheckedContinuation<Bool, Never>? in
                    let c = self.stopTimeoutEventContinuation
                    self.stopTimeoutEventContinuation = nil
                    return c
                }
                cont?.resume(returning: true)  // timed out
            }
        }
    }

    private func signalStopTimeoutEvent() {
        let cont = stopTimeoutLock.withLock { () -> CheckedContinuation<Bool, Never>? in
            if let c = stopTimeoutEventContinuation {
                stopTimeoutEventContinuation = nil
                return c
            } else {
                stopTimeoutSignalled = true
                return nil
            }
        }
        cont?.resume(returning: false)  // not timed out
    }

    private func clearStopTimeoutEvent() {
        stopTimeoutLock.withLock {
            stopTimeoutSignalled = false
        }
    }

    // MARK: - Strategy setup / cleanup

    /// Mirrors `_setup_strategies()` → py:178
    private func setupStrategies() async {
        for s in strategies.start {
            s.onUserTurnStarted = { [weak self] params in
                await self?.triggerUserTurnStart(s, params)
            }
            s.onPushFrame = { [weak self] frame, dir in
                await self?.onPushFrame?(frame, dir)
            }
            s.onBroadcastFrame = { [weak self] make in
                await self?.onBroadcastFrame?(make)
            }
            s.onResetAggregation = { [weak self] in
                await self?.onResetAggregation?()
            }
            await s.setup()
        }
        for s in strategies.stop {
            s.onUserTurnStopped = { [weak self] params in
                await self?.triggerUserTurnStop(s, params)
            }
            s.onPushFrame = { [weak self] frame, dir in
                await self?.onPushFrame?(frame, dir)
            }
            s.onBroadcastFrame = { [weak self] make in
                await self?.onBroadcastFrame?(make)
            }
            await s.setup()
        }
    }

    /// Mirrors `_cleanup_strategies()` → py:192
    private func cleanupStrategies() async {
        for s in strategies.start { await s.cleanup() }
        for s in strategies.stop  { await s.cleanup() }
    }
}
