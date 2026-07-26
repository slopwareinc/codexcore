import Foundation

/// Lightweight sidebar/status projection for one canonical thread.
///
/// It intentionally contains no turns or items. `latestTurnStatus` preserves a
/// terminal failure after the thread itself returns to idle, while
/// `latestLiveAgentMessageRevision` lets UI-local read state react only to a
/// newly completed assistant message received during the current session.
public struct CanonicalThreadIndexSummary: Sendable, Equatable, Identifiable {
    public let id: ThreadID
    public let order: Int
    public let status: CanonicalThreadStatus
    public let latestTurnID: TurnID?
    public let latestTurnStatus: CanonicalTurnStatus?
    public let isArchived: Bool?
    public let isLoaded: Bool
    public let name: String?
    public let preview: String?
    public let cwd: CodexJSONValue?
    public let parentThreadID: ThreadID?
    public let agentNickname: String?
    public let agentRole: String?
    public let path: String?
    public let updatedAt: ProtocolSeconds?
    public let lastChangedRevision: StateRevision
    public let attentionRevision: StateRevision
    public let latestLiveAgentMessageRevision: StateRevision
    public let hasPendingServerRequest: Bool

    public init(
        id: ThreadID,
        order: Int,
        status: CanonicalThreadStatus,
        latestTurnID: TurnID?,
        latestTurnStatus: CanonicalTurnStatus?,
        isArchived: Bool?,
        isLoaded: Bool,
        name: String?,
        preview: String?,
        cwd: CodexJSONValue?,
        parentThreadID: ThreadID?,
        agentNickname: String?,
        agentRole: String?,
        path: String?,
        updatedAt: ProtocolSeconds?,
        lastChangedRevision: StateRevision,
        attentionRevision: StateRevision,
        latestLiveAgentMessageRevision: StateRevision = .zero,
        hasPendingServerRequest: Bool
    ) {
        self.id = id
        self.order = order
        self.status = status
        self.latestTurnID = latestTurnID
        self.latestTurnStatus = latestTurnStatus
        self.isArchived = isArchived
        self.isLoaded = isLoaded
        self.name = name
        self.preview = preview
        self.cwd = cwd
        self.parentThreadID = parentThreadID
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.path = path
        self.updatedAt = updatedAt
        self.lastChangedRevision = lastChangedRevision
        self.attentionRevision = attentionRevision
        self.latestLiveAgentMessageRevision = latestLiveAgentMessageRevision
        self.hasPendingServerRequest = hasPendingServerRequest
    }
}

/// Ordered thread catalogue captured at one canonical-state revision.
public struct CanonicalThreadIndexSnapshot: Sendable, Equatable {
    public let revision: StateRevision
    public let threads: [CanonicalThreadIndexSummary]

    public init(
        revision: StateRevision,
        threads: [CanonicalThreadIndexSummary]
    ) {
        self.revision = revision
        self.threads = threads
    }

    public var threadIDs: [ThreadID] {
        threads.map(\.id)
    }

    public func summary(for threadID: ThreadID) -> CanonicalThreadIndexSummary? {
        threads.first { $0.id == threadID }
    }

    static let attentionFields: StateFieldMask = [
        .threadStatus,
        .turnStructure,
        .turnStatus,
        .itemStructure,
        .itemLifecycle,
        .itemContent,
        .threadGoal,
        .plan,
        .diff,
        .requests,
        .submissionIntents,
        .moderation,
        .extensions,
        .diagnostics,
    ]

    /// Captures every field that can change sidebar identity, status, terminal
    /// failure, request badges, or UI-derived unread attention.
    public static let observationScope = StateObservationScope(
        entities: .all,
        fields: attentionFields.union(.threadMetadata)
    )
}

extension CanonicalStateGraph {
    func threadIndexSnapshot(
        attentionRevisions: [ThreadID: StateRevision],
        liveAgentMessageRevisions: [ThreadID: StateRevision] = [:],
        pendingRequestThreadIDs: Set<ThreadID>
    ) -> CanonicalThreadIndexSnapshot {
        var seen = Set<ThreadID>()
        var orderedIDs = threadOrder.filter { id in
            threads[id] != nil && seen.insert(id).inserted
        }
        orderedIDs.append(contentsOf: threads.keys.filter { seen.insert($0).inserted }.sorted())

        let summaries: [CanonicalThreadIndexSummary] = orderedIDs.enumerated().compactMap { pair in
            let (order, threadID) = pair
            guard let thread = threads[threadID] else { return nil }
            let latestTurnID = thread.turnOrder.last
            let latestTurn = latestTurnID.flatMap {
                turns[TurnKey(threadID: threadID, turnID: $0)]
            }
            let retainedLatestTurn = thread.retainedLatestTurn
            let projectedLatestTurnID = latestTurnID ?? retainedLatestTurn?.id
            let projectedLatestTurnStatus = latestTurn?.status
                ?? retainedLatestTurn.flatMap { summary in
                    summary.id == projectedLatestTurnID ? summary.status : nil
                }
            return CanonicalThreadIndexSummary(
                id: threadID,
                order: order,
                status: thread.status,
                latestTurnID: projectedLatestTurnID,
                latestTurnStatus: projectedLatestTurnStatus,
                isArchived: thread.isArchived,
                isLoaded: thread.isLoaded,
                name: thread.metadata.name,
                preview: thread.metadata.preview,
                cwd: thread.metadata.cwd,
                parentThreadID: thread.metadata.parentThreadID,
                agentNickname: thread.metadata.agentNickname,
                agentRole: thread.metadata.agentRole,
                path: thread.metadata.path,
                updatedAt: thread.metadata.updatedAt,
                lastChangedRevision: thread.lastChangedRevision,
                attentionRevision: attentionRevisions[threadID] ?? thread.lastChangedRevision,
                latestLiveAgentMessageRevision: liveAgentMessageRevisions[threadID] ?? .zero,
                hasPendingServerRequest: pendingRequestThreadIDs.contains(threadID)
            )
        }
        return CanonicalThreadIndexSnapshot(revision: revision, threads: summaries)
    }
}
