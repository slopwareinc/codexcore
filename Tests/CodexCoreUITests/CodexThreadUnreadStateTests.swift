import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexThreadUnreadStateTests {
    @Test func initialSnapshotDoesNotInventUnreadState() {
        var state = CodexThreadUnreadState()

        state.apply(snapshot(status: .completed, revision: 1))

        #expect(!state.isUnread("thread"))
    }

    @Test func streamingAndUnrelatedAttentionRevisionsDoNotMarkUnread() {
        var state = CodexThreadUnreadState()
        state.apply(snapshot(status: .inProgress, revision: 1))

        state.apply(snapshot(status: .inProgress, revision: 2, attentionRevision: 99))

        #expect(!state.isUnread("thread"))
    }

    @Test func terminalTurnTransitionsMarkUnread() {
        for status in [
            CanonicalTurnStatus.completed,
            .interrupted,
            .failed,
        ] {
            var state = CodexThreadUnreadState()
            state.apply(snapshot(status: .inProgress, revision: 1))

            state.apply(snapshot(status: status, revision: 2))

            #expect(state.isUnread("thread"))
        }
    }

    @Test func newlyActionableRequestMarksUnreadWithoutTurnChange() {
        var state = CodexThreadUnreadState()
        state.apply(snapshot(status: .inProgress, revision: 1))

        state.apply(snapshot(status: .inProgress, revision: 2, hasPendingRequest: true))

        #expect(state.isUnread("thread"))
    }

    @Test func completedGoalContinuationDoesNotMarkUnread() {
        var state = CodexThreadUnreadState()
        state.apply(snapshot(status: .inProgress, revision: 1))

        state.apply(snapshot(status: .completed, revision: 2, isGoalAutoContinuing: true))

        #expect(!state.isUnread("thread"))
    }

    @Test func manualReadSurvivesUnrelatedLaterSnapshots() {
        var state = CodexThreadUnreadState()
        state.apply(snapshot(status: .inProgress, revision: 1))
        state.apply(snapshot(status: .completed, revision: 2))
        state.setUnread(false, for: "thread")

        state.apply(snapshot(status: .completed, revision: 3, attentionRevision: 100))

        #expect(!state.isUnread("thread"))
    }

    @Test func focusedConversationClearsUnreadButInactiveConversationDoesNot() {
        var state = CodexThreadUnreadState(unreadThreadIDs: ["thread"])

        state.markReadIfFocused("thread", isConversationFocused: false)
        #expect(state.isUnread("thread"))

        state.markReadIfFocused("thread", isConversationFocused: true)
        #expect(!state.isUnread("thread"))
    }

    @Test func reconnectSeedRetainsPersistedReadDecision() {
        var state = CodexThreadUnreadState()
        state.apply(snapshot(status: .inProgress, revision: 1))
        state.apply(snapshot(status: .completed, revision: 2))
        state.setUnread(false, for: "thread")

        state.resetObservationBaseline()
        state.apply(snapshot(status: .completed, revision: 3))

        #expect(!state.isUnread("thread"))
    }

    @Test func unreadStoragePersistsDedupedThreadIDs() {
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
        status: CanonicalTurnStatus,
        revision: UInt64,
        attentionRevision: UInt64? = nil,
        hasPendingRequest: Bool = false,
        isGoalAutoContinuing: Bool = false
    ) -> CanonicalThreadIndexSnapshot {
        CanonicalThreadIndexSnapshot(
            revision: StateRevision(revision),
            threads: [
                CanonicalThreadIndexSummary(
                    id: "thread",
                    order: 0,
                    status: status == .inProgress ? .active(flags: []) : .idle,
                    latestTurnID: "turn",
                    latestTurnStatus: status,
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
                    hasPendingServerRequest: hasPendingRequest,
                    hasPendingActionableRequest: hasPendingRequest,
                    isGoalAutoContinuing: isGoalAutoContinuing
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
