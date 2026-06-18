import Foundation
import CodexCore

enum CodexAgentLifecycleBuilder {
    static func spawning(
        agents: [CodexSubagentDescriptor],
        item: ThreadItem
    ) -> CodexAgentLifecycleEvent {
        let agentNames = agents.map(\.name)
        return CodexAgentLifecycleEvent(
            status: .spawning,
            title: agentNames.count == 1 ? "Spawning 1 agent" : "Spawning \(agentNames.count) agents",
            detail: CodexAgentItemParser.lifecycleDetail(for: item, fallback: "Delegating focused work to side agents."),
            agentNames: agentNames
        )
    }

    static func finished(
        status: CodexSubagentState.Status,
        item: ThreadItem,
        result: String?,
        names: [String],
        fallback: String,
        createdAt: Date
    ) -> CodexAgentLifecycleEvent {
        CodexAgentLifecycleEvent(
            status: lifecycleStatus(from: status),
            title: CodexAgentItemParser.lifecycleTitle(status: status, count: names.count),
            detail: CodexAgentItemParser.lifecycleDetail(for: item, fallback: result ?? fallback),
            agentNames: names,
            createdAt: createdAt
        )
    }

    static func turnFinished(
        status: CodexSubagentState.Status,
        name: String,
        detail: String,
        createdAt: Date
    ) -> CodexAgentLifecycleEvent {
        CodexAgentLifecycleEvent(
            status: lifecycleStatus(from: status),
            title: CodexAgentItemParser.lifecycleTitle(status: status, count: 1),
            detail: detail,
            agentNames: [name],
            createdAt: createdAt
        )
    }

    static func collabSpawnStarting(prompt: String) -> CodexAgentLifecycleEvent {
        CodexAgentLifecycleEvent(
            status: .spawning,
            title: "Spawning agent",
            detail: prompt == "Subagent task" ? "Starting delegated agent." : prompt
        )
    }

    static func collabToolCall(
        tool: String,
        completed: Bool,
        status: CodexSubagentState.Status,
        names: [String],
        resultText: String?,
        prompt: String,
        createdAt: Date
    ) -> CodexAgentLifecycleEvent {
        CodexAgentLifecycleEvent(
            status: lifecycleStatus(from: status),
            title: CodexAgentItemParser.collabLifecycleTitle(
                tool: tool,
                completed: completed,
                status: status,
                names: names
            ),
            detail: resultText ?? (prompt == "Subagent task" ? CodexAgentItemParser.humanCollabToolTitle(tool, completed: completed) : prompt),
            agentNames: names,
            createdAt: createdAt
        )
    }

    static func lifecycleStatus(from status: CodexSubagentState.Status) -> CodexAgentLifecycleEvent.Status {
        switch status {
        case .running: return .running
        case .completed: return .completed
        case .closed: return .closed
        case .failed: return .failed
        }
    }
}
