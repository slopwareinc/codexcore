import CodexCore
import Foundation

/// App-owned read state for local Codex threads.
///
/// The app-server supplies turn and request lifecycle facts, but does not own
/// whether the user has read them. This state intentionally ignores streaming
/// content revisions and marks a thread unread only for a new terminal turn or
    /// a newly actionable request.
public struct CodexThreadUnreadState: Sendable, Equatable {
    public private(set) var unreadThreadIDs: Set<ThreadID>

    private var observationByThreadID: [ThreadID: Observation] = [:]
    private var hasObservationBaseline = false

    public init(unreadThreadIDs: Set<ThreadID> = []) {
        self.unreadThreadIDs = unreadThreadIDs
    }

    public func isUnread(_ threadID: ThreadID) -> Bool {
        unreadThreadIDs.contains(threadID)
    }

    /// Applies one canonical thread-index snapshot.
    ///
    /// The first snapshot establishes a baseline without making historical
    /// completed turns unread. Persisted unread IDs remain authoritative.
    @discardableResult
    public mutating func apply(_ snapshot: CanonicalThreadIndexSnapshot) -> Bool {
        let nextObservations = Dictionary(
            uniqueKeysWithValues: snapshot.threads.map { summary in
                (summary.id, Observation(summary: summary))
            }
        )
        guard hasObservationBaseline else {
            observationByThreadID = nextObservations
            hasObservationBaseline = true
            return false
        }

        let previousUnread = unreadThreadIDs
        for summary in snapshot.threads {
            let next = Observation(summary: summary)
            let previous = observationByThreadID[summary.id]
            if next.becameActionable(comparedWith: previous)
                || next.completedTurn(comparedWith: previous)
            {
                unreadThreadIDs.insert(summary.id)
            }
        }
        observationByThreadID = nextObservations
        return unreadThreadIDs != previousUnread
    }

    @discardableResult
    public mutating func setUnread(_ unread: Bool, for threadID: ThreadID) -> Bool {
        if unread {
            return unreadThreadIDs.insert(threadID).inserted
        }
        return unreadThreadIDs.remove(threadID) != nil
    }

    @discardableResult
    public mutating func markReadIfFocused(
        _ threadID: ThreadID?,
        isConversationFocused: Bool
    ) -> Bool {
        guard isConversationFocused, let threadID else { return false }
        return setUnread(false, for: threadID)
    }

    @discardableResult
    public mutating func replaceUnreadThreadIDs(_ ids: Set<ThreadID>) -> Bool {
        guard ids != unreadThreadIDs else { return false }
        unreadThreadIDs = ids
        return true
    }

    @discardableResult
    public mutating func removeThread(_ threadID: ThreadID) -> Bool {
        observationByThreadID.removeValue(forKey: threadID)
        return unreadThreadIDs.remove(threadID) != nil
    }

    /// Retains persisted read state while preventing a reconnect seed from
    /// being mistaken for fresh activity.
    public mutating func resetObservationBaseline() {
        observationByThreadID.removeAll(keepingCapacity: true)
        hasObservationBaseline = false
    }

    private struct Observation: Sendable, Equatable {
        let latestTurnID: TurnID?
        let latestTurnStatus: CanonicalTurnStatus?
        let hasPendingActionableRequest: Bool
        let isGoalAutoContinuing: Bool

        init(summary: CanonicalThreadIndexSummary) {
            latestTurnID = summary.latestTurnID
            latestTurnStatus = summary.latestTurnStatus
            hasPendingActionableRequest = summary.hasPendingActionableRequest
            isGoalAutoContinuing = summary.isGoalAutoContinuing
        }

        func becameActionable(comparedWith previous: Self?) -> Bool {
            hasPendingActionableRequest && previous?.hasPendingActionableRequest != true
        }

        func completedTurn(comparedWith previous: Self?) -> Bool {
            guard latestTurnStatus.isUnreadTerminal else { return false }
            guard latestTurnStatus != .completed || !isGoalAutoContinuing else { return false }
            guard let previous else { return true }
            return previous.latestTurnID != latestTurnID
                || previous.latestTurnStatus != latestTurnStatus
        }
    }
}

private extension Optional where Wrapped == CanonicalTurnStatus {
    var isUnreadTerminal: Bool {
        switch self {
        case .completed, .interrupted, .failed:
            true
        case .inProgress, .unknown, .none:
            false
        }
    }
}
