import CodexCore
import Foundation

/// App-owned read state driven only by live completed assistant messages.
public struct CodexThreadUnreadState: Sendable, Equatable {
    public private(set) var unreadThreadIDs: Set<ThreadID>

    private var observedMessageRevisionByThreadID: [ThreadID: StateRevision] = [:]

    public init(unreadThreadIDs: Set<ThreadID> = []) {
        self.unreadThreadIDs = unreadThreadIDs
    }

    public func isUnread(_ threadID: ThreadID) -> Bool {
        unreadThreadIDs.contains(threadID)
    }

    /// Applies the latest lightweight thread index.
    ///
    /// Historical state has a zero live-message revision, so loading or
    /// hydrating existing threads never manufactures unread badges.
    @discardableResult
    public mutating func apply(_ snapshot: CanonicalThreadIndexSnapshot) -> Bool {
        let previousUnread = unreadThreadIDs
        var nextObserved: [ThreadID: StateRevision] = [:]
        nextObserved.reserveCapacity(snapshot.threads.count)

        for summary in snapshot.threads {
            let revision = summary.latestLiveAgentMessageRevision
            let observed = observedMessageRevisionByThreadID[summary.id] ?? .zero
            if revision > observed {
                unreadThreadIDs.insert(summary.id)
            }
            nextObserved[summary.id] = revision
        }

        observedMessageRevisionByThreadID = nextObserved
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

    public mutating func resetObservationBaseline() {
        observedMessageRevisionByThreadID.removeAll(keepingCapacity: true)
    }
}
