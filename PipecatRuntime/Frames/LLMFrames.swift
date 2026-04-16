import Foundation

private let defaultIncompleteShortPrompt = """
The user paused briefly. Generate a brief, natural prompt to encourage them to continue.

IMPORTANT: You MUST respond with ✓ followed by your message. Do NOT output ○ or ◐ - the user has already been given time to continue.

Your response should:
- Be contextually relevant to what was just discussed
- Sound natural and conversational
- Be very concise (1 sentence max)
- Gently prompt them to continue

Example format: ✓ Go ahead, I'm listening.

Generate your ✓ response now.
"""

private let defaultIncompleteLongPrompt = """
The user has been quiet for a while. Generate a friendly check-in message.

IMPORTANT: You MUST respond with ✓ followed by your message. Do NOT output ○ or ◐ - the user has already been given plenty of time.

Your response should:
- Acknowledge they might be thinking or busy
- Offer to help or continue when ready
- Be warm and understanding
- Be brief (1 sentence)

Example format: ✓ No rush! Let me know when you're ready to continue.

Generate your ✓ response now.
"""

private let userTurnCompletionInstructions = """
CRITICAL INSTRUCTION - MANDATORY RESPONSE FORMAT:
Every single response MUST begin with a turn completion indicator. This is not optional.

TURN COMPLETION DECISION FRAMEWORK:
Ask yourself: "Has the user provided enough information for me to give a meaningful, substantive response?"

Mark as COMPLETE (✓) when:
- The user has answered your question with actual content
- The user has made a complete request or statement
- The user has provided all necessary information for you to respond meaningfully
- The conversation can naturally progress to your substantive response

Mark as INCOMPLETE SHORT (○) when the user will likely continue soon:
- The user was clearly cut off mid-sentence or mid-word
- The user is in the middle of a thought that got interrupted
- Brief technical interruption (they'll resume in a few seconds)

Mark as INCOMPLETE LONG (◐) when the user needs more time:
- The user explicitly asks for time: "let me think", "give me a minute", "hold on"
- The user is clearly pondering or deliberating: "hmm", "well...", "that's a good question"
- The user acknowledged but hasn't answered yet: "That's interesting..."
- The response feels like a preamble before the actual answer

RESPOND in one of these three formats:
1. If COMPLETE: `✓` followed by a space and your full substantive response
2. If INCOMPLETE SHORT: ONLY the character `○` (user will continue in a few seconds)
3. If INCOMPLETE LONG: ONLY the character `◐` (user needs more time to think)

KEY INSIGHT: Grammatically complete != conversationally complete
- "That's a really good question." is grammatically complete but conversationally incomplete (use ◐)
- "I'd go to Japan because I love" is mid-sentence (use ○)

FORMAT REQUIREMENTS:
- ALWAYS use single-character indicators: `✓` (complete), `○` (short wait), or `◐` (long wait)
- For COMPLETE: `✓` followed by a space and your full response
- For INCOMPLETE: ONLY the single character (`○` or `◐`) with absolutely nothing else
- Your turn indicator must be the very first character in your response

Remember: Focus on conversational completeness and how long the user might need. Was it a mid-sentence cutoff (○) or do they need time to think (◐)?
"""

struct UserTurnCompletionConfig: Equatable, Sendable {
    let instructions: String?
    let incompleteShortTimeout: TimeInterval
    let incompleteLongTimeout: TimeInterval
    let incompleteShortPrompt: String?
    let incompleteLongPrompt: String?

    init(
        instructions: String? = nil,
        incompleteShortTimeout: TimeInterval = 5.0,
        incompleteLongTimeout: TimeInterval = 10.0,
        incompleteShortPrompt: String? = nil,
        incompleteLongPrompt: String? = nil
    ) {
        self.instructions = instructions
        self.incompleteShortTimeout = incompleteShortTimeout
        self.incompleteLongTimeout = incompleteLongTimeout
        self.incompleteShortPrompt = incompleteShortPrompt
        self.incompleteLongPrompt = incompleteLongPrompt
    }

