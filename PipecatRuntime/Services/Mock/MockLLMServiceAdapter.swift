import Foundation

// MARK: - MockLLMServiceAdapter
//
// Canned LLM replacement for headless CLI runs. Mirrors Pipecat's mock LLM
// services under `tests/utils.py::OfflineLLMService`: consumes LLMContextFrame,
// emits LLMFullResponseStartFrame → LLMTextFrame(s) → LLMFullResponseEndFrame,
// honours InterruptionFrame by cancelling the in-flight response.
//
// This is the CLI parallel of MLXLLMServiceAdapter — same frame surface,
// no model load, no Agent/ dependencies (StreamingSanitizer, Sleeper).
// Bringing the real MLX adapter into the CLI target would require lifting
// those two deps into PipecatRuntime; out of scope for the CLI harness.

final class MockLLMServiceAdapter: FrameProcessor, @unchecked Sendable {
    typealias Responder = @Sendable ([LLMContextMessage]) -> [String]

    private let responder: Responder
    private let interTokenDelay: TimeInterval
    private let echoContext: Bool
    private var generationTask: Task<Void, Never>?
    private let captureLock = NSLock()
    private var receivedContexts: [LLMContext] = []

    /// All LLMContexts observed on LLMContextFrame, in arrival order.
    /// LLMContextFrame is consumed (not forwarded) by LLM adapters — the
    /// same contract MLXLLMServiceAdapter follows — so a downstream
    /// MockOutputTransport will never see them. Inspect here instead.
    var capturedContexts: [LLMContext] {
        captureLock.withLock { Array(receivedContexts) }
    }

    /// - Parameters:
    ///   - responder: maps the LLM context (system + user history) to a token
    ///     sequence. Default answers "✓ 你好" to exercise the marker path.
    ///   - interTokenDelay: delay between tokens (0 = emit as fast as possible).
    ///   - echoContext: print the received context before responding (useful
    ///     for verifying the system prompt + chat shape reaching the LLM).
    init(
        responder: @escaping Responder = { _ in ["✓ ", "你好"] },
        interTokenDelay: TimeInterval = 0,
        echoContext: Bool = true
    ) {
        self.responder = responder
        self.interTokenDelay = interTokenDelay
        self.echoContext = echoContext
        super.init(name: "MockLLMServiceAdapter")
    }

    override func didReceiveStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        cancelGeneration()
    }

    override func didReceiveCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        cancelGeneration()
    }

    override func process(
        _ frame: Frame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        switch frame {
        case let frame as LLMContextFrame:
            await startGeneration(messages: frame.context.messages, context: context)

        case is InterruptionFrame:
            print("[MockLLM] received InterruptionFrame — cancelling generation")
            cancelGeneration()
            await context.push(frame, direction: direction)

        default:
            await super.process(frame, direction: direction, context: context)
        }
    }

    private func startGeneration(
        messages: [LLMContextMessage],
        context: FrameProcessorContext
    ) async {
        cancelGeneration()

        captureLock.withLock {
            receivedContexts.append(LLMContext(messages: messages))
        }

        if echoContext {
            print("[MockLLM] ─── LLMContextFrame received (\(messages.count) messages) ───")
            for (index, message) in messages.enumerated() {
                let role = String(describing: message.role)
                let content = message.content ?? ""
                let preview = content.count > 200 ? String(content.prefix(200)) + "…" : content
                print("[MockLLM]   [\(index)] role=\(role) chars=\(content.count)")
                print("[MockLLM]       \(preview)")
            }
        }

        let tokens = responder(messages)
        let delay = interTokenDelay

        generationTask = Task {
            await context.push(LLMFullResponseStartFrame(), direction: .downstream)
            for token in tokens {
                if Task.isCancelled { return }
                await context.push(LLMTextFrame(text: token), direction: .downstream)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
            if Task.isCancelled { return }
            await context.push(LLMFullResponseEndFrame(), direction: .downstream)
        }
    }

    private func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
    }
}
