import Foundation
import MLX
import MLXLMCommon

// MARK: - KV Cache Reuse
//
// Cross-turn prompt prefix caching for text-only inference.
//
// Gemma 4 E4B re-prefills the entire prompt every generateStream call, which at
// Phase 2 skill-expanded prompt size (~400 tok system + turn history) costs
// ~200ms TTFT per turn. Python probe (phoneclaw_probe/kv_reuse_multi.py) measured
// a 1.9x speedup (355ms → 182ms) by holding one KVCache across turns and only
// prefilling the delta since the last call.
//
// Strategy:
// 1. Service holds one `activeCache` + `cachedPromptTokens` (IDs processed into cache)
// 2. On each text-only generateStream:
//    a. Tokenize via processor (unchanged path)
//    b. Diff new prompt tokens vs cached → common prefix length
//    c. Trim cache to commonPrefix, feed only delta tokens via generate(cache:)
// 3. After generation, trim cache back to the prompt length so the next diff
//    is based on the exact prompt content (not mixed with generated tokens,
//    whose IDs may not match the retokenized assistant reply on the next turn).
//
// Scope:
// - Text-only path only. Multimodal (images/audio) bypasses cache reuse entirely
//   because image tokens get replaced with embeddings downstream.
// - Cache is invalidated on: model load/unload, multimodal call, generation
//   cancellation, or any error during generation.
// - Feature flag `kvReuseEnabled` defaults true; harness/tests can flip it off
//   to verify cache-on vs cache-off parity.

extension MLXLocalLLMService {

    /// Decision produced by the cache-reuse planner for one call.
    struct KVReusePlan {
        let cache: [KVCache]
        let deltaInput: LMInput
        let fullPromptTokens: [Int]
        let commonPrefix: Int
        let isFreshCache: Bool
    }

    /// Plan a cache-reuse path for the given prepared input.
    ///
    /// Returns nil if reuse is disabled or not applicable; callers should fall
    /// back to the no-cache path in that case.
    func planKVReuse(
        preparedInput: LMInput,
        model: any LanguageModel,
        parameters: GenerateParameters,
        isMultimodal: Bool
    ) -> KVReusePlan? {
        guard kvReuseEnabled, !isMultimodal else { return nil }
        // Text-only path: flatten to 1D Int array
        let tokensArray = preparedInput.text.tokens
        // Expected shape [1, S]; fall back to whatever asArray yields
        let flatTokens: [Int] = tokensArray.asArray(Int.self)
        guard !flatTokens.isEmpty else { return nil }

        var commonPrefix = 0
        if let cache = activeCache {
            let maxCompare = min(cachedPromptTokens.count, flatTokens.count)
            var i = 0
            while i < maxCompare && cachedPromptTokens[i] == flatTokens[i] {
                i += 1
            }
            commonPrefix = i
            // Need at least 1 new token to feed; if new prompt is identical
            // or is a prefix of the cached one, invalidate and take fresh path.
            if commonPrefix >= flatTokens.count || commonPrefix == 0 {
                invalidateKVReuseCache()
                return buildFreshPlan(
                    flatTokens: flatTokens,
                    model: model,
                    parameters: parameters
                )
            }
            // Trim cache to the reuse boundary
            let excess = cache[0].offset - commonPrefix
            if excess > 0 {
                _ = trimPromptCache(cache, numTokens: excess)
            }
            let deltaIds = Array(flatTokens[commonPrefix...])
            let deltaInput = makeLMInput(fromTokens: deltaIds)
            print(
                "[MLX] KV reuse — cached=\(cachedPromptTokens.count)t "
                    + "new=\(flatTokens.count)t common=\(commonPrefix)t "
                    + "delta=\(deltaIds.count)t"
            )
            return KVReusePlan(
                cache: cache,
                deltaInput: deltaInput,
                fullPromptTokens: flatTokens,
                commonPrefix: commonPrefix,
                isFreshCache: false
            )
        }

        return buildFreshPlan(
            flatTokens: flatTokens,
            model: model,
            parameters: parameters
        )
    }

    private func buildFreshPlan(
        flatTokens: [Int],
        model: any LanguageModel,
        parameters: GenerateParameters
    ) -> KVReusePlan {
        let newCache = model.newCache(parameters: parameters)
        let fullInput = makeLMInput(fromTokens: flatTokens)
        print("[MLX] KV reuse — fresh cache, prompt=\(flatTokens.count)t")
        return KVReusePlan(
            cache: newCache,
            deltaInput: fullInput,
            fullPromptTokens: flatTokens,
            commonPrefix: 0,
            isFreshCache: true
        )
    }

    /// Commit a successful generation: persist cache and the prompt tokens it
    /// corresponds to. Also trim any generated-token state out of the cache so
    /// the next diff starts from the exact prompt boundary.
    func commitKVReuse(plan: KVReusePlan) {
        // Drop generated tokens' K/V: cache currently has
        //   [commonPrefix tokens from before] + [delta prompt tokens] + [generated tokens]
        // We want cache to end at fullPromptTokens.count.
        let targetLen = plan.fullPromptTokens.count
        let excess = plan.cache[0].offset - targetLen
        if excess > 0 {
            _ = trimPromptCache(plan.cache, numTokens: excess)
        }
        activeCache = plan.cache
        cachedPromptTokens = plan.fullPromptTokens
    }

    /// Drop any cached state. Call on model reload, cancellation, multimodal
    /// entry, or any error path where cache correctness is uncertain.
    func invalidateKVReuseCache() {
        if activeCache != nil {
            print("[MLX] KV reuse — cache invalidated")
        }
        activeCache = nil
        cachedPromptTokens = []
    }

    private func makeLMInput(fromTokens tokens: [Int]) -> LMInput {
        let ids = tokens.map { Int32($0) }
        let array = MLXArray(ids).reshaped([1, ids.count])
        return LMInput(text: .init(tokens: array))
    }
}