    var completionInstructions: String {
        instructions ?? userTurnCompletionInstructions
    }

    var shortPrompt: String {
        incompleteShortPrompt ?? defaultIncompleteShortPrompt
    }

    var longPrompt: String {
        incompleteLongPrompt ?? defaultIncompleteLongPrompt
    }
}

enum SettingField<Value: Equatable & Sendable>: Equatable, Sendable {
    case notGiven
    case value(Value)

    static func given(_ value: Value) -> Self {
        .value(value)
    }

    var isGiven: Bool {
        if case .value = self {
            return true
        }
        return false
    }
}

private func boxedSettingValue(_ value: Any) -> Any {
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .optional else {
        return value
    }
    guard let child = mirror.children.first else {
        return NSNull()
    }
    return child.value
}

private func parseOptionalStringField(_ value: Any) -> SettingField<String?>? {
    if value is NSNull {
        return .value(nil)
    }
    guard let string = value as? String else {
        return nil
    }
    return .value(string)
}

private func parseOptionalIntField(_ value: Any) -> SettingField<Int?>? {
    if value is NSNull {
        return .value(nil)
    }
    if let int = value as? Int {
        return .value(int)
    }
    return nil
}

private func parseOptionalDoubleField(_ value: Any) -> SettingField<Double?>? {
    if value is NSNull {
        return .value(nil)
    }
    if let double = value as? Double {
        return .value(double)
    }
    if let int = value as? Int {
        return .value(Double(int))
    }
    return nil
}

private func parseOptionalBoolField(_ value: Any) -> SettingField<Bool?>? {
    if value is NSNull {
        return .value(nil)
    }
    guard let bool = value as? Bool else {
        return nil
    }
    return .value(bool)
}

private func parseUserTurnCompletionConfigField(_ value: Any) -> SettingField<UserTurnCompletionConfig?>? {
    if value is NSNull {
        return .value(nil)
    }
    guard let rawConfig = value as? [String: Any] else {
        return nil
    }
    return .value(
        UserTurnCompletionConfig(
            instructions: rawConfig["instructions"] as? String,
            incompleteShortTimeout: rawConfig["incomplete_short_timeout"] as? TimeInterval ?? 5.0,
            incompleteLongTimeout: rawConfig["incomplete_long_timeout"] as? TimeInterval ?? 10.0,
            incompleteShortPrompt: rawConfig["incomplete_short_prompt"] as? String,
            incompleteLongPrompt: rawConfig["incomplete_long_prompt"] as? String
        )
    )
}

class ServiceSettings: @unchecked Sendable {
    var model: SettingField<String?>
    var extra: [String: Any]

    required init() {
        self.model = .notGiven
        self.extra = [:]
    }

    init(
        model: SettingField<String?> = .notGiven,
        extra: [String: Any] = [:]
    ) {
        self.model = model
        self.extra = extra
    }

    class var aliases: [String: String] {
        [:]
    }

    func givenFields() -> [String: Any] {
        var result: [String: Any] = [:]
        appendField(named: "model", value: model, into: &result)
        result.merge(extra) { _, new in new }
        return result
    }

    func applyUpdate(_ delta: ServiceSettings) -> [String: Any] {
        var changed: [String: Any] = [:]
        applyField(named: "model", delta: delta.model, current: &model, changed: &changed)
        for (key, newValue) in delta.extra {
            let oldValue = extra[key]
            if oldValue == nil || !areSettingsValuesEqual(oldValue!, newValue) {
                extra[key] = newValue
                changed[key] = oldValue ?? NSNull()
            }
        }
        return changed
    }

    func validateComplete() -> [String] {
        var missing: [String] = []
        if case .notGiven = model {
            missing.append("model")
        }
        return missing
    }

    class func fromMapping(_ settings: [String: Any]) -> Self {
        let instance = self.init()
        var extra: [String: Any] = [:]

