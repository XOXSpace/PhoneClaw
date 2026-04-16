import Foundation
import XCTest
@testable import PhoneClaw

private final class ManualSleeper: @unchecked Sendable, Sleeper {
    private struct Waiter {
        var id = 0
        var deadline: TimeInterval = 0
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var nextID = 0
    private var waiters: [Waiter] = []

    var waiterCount: Int {
        lock.withLock { waiters.count }
    }

    func sleep(for duration: TimeInterval) async throws {
        var generatedID = 0
        var computedDeadline: TimeInterval = 0
        lock.withLock {
            generatedID = nextID
            nextID += 1
            computedDeadline = now + duration
        }
        let waiterID = generatedID
        let deadline = computedDeadline
        var readyContinuation: CheckedContinuation<Void, Error>?

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if deadline <= now {
                        readyContinuation = continuation
                    } else {
                        waiters.append(Waiter(id: waiterID, deadline: deadline, continuation: continuation))
                    }
                }
            }
            readyContinuation?.resume()
        } onCancel: {
            var continuation: CheckedContinuation<Void, Error>?
            lock.withLock {
                if let index = waiters.firstIndex(where: { $0.id == waiterID }) {
                    continuation = waiters.remove(at: index).continuation
                }
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by delta: TimeInterval) {
        var due: [CheckedContinuation<Void, Error>] = []
        lock.withLock {
            now += delta
            var remaining: [Waiter] = []
            for waiter in waiters {
                if waiter.deadline <= now {
                    due.append(waiter.continuation)
                } else {
                    remaining.append(waiter)
                }
            }
            waiters = remaining
        }
        due.forEach { $0.resume() }
    }
}

final class VoiceTurnControllerTests: XCTestCase {
    private func waitForWaiters(
        _ expectedCount: Int,
        on sleeper: ManualSleeper,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if sleeper.waiterCount >= expectedCount {
                return
            }
            await Task.yield()
        }

        XCTFail(
            "Expected at least \(expectedCount) pending sleeper waiters, got \(sleeper.waiterCount)",
            file: file,
            line: line
        )
    }

    func testConfirmsTurnAfterGraceWindow() async {
        let sleeper = ManualSleeper()
        let controller = VoiceTurnController(sleeper: sleeper)
        controller.graceWindow = 0.1

        let confirmed = expectation(description: "turn confirmed")
        var delivered: [Float] = []

        controller.onTurnConfirmed = { samples in
            delivered = samples
            confirmed.fulfill()
        }

        controller.handleSpeechStart()
        XCTAssertEqual(controller.phase, .recording)

        controller.handleSpeechEnd(samples: [0.1, 0.2, 0.3])
        XCTAssertEqual(controller.phase, .pendingStop)
        await waitForWaiters(2, on: sleeper)

        sleeper.advance(by: 0.09)
        await Task.yield()
        XCTAssertEqual(controller.phase, .pendingStop)
        XCTAssertTrue(delivered.isEmpty)

        sleeper.advance(by: 0.02)
        await fulfillment(of: [confirmed], timeout: 1.0)
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertEqual(delivered, [0.1, 0.2, 0.3])
    }

    func testResumeWithinGraceMergesSegmentsIntoOneTurn() async {
        let sleeper = ManualSleeper()
        let controller = VoiceTurnController(sleeper: sleeper)
        controller.graceWindow = 0.1

        let confirmed = expectation(description: "merged turn confirmed")
        var startCount = 0
        var delivered: [Float] = []

        controller.onTurnStarted = {
            startCount += 1
        }
        controller.onTurnConfirmed = { samples in
            delivered = samples
            confirmed.fulfill()
        }

        controller.handleSpeechStart()
        controller.handleSpeechEnd(samples: [1, 2])
        await waitForWaiters(2, on: sleeper)

        sleeper.advance(by: 0.05)
        await Task.yield()

        controller.handleSpeechStart()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(startCount, 1)

        controller.handleSpeechEnd(samples: [3, 4])
        await waitForWaiters(2, on: sleeper)
        sleeper.advance(by: 0.11)

        await fulfillment(of: [confirmed], timeout: 1.0)
        XCTAssertEqual(delivered, [1, 2, 3, 4])
        XCTAssertEqual(controller.phase, .listening)
    }

    func testResetCancelsPendingCallbacks() async {
        let sleeper = ManualSleeper()
        let controller = VoiceTurnController(sleeper: sleeper)
        controller.graceWindow = 0.1
        controller.pendingStopTimeout = 0.2

        var confirmedCount = 0
        var cancelledCount = 0

        controller.onTurnConfirmed = { _ in confirmedCount += 1 }
        controller.onTurnCancelled = { cancelledCount += 1 }

        controller.handleSpeechStart()
        controller.handleSpeechEnd(samples: [1])
        controller.reset()

        sleeper.advance(by: 1.0)
        await Task.yield()

        XCTAssertEqual(controller.phase, .listening)
        XCTAssertEqual(confirmedCount, 0)
        XCTAssertEqual(cancelledCount, 0)
    }

    func testPendingStopTimeoutActsAsDefensiveFuse() async {
        let sleeper = ManualSleeper()
        let controller = VoiceTurnController(sleeper: sleeper)
        controller.graceWindow = 10.0
        controller.pendingStopTimeout = 0.5

        let cancelled = expectation(description: "pending stop timeout fired")
        var confirmedCount = 0

        controller.onTurnConfirmed = { _ in confirmedCount += 1 }
        controller.onTurnCancelled = {
            cancelled.fulfill()
        }

        controller.handleSpeechStart()
        controller.handleSpeechEnd(samples: [1, 2, 3])
        await waitForWaiters(2, on: sleeper)

        sleeper.advance(by: 0.6)
        await fulfillment(of: [cancelled], timeout: 1.0)

        XCTAssertEqual(controller.phase, .listening)
        XCTAssertEqual(confirmedCount, 0)
    }
}
