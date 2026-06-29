import Foundation
@testable import CodexCoreUI

struct AgentUIFixture {
    var sideChat: CodexSideChatState
    var subagents: [CodexSubagentState]

    static func make() -> AgentUIFixture {
        let now = Date(timeIntervalSince1970: 1_000)
        let sideChat = CodexSideChatState(
            messages: [
                CodexChatMessage(role: .user, text: "Open a focused branch", createdAt: now),
                CodexChatMessage(role: .assistant, text: "Branch ready", createdAt: now.addingTimeInterval(1))
            ],
            createdAt: now
        )

        let subagents = [
            CodexSubagentState(
                name: "Chandrasekhar",
                title: "Chat and composer inspection",
                prompt: "Inspect chat/composer UX",
                status: .closed,
                messages: [CodexChatMessage(role: .assistant, text: "Chat/composer findings", createdAt: now.addingTimeInterval(2))],
                createdAt: now,
                completedAt: now.addingTimeInterval(2)
            ),
            CodexSubagentState(
                name: "Copernicus",
                title: "Side panel inspection",
                prompt: "Inspect side panel UX",
                status: .closed,
                messages: [CodexChatMessage(role: .assistant, text: "Side-panel findings", createdAt: now.addingTimeInterval(3))],
                createdAt: now,
                completedAt: now.addingTimeInterval(3)
            )
        ]

        return AgentUIFixture(sideChat: sideChat, subagents: subagents)
    }
}