        for (key, value) in settings {
            let canonical = aliases[key] ?? key
            if !instance.applyMappedValue(canonicalKey: canonical, value: value) {
                extra[key] = value
            }
        }

        instance.extra = extra
        return instance
    }

    func copy() -> Self {
        let cloned = type(of: self).init()
        cloned.model = model
        cloned.extra = extra
        return cloned
    }

    func applyMappedValue(canonicalKey: String, value: Any) -> Bool {
        guard canonicalKey == "model",
              let parsed = parseOptionalStringField(value) else {
            return false
        }
        model = parsed
        return true
    }

    var resolvedModel: String? {
        guard case let .value(value) = model else {
            return nil
        }
        return value
    }

    func appendField<Value: Equatable & Sendable>(
        named name: String,
        value: SettingField<Value>,
        into result: inout [String: Any]
    ) {
        guard case let .value(actualValue) = value else {
            return
        }
        result[name] = boxedSettingValue(actualValue)
    }

    func applyField<Value: Equatable & Sendable>(
        named name: String,
        delta: SettingField<Value>,
        current: inout SettingField<Value>,
        changed: inout [String: Any]
    ) {
        guard case let .value(newValue) = delta else {
            return
        }
        let newField = SettingField<Value>.value(newValue)
        guard current != newField else {
            return
        }
        if case let .value(oldValue) = current {
            changed[name] = boxedSettingValue(oldValue)
        } else {
            changed[name] = NSNull()
        }
        current = newField
    }

    private func areSettingsValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (lhs as String, rhs as String):
            return lhs == rhs
        case let (lhs as Int, rhs as Int):
            return lhs == rhs
        case let (lhs as Double, rhs as Double):
            return lhs == rhs
        case let (lhs as Bool, rhs as Bool):
            return lhs == rhs
        case let (lhs as UserTurnCompletionConfig, rhs as UserTurnCompletionConfig):
            return lhs == rhs
        case (_ as NSNull, _ as NSNull):
            return true
        default:
            return false
        }
    }
}

final class LLMSettings: ServiceSettings, @unchecked Sendable {
    var systemInstruction: SettingField<String?>
    var temperature: SettingField<Double?>
    var maxTokens: SettingField<Int?>
    var topP: SettingField<Double?>
    var topK: SettingField<Int?>
    var frequencyPenalty: SettingField<Double?>
    var presencePenalty: SettingField<Double?>
    var seed: SettingField<Int?>
    var filterIncompleteUserTurns: SettingField<Bool?>
    var userTurnCompletionConfig: SettingField<UserTurnCompletionConfig?>

    required init() {
        self.systemInstruction = .notGiven
        self.temperature = .notGiven
        self.maxTokens = .notGiven
        self.topP = .notGiven
        self.topK = .notGiven
        self.frequencyPenalty = .notGiven
        self.presencePenalty = .notGiven
        self.seed = .notGiven
        self.filterIncompleteUserTurns = .notGiven
        self.userTurnCompletionConfig = .notGiven
        super.init()
    }

    init(
        model: SettingField<String?> = .notGiven,
        extra: [String: Any] = [:],
        systemInstruction: SettingField<String?> = .notGiven,
        temperature: SettingField<Double?> = .notGiven,
        maxTokens: SettingField<Int?> = .notGiven,
        topP: SettingField<Double?> = .notGiven,
        topK: SettingField<Int?> = .notGiven,
        frequencyPenalty: SettingField<Double?> = .notGiven,
        presencePenalty: SettingField<Double?> = .notGiven,
        seed: SettingField<Int?> = .notGiven,
        filterIncompleteUserTurns: SettingField<Bool?> = .notGiven,
        userTurnCompletionConfig: SettingField<UserTurnCompletionConfig?> = .notGiven
    ) {
        self.systemInstruction = systemInstruction
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.topK = topK
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.seed = seed
        self.filterIncompleteUserTurns = filterIncompleteUserTurns
        self.userTurnCompletionConfig = userTurnCompletionConfig
        super.init(model: model, extra: extra)
    }

