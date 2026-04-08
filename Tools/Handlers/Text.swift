import Foundation

enum TextTools {

    static func register(into registry: ToolRegistry) {

        // ── calculate-hash ──
        registry.register(RegisteredTool(
            name: "calculate-hash",
            description: "计算文本的哈希值",
            parameters: "text: 要计算哈希的文本",
            requiredParameters: ["text"]
        ) { args in
            guard let text = args["text"] as? String else {
                return failurePayload(error: "缺少 text 参数")
            }
            let hash = text.hashValue
            return successPayload(
                result: "文本\u{201C}\(text)\u{201D}的哈希值是 \(hash)。",
                extras: [
                    "input": text,
                    "hash": hash
                ]
            )
        })

        // ── text-reverse ──
        registry.register(RegisteredTool(
            name: "text-reverse",
            description: "翻转文本",
            parameters: "text: 要翻转的文本",
            requiredParameters: ["text"]
        ) { args in
            guard let text = args["text"] as? String else {
                return failurePayload(error: "缺少 text 参数")
            }
            let reversed = String(text.reversed())
            return successPayload(
                result: "翻转结果：\(reversed)",
                extras: [
                    "original": text,
                    "reversed": reversed
                ]
            )
        })
    }
}
