import Foundation

struct FunctionCallPayload: Equatable, Sendable {
    let name: String
    let arguments: String
}

struct FunctionCallResultProperties: Equatable, Sendable {
    let runLLM: Bool?
    let isFinal: Bool

    init(runLLM: Bool? = nil, isFinal: Bool = true) {
        self.runLLM = runLLM
        self.isFinal = isFinal
    }
}

final class FunctionCallsStartedFrame: SystemFrame, @unchecked Sendable {
    let functionCalls: [FunctionCallPayload]

    init(functionCalls: [FunctionCallPayload]) {
        self.functionCalls = functionCalls
        super.init()
    }
}

final class FunctionCallCancelFrame: SystemFrame, @unchecked Sendable {
    let callID: String

    init(callID: String) {
        self.callID = callID
        super.init()
    }
}

final class FunctionCallInProgressFrame: ControlFrame, UninterruptibleFrame, @unchecked Sendable {
    let callID: String
    let payload: FunctionCallPayload
    let cancelOnInterruption: Bool

    init(
        callID: String,
        payload: FunctionCallPayload,
        cancelOnInterruption: Bool = false
    ) {
        self.callID = callID
        self.payload = payload
        self.cancelOnInterruption = cancelOnInterruption
        super.init()
    }
}

final class FunctionCallResultFrame: DataFrame, UninterruptibleFrame, @unchecked Sendable {
    let callID: String
    let result: String
    let runLLM: Bool?
    let properties: FunctionCallResultProperties?

    init(
        callID: String,
        result: String,
        runLLM: Bool? = nil,
        properties: FunctionCallResultProperties? = nil
    ) {
        self.callID = callID
        self.result = result
        self.runLLM = runLLM
        self.properties = properties
        super.init()
    }
}