    convenience init(
        filterIncompleteUserTurns: Bool? = nil,
        userTurnCompletionConfig: UserTurnCompletionConfig? = nil
    ) {
        self.init(
            filterIncompleteUserTurns: filterIncompleteUserTurns.map { .value($0) } ?? .notGiven,
            userTurnCompletionConfig: userTurnCompletionConfig.map { .value($0) } ?? .notGiven
        )
    }

    static func defaultStore() -> LLMSettings {
        LLMSettings(
            model: .value(nil),
            systemInstruction: .value(nil),
            temperature: .value(nil),
            maxTokens: .value(nil),
            topP: .value(nil),
            topK: .value(nil),
            frequencyPenalty: .value(nil),
            presencePenalty: .value(nil),
            seed: .value(nil),
            filterIncompleteUserTurns: .value(false),
            userTurnCompletionConfig: .value(UserTurnCompletionConfig())
        )
    }

    override func givenFields() -> [String: Any] {
        var result = super.givenFields()
        appendField(named: "system_instruction", value: systemInstruction, into: &result)
        appendField(named: "temperature", value: temperature, into: &result)
        appendField(named: "max_tokens", value: maxTokens, into: &result)
        appendField(named: "top_p", value: topP, into: &result)
        appendField(named: "top_k", value: topK, into: &result)
        appendField(named: "frequency_penalty", value: frequencyPenalty, into: &result)
        appendField(named: "presence_penalty", value: presencePenalty, into: &result)
        appendField(named: "seed", value: seed, into: &result)
        appendField(
            named: "filter_incomplete_user_turns",
            value: filterIncompleteUserTurns,
            into: &result
        )
        appendField(
            named: "user_turn_completion_config",
            value: userTurnCompletionConfig,
            into: &result
        )
        return result
    }

    override func applyUpdate(_ delta: ServiceSettings) -> [String: Any] {
        var changed = super.applyUpdate(delta)
        guard let delta = delta as? LLMSettings else {
            return changed
        }

        applyField(named: "system_instruction", delta: delta.systemInstruction, current: &systemInstruction, changed: &changed)
        applyField(named: "temperature", delta: delta.temperature, current: &temperature, changed: &changed)
        applyField(named: "max_tokens", delta: delta.maxTokens, current: &maxTokens, changed: &changed)
        applyField(named: "top_p", delta: delta.topP, current: &topP, changed: &changed)
        applyField(named: "top_k", delta: delta.topK, current: &topK, changed: &changed)
        applyField(named: "frequency_penalty", delta: delta.frequencyPenalty, current: &frequencyPenalty, changed: &changed)
        applyField(named: "presence_penalty", delta: delta.presencePenalty, current: &presencePenalty, changed: &changed)
        applyField(named: "seed", delta: delta.seed, current: &seed, changed: &changed)
        applyField(
            named: "filter_incomplete_user_turns",
            delta: delta.filterIncompleteUserTurns,
            current: &filterIncompleteUserTurns,
            changed: &changed
        )
        applyField(
            named: "user_turn_completion_config",
            delta: delta.userTurnCompletionConfig,
            current: &userTurnCompletionConfig,
            changed: &changed
        )
        return changed
    }

    override func validateComplete() -> [String] {
        var missing = super.validateComplete()
        let additional: [(String, Bool)] = [
            ("system_instruction", systemInstruction.isGiven),
            ("temperature", temperature.isGiven),
            ("max_tokens", maxTokens.isGiven),
            ("top_p", topP.isGiven),
            ("top_k", topK.isGiven),
            ("frequency_penalty", frequencyPenalty.isGiven),
            ("presence_penalty", presencePenalty.isGiven),
            ("seed", seed.isGiven),
            ("filter_incomplete_user_turns", filterIncompleteUserTurns.isGiven),
            ("user_turn_completion_config", userTurnCompletionConfig.isGiven)
        ]
        missing.append(contentsOf: additional.compactMap { $0.1 ? nil : $0.0 })
        return missing
    }

