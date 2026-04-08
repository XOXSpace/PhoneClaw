import CoreImage
import Foundation

// MARK: - Planner 内部数据类型（仅 Planner 使用，文件级私有）

struct ExecutionPlanStep {
    let id: String
    let skill: String
    let tool: String
    let intent: String
    let dependsOn: [String]
}

struct ExecutionPlan {
    let goal: String
    let steps: [ExecutionPlanStep]
    let needsClarification: String?
}

struct SkillSelection {
    let goal: String
    let requiredSkills: [String]
    let needsClarification: String?
}

struct ExecutedPlanStep {
    let step: ExecutionPlanStep
    let toolResult: String
    let toolResultSummary: String
}

extension AgentEngine {

    // MARK: - Skill 描述构造

    func buildAvailableSkillsSummary(
        skillIds: [String],
        compact: Bool = false
    ) -> String {
        let selectedIds = uniqueStringsPreservingOrder(skillIds)
        let chosenEntries: [SkillEntry]
        if selectedIds.isEmpty {
            chosenEntries = skillEntries.filter(\.isEnabled)
        } else {
            let selectedSet = Set(selectedIds)
            chosenEntries = skillEntries.filter { $0.isEnabled && selectedSet.contains($0.id) }
        }

        return chosenEntries.map { entry in
            if compact {
                let tools = registeredTools(for: entry.id).map(\.name).joined(separator: "、")
                return "- \(entry.id): \(tools)"
            } else {
                let tools = registeredTools(for: entry.id).map {
                    "\($0.name): \($0.description)"
                }.joined(separator: "；")
                return """
                - \(entry.id)(\(entry.name)): \(entry.description)
                  可用工具: \(tools)
                """
            }
        }.joined(separator: "\n")
    }

    func recentPlannerContextSummary(limit: Int = 2) -> String {
        let toolNames = Set(
            skillEntries
                .filter(\.isEnabled)
                .flatMap { registeredTools(for: $0.id).map(\.name) }
        )
        guard !toolNames.isEmpty else { return "" }

        var blocks: [String] = []
        for message in messages.reversed() {
            guard message.role == .skillResult,
                  let skillName = message.skillName,
                  toolNames.contains(skillName) else {
                continue
            }

            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let summary: String
            if trimmed.count > 220 {
                summary = String(trimmed.prefix(220)) + "..."
            } else {
                summary = trimmed
            }

            blocks.append("- \(skillName): \(summary)")
            if blocks.count >= limit {
                break
            }
        }

        return blocks.reversed().joined(separator: "\n")
    }

    // MARK: - 计划解析

    func parseExecutionPlan(_ text: String) -> ExecutionPlan? {
        guard let object = parseJSONObject(text) else { return nil }
        let goal = object["goal"] as? String ?? ""
        let needsClarification = object["needs_clarification"] as? String
        let rawSteps = object["steps"] as? [[String: Any]] ?? []

        let steps = rawSteps.compactMap { rawStep -> ExecutionPlanStep? in
            guard let id = rawStep["id"] as? String,
                  let skill = rawStep["skill"] as? String,
                  let tool = rawStep["tool"] as? String,
                  let intent = rawStep["intent"] as? String else {
                return nil
            }
            let dependsOn = rawStep["depends_on"] as? [String] ?? []
            return ExecutionPlanStep(
                id: id,
                skill: skill,
                tool: tool,
                intent: intent,
                dependsOn: dependsOn
            )
        }

        return ExecutionPlan(goal: goal, steps: steps, needsClarification: needsClarification)
    }

    func parseSkillSelection(_ text: String) -> SkillSelection? {
        guard let object = parseJSONObject(text) else { return nil }
        let goal = object["goal"] as? String ?? ""
        let requiredSkills = object["required_skills"] as? [String] ?? []
        let needsClarification = object["needs_clarification"] as? String
        return SkillSelection(
            goal: goal,
            requiredSkills: requiredSkills,
            needsClarification: needsClarification
        )
    }

    func validateSkillSelection(
        _ selection: SkillSelection,
        candidateSkillIds: [String]
    ) -> SkillSelection? {
        let clarification = selection.needsClarification?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let clarification, !clarification.isEmpty {
            return SkillSelection(goal: selection.goal, requiredSkills: [], needsClarification: clarification)
        }

        let normalizedSkills = uniqueStringsPreservingOrder(
            selection.requiredSkills.compactMap { canonicalSkillSelectionEntry($0) }
        )
        guard !normalizedSkills.isEmpty, normalizedSkills.count <= 3 else {
            return nil
        }

        let enabledSkillSet = Set(skillEntries.filter(\.isEnabled).map(\.id))
        let candidateSet = candidateSkillIds.isEmpty ? enabledSkillSet : Set(candidateSkillIds)
        guard normalizedSkills.allSatisfy({
            enabledSkillSet.contains($0) && (candidateSet.contains($0) || candidateSkillIds.isEmpty)
        }) else {
            return nil
        }

        return SkillSelection(
            goal: selection.goal,
            requiredSkills: normalizedSkills,
            needsClarification: nil
        )
    }

