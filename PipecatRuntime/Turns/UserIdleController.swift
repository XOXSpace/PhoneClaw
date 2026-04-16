import Foundation

protocol UserIdleSleeper: Sendable {
    func sleep(for duration: TimeInterval) async throws
}

struct RealUserIdleSleeper: UserIdleSleeper {
    func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}

final class UserIdleController {
    typealias UserTurnIdleHandler = @Sendable () async -> Void

    var userIdleTimeout: TimeInterval
    var onUserTurnIdle: UserTurnIdleHandler?

    private let sleeper: UserIdleSleeper
    private var userTurnInProgress = false
    private var functionCallsInProgress = 0
    private var idleTask: Task<Void, Never>?

    init(
        userIdleTimeout: TimeInterval = 0,
        sleeper: UserIdleSleeper = RealUserIdleSleeper()
    ) {
        self.userIdleTimeout = userIdleTimeout
        self.sleeper = sleeper
    }

    func start() {
        resetState()
    }

    func stop() {
        resetState()
        onUserTurnIdle = nil
    }

    func cancel() {
        resetState()
        onUserTurnIdle = nil
    }

    func process(_ frame: Frame) async {
        switch frame {
        case let frame as UserIdleTimeoutUpdateFrame:
            userIdleTimeout = frame.timeout
            if userIdleTimeout <= 0 {
                cancelIdleTimer()
            }

        case is BotStoppedSpeakingFrame:
            if !userTurnInProgress, functionCallsInProgress == 0 {
                scheduleIdleTimer()
            }

        case is BotStartedSpeakingFrame:
            cancelIdleTimer()

        case is UserStartedSpeakingFrame:
            userTurnInProgress = true
            cancelIdleTimer()

        case is UserStoppedSpeakingFrame:
            userTurnInProgress = false

        case let frame as FunctionCallsStartedFrame:
            functionCallsInProgress += frame.functionCalls.count
            cancelIdleTimer()

        case is FunctionCallResultFrame, is FunctionCallCancelFrame:
            functionCallsInProgress = max(0, functionCallsInProgress - 1)

        default:
            break
        }
    }

    private func resetState() {
        cancelIdleTimer()
        userTurnInProgress = false
        functionCallsInProgress = 0
    }

    private func scheduleIdleTimer() {
        guard userIdleTimeout > 0 else { return }

        cancelIdleTimer()
        idleTask = Task { [weak self, sleeper] in
            do {
                try await sleeper.sleep(for: self?.userIdleTimeout ?? 0)
            } catch {
                return
            }

            guard let self else { return }
            self.idleTask = nil
            await self.onUserTurnIdle?()
        }
    }

    private func cancelIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
    }
}
