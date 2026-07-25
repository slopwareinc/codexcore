import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexThreadUnreadStateTests {
    @Test func historicalAndUnrelatedStateNeverInventUnread() {
        var state = CodexThreadUnreadState()

        state.apply(snapshot(revision: 1, liveMessageRevision: 0, attentionRevision: 50))
        state.apply(snapshot(revision: 2, liveMessageRevision: 0, attentionRevision: 100))

        #expect(!state.isUnread("thread"))
    }

    @Test func newlyCompletedLiveAssistantMessageMarksUnread() {
        var state = CodexThreadUnreadState()
        state.apply(snapshot(revision: 1, liveMessageRevision: 0))

        state.apply(snapshot(revision: 2, liveMessageRevision: 2))

        #expect(state.isUnread("thread"))
    }

    @Test func readDecisionSurvivesLaterToolAndStatusChanges() {
        var state = CodexThreadUnreadState()
        state.apply(snapshot(revision: 1, liveMessageRevision: 0))
        state.apply(snapshot(revision: 2, liveMessageRevision: 2))
        state.setUnread(false, for: "thread")

        state.apply(snapshot(revision: 3, liveMessageRevision: 2, attentionRevision: 99))

        #expect(!state.isUnread("thread"))
    }

    @Test func aLaterAssistantMessageMarksTheThreadUnreadAgain() {
        var state = CodexThreadUnreadState()
        state.apply(snapshot(revision: 1, liveMessageRevision: 2))
        state.setUnread(false, for: "thread")

        state.apply(snapshot(revision: 2, liveMessageRevision: 4))

        #expect(state.isUnread("thread"))
    }

    @Test func focusedConversationClearsUnread() {
        var state = CodexThreadUnreadState(unreadThreadIDs: ["thread"])

        state.markReadIfFocused("thread", isConversationFocused: false)
        #expect(state.isUnread("thread"))

        state.markReadIfFocused("thread", isConversationFocused: true)
        #expect(!state.isUnread("thread"))
    }

    @Test func unreadStoragePersistsOnlyExplicitMessageUnreadIDs() {
        let store = UnreadPreferenceStore()

        CodexUnreadThreadStorage.saveUnreadThreadIDs(
            ["thread-b", "thread-a", "thread-a"],
            to: store
        )

        #expect(
            CodexUnreadThreadStorage.loadUnreadThreadIDs(from: store)
                == ["thread-a", "thread-b"]
        )
    }

    private func snapshot(
        revision: UInt64,
        liveMessageRevision: UInt64,
        attentionRevision: UInt64? = nil
    ) -> CanonicalThreadIndexSnapshot {
        CanonicalThreadIndexSnapshot(
            revision: StateRevision(revision),
            threads: [
                CanonicalThreadIndexSummary(
                    id: "thread",
                    order: 0,
                    status: .idle,
                    latestTurnID: "turn",
                    latestTurnStatus: .completed,
                    isArchived: false,
                    isLoaded: true,
                    name: nil,
                    preview: nil,
                    cwd: nil,
                    parentThreadID: nil,
                    agentNickname: nil,
                    agentRole: nil,
                    path: nil,
                    updatedAt: ProtocolSeconds(Int64(revision)),
                    lastChangedRevision: StateRevision(revision),
                    attentionRevision: StateRevision(attentionRevision ?? revision),
                    latestLiveAgentMessageRevision: StateRevision(liveMessageRevision),
                    hasPendingServerRequest: false
                )
            ]
        )
    }
}

private final class UnreadPreferenceStore:
    CodexStringListPreferenceStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: [String]] = [:]

    func loadStrings(forKey key: String) -> [String] {
        lock.withLock { values[key] ?? [] }
    }

    func saveStrings(_ strings: [String], forKey key: String) {
        lock.withLock { values[key] = strings }
    }

    func hasStrings(forKey key: String) -> Bool {
        lock.withLock { values[key] != nil }
    }
}