    func validateExecutionPlan(
        _ plan: ExecutionPlan,
        candidateSkillIds: [String]
    ) -> ExecutionPlan? {
        let clarification = plan.needsClarification?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let clarification, !clarification.isEmpty, plan.steps.isEmpty {
            return ExecutionPlan(goal: plan.goal, steps: [], needsClarification: clarification)
        }

        guard !plan.steps.isEmpty, plan.steps.count <= 4 else {
            return nil
        }

        let enabledSkillSet = Set(skillEntries.filter(\.isEnabled).map(\.id))
        let candidateSet = candidateSkillIds.isEmpty ? enabledSkillSet : Set(candidateSkillIds)
        var seenStepIds: Set<String> = []
        var previousStepIds: Set<String> = []

        let uniqueSkillCount = Set(plan.steps.map(\.skill)).count
        guard uniqueSkillCount <= 3 else { return nil }

        for step in plan.steps {
            let stepID = step.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let skillID = skillRegistry.canonicalSkillId(for: step.skill)
            let toolName = canonicalToolName(
                step.tool,
                arguments: [:],
                preferredSkillId: step.skill
            )

            guard !stepID.isEmpty,
                  !step.intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !seenStepIds.contains(stepID),
                  enabledSkillSet.contains(skillID),
                  candidateSet.contains(skillID) || candidateSkillIds.isEmpty else {
                return nil
            }

            let allowedToolNames = Set(registeredTools(for: skillID).map(\.name))
            guard allowedToolNames.contains(toolName) else {
                return nil
            }

            guard step.dependsOn.allSatisfy({ previousStepIds.contains($0) }) else {
                return nil
            }

            seenStepIds.insert(stepID)
            previousStepIds.insert(stepID)
        }

        let normalizedSteps = plan.steps.map { step in
            ExecutionPlanStep(
                id: step.id,
                skill: skillRegistry.canonicalSkillId(for: step.skill),
                tool: canonicalToolName(
                    step.tool,
                    arguments: [:],
                    preferredSkillId: step.skill
                ),
                intent: step.intent,
                dependsOn: step.dependsOn
            )
        }

        return ExecutionPlan(goal: plan.goal, steps: normalizedSteps, needsClarification: nil)
    }

    func completedPlanSummary(_ completedSteps: [ExecutedPlanStep]) -> String {
        completedSteps.map { completedStep in
            let summary = completedStep.toolResultSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            let compactSummary: String
            if summary.count > 160 {
                compactSummary = String(summary.prefix(160)) + "..."
            } else {
                compactSummary = summary
            }

            let block = """
            [\(completedStep.step.id)] \(completedStep.step.tool)
            目标:\(completedStep.step.intent)
            可直接给用户的结果:\(compactSummary)
            """

            return block
        }.joined(separator: "\n\n")
    }

    // MARK: - 多 Skill 编排主入口