    override func copy() -> Self {
        LLMSettings(
            model: model,
            extra: extra,
            systemInstruction: systemInstruction,
            temperature: temperature,
            maxTokens: maxTokens,
            topP: topP,
            topK: topK,
            frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty,
            seed: seed,
            filterIncompleteUserTurns: filterIncompleteUserTurns,
            userTurnCompletionConfig: userTurnCompletionConfig
        ) as! Self
    }

    override func applyMappedValue(canonicalKey: String, value: Any) -> Bool {
        if super.applyMappedValue(canonicalKey: canonicalKey, value: value) {
            return true
        }

        switch canonicalKey {
        case "system_instruction":
            guard let parsed = parseOptionalStringField(value) else { return false }
            systemInstruction = parsed
        case "temperature":
            guard let parsed = parseOptionalDoubleField(value) else { return false }
            temperature = parsed
        case "max_tokens":
            guard let parsed = parseOptionalIntField(value) else { return false }
            maxTokens = parsed
        case "top_p":
            guard let parsed = parseOptionalDoubleField(value) else { return false }
            topP = parsed
        case "top_k":
            guard let parsed = parseOptionalIntField(value) else { return false }
            topK = parsed
        case "frequency_penalty":
            guard let parsed = parseOptionalDoubleField(value) else { return false }
            frequencyPenalty = parsed
        case "presence_penalty":
            guard let parsed = parseOptionalDoubleField(value) else { return false }
            presencePenalty = parsed
        case "seed":
            guard let parsed = parseOptionalIntField(value) else { return false }
            seed = parsed
        case "filter_incomplete_user_turns":
            guard let parsed = parseOptionalBoolField(value) else { return false }
            filterIncompleteUserTurns = parsed
        case "user_turn_completion_config":
            guard let parsed = parseUserTurnCompletionConfigField(value) else { return false }
            userTurnCompletionConfig = parsed
        default:
            return false
        }
        return true
    }

    var resolvedSystemInstruction: String? {
        guard case let .value(value) = systemInstruction else {
            return nil
        }
        return value
    }

    var resolvedFilterIncompleteUserTurns: Bool {
        guard case let .value(value) = filterIncompleteUserTurns else {
            return false
        }
        return value ?? false
    }

    var resolvedUserTurnCompletionConfig: UserTurnCompletionConfig? {
        guard case let .value(value) = userTurnCompletionConfig else {
            return nil
        }
        return value
    }
}

final class TTSSettings: ServiceSettings, @unchecked Sendable {
    override class var aliases: [String: String] {
        ["voice_id": "voice"]
    }

    var voice: SettingField<String?>
    var language: SettingField<String?>

    required init() {
        self.voice = .notGiven
        self.language = .notGiven
        super.init()
    }

    init(
        model: SettingField<String?> = .notGiven,
        extra: [String: Any] = [:],
        voice: SettingField<String?> = .notGiven,
        language: SettingField<String?> = .notGiven
    ) {
        self.voice = voice
        self.language = language
        super.init(model: model, extra: extra)
    }

    convenience init(
        model: String? = nil,
        voice: String? = nil,
        language: String? = nil
    ) {
        self.init(
            model: model.map { .value($0) } ?? .notGiven,
            voice: voice.map { .value($0) } ?? .notGiven,
            language: language.map { .value($0) } ?? .notGiven
        )
    }

    static func defaultStore() -> TTSSettings {
        TTSSettings(
            model: .value(nil),
            voice: .value(nil),
            language: .value(nil)
        )
    }

    override func givenFields() -> [String: Any] {
        var result = super.givenFields()
        appendField(named: "voice", value: voice, into: &result)
        appendField(named: "language", value: language, into: &result)
        return result
    }

    override func applyUpdate(_ delta: ServiceSettings) -> [String: Any] {
        var changed = super.applyUpdate(delta)
        guard let delta = delta as? TTSSettings else {
            return changed
        }

        applyField(named: "voice", delta: delta.voice, current: &voice, changed: &changed)
        applyField(named: "language", delta: delta.language, current: &language, changed: &changed)
        return changed
    }

