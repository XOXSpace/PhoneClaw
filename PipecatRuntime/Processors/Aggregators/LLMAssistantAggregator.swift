import Foundation

final class LLMAssistantAggregator: LLMContextAggregator, @unchecked Sendable {
    private static let timestampFormatter = ISO8601DateFormatter()

    private var userSpeaking = false
    private var botSpeaking = false
    private var shouldPushContextOnBotStopped = false
    private var inProgressCalls: [String: FunctionCallInProgressFrame] = [:]
    private var assistantTurnStartTimestamp = ""

    init(context: LLMContext = LLMContext()) {
        super.init(context: context, role: .assistant, name: "LLMAssistantAggregator")
    }

    override func pushContextFrame(
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await super.pushContextFrame(direction: direction, context: context)
        shouldPushContextOnBotStopped = false
    }

    override func didReceiveStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await flushAssistantTurnIfNeeded(context: context)
        clearTurnState()
    }

    override func didReceiveCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        await flushAssistantTurnIfNeeded(context: context)
        clearTurnState()
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        switch frame {
        case is InterruptionFrame:
            await flushAssistantTurnIfNeeded(context: context)
            await context.push(frame, direction: direction)

        case is LLMFullResponseStartFrame:
            assistantTurnStartTimestamp = Self.timestampNow()
            resetAggregation()
            await context.push(frame, direction: direction)

        case is LLMFullResponseEndFrame:
            await flushAssistantTurnIfNeeded(context: context)
            await context.push(frame, direction: direction)

        case let frame as TextFrame where !(frame is BaseTranscriptionFrame):
            if frame.appendToContext, !frame.text.isEmpty {
                appendAggregation(
                    frame.text,
                    includesInterFrameSpaces: frame.includesInterFrameSpaces
                )
            }
            await context.push(frame, direction: direction)

        case let frame as FunctionCallInProgressFrame:
            inProgressCalls[frame.callID] = frame
            llmContext.addMessage(
                LLMContextMessage(
                    role: .assistant,
                    toolCalls: [
                        LLMToolCall(
                            id: frame.callID,
                            name: frame.payload.name,
                            arguments: frame.payload.arguments
                        )
                    ]
                )
            )
            await context.push(frame, direction: direction)

        case let frame as FunctionCallResultFrame:
            if inProgressCalls[frame.callID] != nil {
                inProgressCalls[frame.callID] = nil
                llmContext.addMessage(
                    LLMContextMessage(
                        role: .tool,
                        content: frame.result,
                        toolCallID: frame.callID
                    )
                )
                let shouldRunLLM = frame.properties?.runLLM ?? frame.runLLM ?? !frame.result.isEmpty
                if shouldRunLLM, !userSpeaking {
                    if botSpeaking {
                        shouldPushContextOnBotStopped = true
                    } else {
                        await pushContextFrame(direction: .upstream, context: context)
                    }
                }
            }
            await context.push(frame, direction: direction)

        case let frame as FunctionCallCancelFrame:
            inProgressCalls[frame.callID] = nil
            await context.push(frame, direction: direction)

        case is LLMRunFrame:
            await pushContextFrame(direction: .upstream, context: context)

        case let frame as LLMMessagesAppendFrame:
            addMessages(frame.messages)
            if frame.runLLM {
                await pushContextFrame(direction: .upstream, context: context)
            }

        case let frame as LLMMessagesUpdateFrame:
            setMessages(frame.messages)
            if frame.runLLM {
                await pushContextFrame(direction: .upstream, context: context)
            }

        case let frame as LLMMessagesTransformFrame:
            transformMessages(frame.transform)
            if frame.runLLM {
                await pushContextFrame(direction: .upstream, context: context)
            }

        case is LLMAssistantPushAggregationFrame:
            await flushAssistantTurnIfNeeded(context: context)

        case is UserStartedSpeakingFrame:
            userSpeaking = true
            await context.push(frame, direction: direction)

        case is UserStoppedSpeakingFrame:
            userSpeaking = false
            await context.push(frame, direction: direction)

        case is BotStartedSpeakingFrame:
            botSpeaking = true
            await context.push(frame, direction: direction)

        case is BotStoppedSpeakingFrame:
            botSpeaking = false
            await context.push(frame, direction: direction)

            if shouldPushContextOnBotStopped, !userSpeaking {
                shouldPushContextOnBotStopped = false
                await pushContextFrame(direction: .upstream, context: context)
            }

        default:
            await context.push(frame, direction: direction)
        }
    }

    private func flushAssistantTurnIfNeeded(context: FrameProcessorContext) async {
        let content = aggregationString().trimmingCharacters(in: .whitespacesAndNewlines)
        resetAggregation()

        guard !content.isEmpty else {
            assistantTurnStartTimestamp = ""
            return
        }

        llmContext.addMessage(
            LLMContextMessage(
                role: .assistant,
                content: content
            )
        )
        await pushContextFrame(direction: .downstream, context: context)
        await context.push(
            LLMContextAssistantTimestampFrame(timestamp: Self.timestampNow()),
            direction: .downstream
        )
        assistantTurnStartTimestamp = ""
    }

    private func clearTurnState() {
        userSpeaking = false
        botSpeaking = false
        shouldPushContextOnBotStopped = false
        assistantTurnStartTimestamp = ""
        inProgressCalls.removeAll(keepingCapacity: true)
    }

    private static func timestampNow() -> String {
        timestampFormatter.string(from: Date())
    }
}
