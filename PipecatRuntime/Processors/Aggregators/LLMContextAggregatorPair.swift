import Foundation

final class LLMContextAggregatorPair {
    let context: LLMContext
    let user: LLMUserAggregator
    let assistant: LLMAssistantAggregator

    init(
        context: LLMContext = LLMContext(),
        userParams: LLMUserAggregatorParams = LLMUserAggregatorParams()
    ) {
        self.context = context
        self.user = LLMUserAggregator(context: context, params: userParams)
        self.assistant = LLMAssistantAggregator(context: context)
    }
}