    override func validateComplete() -> [String] {
        var missing = super.validateComplete()
        let additional: [(String, Bool)] = [
            ("voice", voice.isGiven),
            ("language", language.isGiven)
        ]
        missing.append(contentsOf: additional.compactMap { $0.1 ? nil : $0.0 })
        return missing
    }

    override func copy() -> Self {
        TTSSettings(
            model: model,
            extra: extra,
            voice: voice,
            language: language
        ) as! Self
    }

    override func applyMappedValue(canonicalKey: String, value: Any) -> Bool {
        if super.applyMappedValue(canonicalKey: canonicalKey, value: value) {
            return true
        }

        switch canonicalKey {
        case "voice":
            guard let parsed = parseOptionalStringField(value) else { return false }
            voice = parsed
        case "language":
            guard let parsed = parseOptionalStringField(value) else { return false }
            language = parsed
        default:
            return false
        }
        return true
    }

    var resolvedVoice: String? {
        guard case let .value(value) = voice else {
            return nil
        }
        return value
    }

    var resolvedLanguage: String? {
        guard case let .value(value) = language else {
            return nil
        }
        return value
    }
}

final class STTSettings: ServiceSettings, @unchecked Sendable {
    var language: SettingField<String?>

    required init() {
        self.language = .notGiven
        super.init()
    }

    init(
        model: SettingField<String?> = .notGiven,
        extra: [String: Any] = [:],
        language: SettingField<String?> = .notGiven
    ) {
        self.language = language
        super.init(model: model, extra: extra)
    }

    convenience init(
        model: String? = nil,
        language: String? = nil
    ) {
        self.init(
            model: model.map { .value($0) } ?? .notGiven,
            language: language.map { .value($0) } ?? .notGiven
        )
    }

    static func defaultStore() -> STTSettings {
        STTSettings(
            model: .value(nil),
            language: .value(nil)
        )
    }

    override func givenFields() -> [String: Any] {
        var result = super.givenFields()
        appendField(named: "language", value: language, into: &result)
        return result
    }

    override func applyUpdate(_ delta: ServiceSettings) -> [String: Any] {
        var changed = super.applyUpdate(delta)
        guard let delta = delta as? STTSettings else {
            return changed
        }

        applyField(named: "language", delta: delta.language, current: &language, changed: &changed)
        return changed
    }

    override func validateComplete() -> [String] {
        var missing = super.validateComplete()
        if !language.isGiven {
            missing.append("language")
        }
        return missing
    }

    override func copy() -> Self {
        STTSettings(
            model: model,
            extra: extra,
            language: language
        ) as! Self
    }

    override func applyMappedValue(canonicalKey: String, value: Any) -> Bool {
        if super.applyMappedValue(canonicalKey: canonicalKey, value: value) {
            return true
        }

        guard canonicalKey == "language",
              let parsed = parseOptionalStringField(value) else {
            return false
        }
        language = parsed
        return true
    }

    var resolvedLanguage: String? {
        guard case let .value(value) = language else {
            return nil
        }
        return value
    }
}

class ServiceUpdateSettingsFrame: ControlFrame, UninterruptibleFrame, @unchecked Sendable {
    let settings: [String: Any]
    let delta: ServiceSettings?
    let service: FrameProcessor?

    init(
        settings: [String: Any] = [:],
        delta: ServiceSettings? = nil,
        service: FrameProcessor? = nil
    ) {
        self.settings = settings
        self.delta = delta
        self.service = service
        super.init()
    }
}

final class LLMUpdateSettingsFrame: ServiceUpdateSettingsFrame, @unchecked Sendable {
    init(
        settings: [String: Any] = [:],
        delta: LLMSettings? = nil,
        service: FrameProcessor? = nil
    ) {
        super.init(settings: settings, delta: delta, service: service)
    }

