import Foundation
import CodexCore

extension CodexAgentStateMapper {
    mutating func applyCollabAgentToolCall(_ item: ThreadItem, completed: Bool) -> CodexAgentItemUpdate? {
        guard let payload = CodexAgentItemParser.collabPayload(from: item) else { return nil }

        if payload.tool == "spawnAgent", !completed, payload.receiverThreadIDs.isEmpty {
            appendLifecycleEvent(CodexAgentLifecycleBuilder.collabSpawnStarting(prompt: payload.prompt))
            ensureSideChat()
            return CodexAgentItemUpdate(
                activityTitle: "Subagent spawning",
                activityDetail: CodexAgentItemParser.previewText(payload.prompt)
            )
        }

        guard !payload.receiverThreadIDs.isEmpty else {
            ensureSideChat()
            return CodexAgentItemUpdate(
                activityTitle: CodexAgentItemParser.humanCollabToolTitle(payload.tool, completed: completed),
                activityDetail: CodexAgentItemParser.previewText(payload.prompt)
            )
        }

        let status = payload.status(completed: completed)
        let now = Date()
        var names: [String] = []
        var resultText: String?
        for receiverID in payload.receiverThreadIDs {
            let state = payload.states[receiverID]
            let result = CodexAgentItemParser.firstString(in: state ?? [:], keys: ["message", "summary", "result"])
            if resultText == nil { resultText = result }
            let name = nameForSubagent(id: receiverID, state: state)
            names.append(name)
            upsertSubagent(
                id: receiverID,
                name: name,
                title: CodexAgentItemParser.titleForCollabPrompt(payload.prompt),
                prompt: payload.prompt,
                status: status,
                itemID: item.id,
                result: result,
                createdAt: status == .running ? now : nil,
                completedAt: status == .running ? nil : now
            )
        }

        appendLifecycleEvent(CodexAgentLifecycleBuilder.collabToolCall(
            tool: payload.tool,
            completed: completed,
            status: status,
            names: names,
            resultText: resultText,
            prompt: payload.prompt,
            createdAt: now
        ))
        ensureSideChat()
        return CodexAgentItemUpdate(
            activityTitle: CodexAgentItemParser.humanCollabToolTitle(payload.tool, completed: completed),
            activityDetail: names.joined(separator: ", ")
        )
    }
}