    @discardableResult
    func executePlannedSkillChainIfPossible(
        prompt: String,
        userQuestion: String,
        images: [CIImage]
    ) async -> Bool {
        let matchedSkills = matchedSkillIds(for: userQuestion)
        log("[Agent] \(plannerRevision) matchedSkills=\(matchedSkills.joined(separator: ","))")
        let candidateSkillIds =
            matchedSkills.count >= 2
            ? matchedSkills
            : skillEntries.filter(\.isEnabled).map(\.id)
        let recentContextSummary = recentPlannerContextSummary()
        let selectedSkillIds: [String]
        if matchedSkills.count >= 2, matchedSkills.count <= 3 {
            selectedSkillIds = matchedSkills
            log("[Agent] skill selection satisfied locally skills=\(selectedSkillIds.joined(separator: ","))")
        } else {
            let selectionSkillsSummary = buildAvailableSkillsSummary(skillIds: candidateSkillIds)
            guard !selectionSkillsSummary.isEmpty else {
                messages.append(ChatMessage(role: .assistant, content: "⚠️ 当前没有可用于编排的 Skill。"))
                isProcessing = false
                return true
            }

            let selectionPrompt = PromptBuilder.buildSkillSelectionPrompt(
                originalPrompt: prompt,
                userQuestion: userQuestion,
                availableSkillsSummary: selectionSkillsSummary,
                recentContextSummary: recentContextSummary,
                currentImageCount: images.count
            )
            log("[Agent] skill selection prompt chars=\(selectionPrompt.count), candidateSkills=\(candidateSkillIds.count)")

            guard let rawSelection = await streamLLM(prompt: selectionPrompt, images: images) else {
                messages.append(ChatMessage(role: .assistant, content: "⚠️ 无法判断需要哪些 Skill，请重试。"))
                isProcessing = false
                return true
            }

            let cleanedSelection = cleanOutput(rawSelection)
            guard let parsedSelection = parseSkillSelection(cleanedSelection),
                  let validatedSelection = validateSkillSelection(parsedSelection, candidateSkillIds: candidateSkillIds) else {
                messages.append(ChatMessage(role: .assistant, content: "⚠️ 当前无法判断需要哪些 Skill，请把需求说得更具体一些。"))
                isProcessing = false
                return true
            }

            if let clarification = validatedSelection.needsClarification,
               !clarification.isEmpty {
                messages.append(ChatMessage(role: .assistant, content: clarification))
                isProcessing = false
                return true
            }

            guard validatedSelection.requiredSkills.count >= 2 else {
                messages.append(ChatMessage(role: .assistant, content: "⚠️ 当前只识别到单一 Skill，请把组合操作说得更明确一些。"))
                isProcessing = false
                return true
            }

            selectedSkillIds = validatedSelection.requiredSkills
            log("[Agent] skill selection accepted skills=\(selectedSkillIds.joined(separator: ","))")
        }

        var loadedInstructions: [String: String] = [:]
        var loadedDisplayNames: [String: String] = [:]
        var skillCardIndices: [String: Int] = [:]
        var completedSteps: [ExecutedPlanStep] = []
        var toolResultsForAnswer: [(toolName: String, result: String)] = []
        var remainingSkillIds = selectedSkillIds
        var planningPass = 0

        func finishPlanning(with message: String? = nil) {
            if let message, !message.isEmpty {
                messages.append(ChatMessage(role: .assistant, content: message))
            }
            markSkillsDone(Array(loadedDisplayNames.values))
            isProcessing = false
        }

        while !remainingSkillIds.isEmpty, planningPass < 3 {
            planningPass += 1

            let combinedContextSummary = [recentContextSummary, completedPlanSummary(completedSteps)]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")

            let availableSkillsSummary = buildAvailableSkillsSummary(
                skillIds: remainingSkillIds,
                compact: true
            )
            guard !availableSkillsSummary.isEmpty else { break }

            let planningPrompt = PromptBuilder.buildSkillPlanningPrompt(
                originalPrompt: prompt,
                userQuestion: userQuestion,
                availableSkillsSummary: availableSkillsSummary,
                recentContextSummary: combinedContextSummary,
                currentImageCount: images.count
            )
            log("[Agent] planner prompt chars=\(planningPrompt.count), candidateSkills=\(remainingSkillIds.count), pass=\(planningPass)")

            guard let rawPlan = await streamLLM(prompt: planningPrompt, images: images) else {
                let message = completedSteps.isEmpty
                    ? "⚠️ 无法生成执行计划，请重试。"
                    : "⚠️ 无法继续规划剩余步骤，请重试。"
                finishPlanning(with: message)
                return true
            }

            let cleanedPlan = cleanOutput(rawPlan)
            guard let parsedPlan = parseExecutionPlan(cleanedPlan),
                  let validatedPlan = validateExecutionPlan(parsedPlan, candidateSkillIds: remainingSkillIds) else {
                let message = completedSteps.isEmpty
                    ? "⚠️ 当前无法生成有效计划，请把需求说得更具体一些。"
                    : "⚠️ 当前无法继续规划剩余步骤，请把需求说得更具体一些。"
                finishPlanning(with: message)
                return true
            }

            if let clarification = validatedPlan.needsClarification,
               !clarification.isEmpty {
                messages.append(ChatMessage(role: .assistant, content: clarification))
                isProcessing = false
                return true
            }

            guard !validatedPlan.steps.isEmpty else {
                let message = completedSteps.isEmpty
                    ? "⚠️ 当前没有可执行步骤，请补充更具体的信息。"
                    : "⚠️ 当前无法继续规划剩余步骤，请补充更具体的信息。"
                finishPlanning(with: message)
                return true
            }

            log("[Agent] planner accepted plan with \(validatedPlan.steps.count) steps")

            let executedSkillIdsThisPass = uniqueStringsPreservingOrder(validatedPlan.steps.map(\.skill))

            for step in validatedPlan.steps {
                if loadedInstructions[step.skill] == nil {
                    let displayName = findDisplayName(for: step.skill)
                    loadedDisplayNames[step.skill] = displayName
                    messages.append(ChatMessage(role: .system, content: "identified", skillName: displayName))
                    let cardIndex = messages.count - 1
                    skillCardIndices[step.skill] = cardIndex

                    guard let instructions = handleLoadSkill(skillName: step.skill) else {
                        messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
                        finishPlanning(with: "⚠️ 无法加载 Skill \(displayName)，已停止执行。")
                        return true
                    }

                    try? await Task.sleep(for: .milliseconds(300))
                    messages[cardIndex].update(role: .system, content: "loaded", skillName: displayName)
                    messages.append(ChatMessage(role: .skillResult, content: instructions, skillName: step.skill))
                    loadedInstructions[step.skill] = instructions
                }

                let displayName = loadedDisplayNames[step.skill] ?? findDisplayName(for: step.skill)
                guard let cardIndex = skillCardIndices[step.skill],
                      let tool = toolRegistry.find(name: step.tool) else {
                    finishPlanning(with: "⚠️ 当前规划步骤无效，已停止执行。")
                    return true
                }

                let arguments: [String: Any]
                if tool.isParameterless {
                    arguments = [:]
                } else {
                    let completedSummary = completedPlanSummary(completedSteps)
                    let argumentsPrompt = PromptBuilder.buildPlannedToolArgumentsPrompt(
                        originalPrompt: prompt,
                        userQuestion: userQuestion,
                        stepIntent: step.intent,
                        toolName: step.tool,
                        toolParameters: tool.parameters,
                        completedStepSummary: completedSummary,
                        currentImageCount: images.count
                    )

                    guard let rawArguments = await streamLLM(prompt: argumentsPrompt, images: images) else {
                        finishPlanning(with: "⚠️ 无法提取步骤参数，请重试。")
                        return true
                    }

                    let cleanedArguments = cleanOutput(rawArguments)
                    guard let payload = parseJSONObject(cleanedArguments) else {
                        finishPlanning(with: "⚠️ 无法提取步骤参数，请把需求说得更具体一些。")
                        return true
                    }

                    if let clarification = payload["_needs_clarification"] as? String,
                       !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        finishPlanning(with: clarification)
                        return true
                    }

                    guard toolRegistry.validatesArguments(payload, for: step.tool) else {
                        finishPlanning(with: "⚠️ 当前步骤缺少必要参数，请把需求说得更具体一些。")
                        return true
                    }

                    arguments = payload
                }

                messages[cardIndex].update(
                    role: .system,
                    content: "executing:\(step.tool)",
                    skillName: displayName
                )

                do {
                    let toolResult = try await handleToolExecution(toolName: step.tool, args: arguments)
                    let toolResultSummary = toolResultSummaryForModel(
                        toolName: step.tool,
                        toolResult: toolResult
                    )

                    messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
                    messages.append(ChatMessage(role: .skillResult, content: toolResultSummary, skillName: step.tool))

                    if let payload = parsedToolPayload(from: toolResult),
                       let success = payload["success"] as? Bool,
                       !success {
                        let error = payload["error"] as? String ?? toolResultSummary
                        finishPlanning(with: error)
                        return true
                    }

                    completedSteps.append(
                        ExecutedPlanStep(
                            step: step,
                            toolResult: toolResult,
                            toolResultSummary: toolResultSummary
                        )
                    )
                    toolResultsForAnswer.append((toolName: step.tool, result: toolResultSummary))
                } catch {
                    messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
                    finishPlanning(with: "❌ Tool 执行失败:\(error.localizedDescription)")
                    return true
                }
            }

            remainingSkillIds.removeAll { executedSkillIdsThisPass.contains($0) }
        }