    var llmDelta: LLMSettings? {
        delta as? LLMSettings
    }
}

final class TTSUpdateSettingsFrame: ServiceUpdateSettingsFrame, @unchecked Sendable {
    init(
        settings: [String: Any] = [:],
        delta: TTSSettings? = nil,
        service: FrameProcessor? = nil
    ) {
        super.init(settings: settings, delta: delta, service: service)
    }

    var ttsDelta: TTSSettings? {
        delta as? TTSSettings
    }
}

final class STTUpdateSettingsFrame: ServiceUpdateSettingsFrame, @unchecked Sendable {
    init(
        settings: [String: Any] = [:],
        delta: STTSettings? = nil,
        service: FrameProcessor? = nil
    ) {
        super.init(settings: settings, delta: delta, service: service)
    }

    var sttDelta: STTSettings? {
        delta as? STTSettings
    }
}

class TextFrame: DataFrame, @unchecked Sendable {
    let text: String
    var skipTTS: Bool?
    var includesInterFrameSpaces: Bool
    var appendToContext: Bool

    init(text: String) {
        self.text = text
        self.skipTTS = nil
        self.includesInterFrameSpaces = false
        self.appendToContext = true
        super.init()
    }
}

final class LLMContextFrame: DataFrame, @unchecked Sendable {
    let context: LLMContext

    init(context: LLMContext) {
        self.context = context.copy()
        super.init()
    }
}

final class LLMRunFrame: DataFrame, @unchecked Sendable {}

final class LLMMessagesAppendFrame: DataFrame, @unchecked Sendable {
    let messages: [LLMContextMessage]
    let runLLM: Bool

    init(messages: [LLMContextMessage], runLLM: Bool = false) {
        self.messages = messages
        self.runLLM = runLLM
        super.init()
    }
}

final class LLMMessagesUpdateFrame: DataFrame, @unchecked Sendable {
    let messages: [LLMContextMessage]
    let runLLM: Bool

    init(messages: [LLMContextMessage], runLLM: Bool = false) {
        self.messages = messages
        self.runLLM = runLLM
        super.init()
    }
}

final class LLMMessagesTransformFrame: DataFrame, @unchecked Sendable {
    let transform: @Sendable ([LLMContextMessage]) -> [LLMContextMessage]
    let runLLM: Bool

    init(
        transform: @escaping @Sendable ([LLMContextMessage]) -> [LLMContextMessage],
        runLLM: Bool = false
    ) {
        self.transform = transform
        self.runLLM = runLLM
        super.init()
    }
}

final class LLMTextFrame: TextFrame, @unchecked Sendable {
    init(text: String, appendToContext: Bool = true, skipTTS: Bool = false) {
        super.init(text: text)
        self.includesInterFrameSpaces = true
        self.appendToContext = appendToContext
        self.skipTTS = skipTTS
    }
}

final class TTSTextFrame: TextFrame, @unchecked Sendable {
    let contextID: String?

    init(text: String, contextID: String? = nil, appendToContext: Bool = true) {
        self.contextID = contextID
        super.init(text: text)
        self.appendToContext = appendToContext
    }
}

final class LLMFullResponseStartFrame: ControlFrame, @unchecked Sendable {
    var skipTTS: Bool?

    override init(id: UUID = UUID(), createdAt: Date = Date()) {
        self.skipTTS = nil
        super.init(id: id, createdAt: createdAt)
    }
}

final class LLMFullResponseEndFrame: ControlFrame, @unchecked Sendable {
    var skipTTS: Bool?

    override init(id: UUID = UUID(), createdAt: Date = Date()) {
        self.skipTTS = nil
        super.init(id: id, createdAt: createdAt)
    }
}

final class LLMAssistantPushAggregationFrame: ControlFrame, @unchecked Sendable {}

final class LLMContextAssistantTimestampFrame: DataFrame, @unchecked Sendable {
    let timestamp: String

    init(timestamp: String) {
        self.timestamp = timestamp
        super.init()
    }
}