        if !remainingSkillIds.isEmpty {
            finishPlanning(with: "⚠️ 还缺少部分步骤未完成，请把需求说得更具体一些。")
            return true
        }

        let followUpPrompt = PromptBuilder.buildMultiToolAnswerPrompt(
            originalPrompt: prompt,
            toolResults: toolResultsForAnswer,
            userQuestion: userQuestion,
            currentImageCount: images.count
        )

        messages.append(ChatMessage(role: .assistant, content: "▍"))
        let followUpIndex = messages.count - 1

        guard let nextText = await streamLLM(prompt: followUpPrompt, msgIndex: followUpIndex, images: images) else {
            markSkillsDone(Array(loadedDisplayNames.values))
            isProcessing = false
            return true
        }

        if !parseAllToolCalls(nextText).isEmpty {
            log("[Agent] planner follow-up detected extra tool call")
            messages[followUpIndex].update(content: "")
            await executeToolChain(
                prompt: followUpPrompt,
                fullText: nextText,
                userQuestion: userQuestion,
                images: images
            )
            return true
        }

        let cleaned = cleanOutput(nextText)
        let finalReply: String
        if cleaned.isEmpty
            || looksLikeStructuredIntermediateOutput(cleaned)
            || looksLikePromptEcho(cleaned) {
            finalReply = toolResultsForAnswer.map(\.result).joined(separator: "\n")
        } else {
            finalReply = cleaned
        }

        messages[followUpIndex].update(content: finalReply)
        markSkillsDone(Array(loadedDisplayNames.values))
        isProcessing = false
        return true
    }
}
