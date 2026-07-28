import CodexCore
import Foundation

/// A disposable transcript presentation derived from one canonical state
/// revision. It contains no protocol mutation logic and can be rebuilt at any
/// time from `CanonicalStateSnapshot`.
public struct CodexCanonicalTranscriptPresentation: Sendable, Equatable {
    public var threadID: ThreadID
    public var sourceRevision: StateRevision
    public var requestSourceRevision: UInt64
    public var turnOrder: [TurnID]
    public var turnsByID: [TurnID: CodexTurnV2]
    public var sourceTurnRevisions: [TurnID: StateRevision]
    public var pendingRequests: [CodexTranscriptRequestPresentation]

    public init(
        threadID: ThreadID,
        sourceRevision: StateRevision,
        requestSourceRevision: UInt64 = 0,
        turnOrder: [TurnID] = [],
        turnsByID: [TurnID: CodexTurnV2] = [:],
        sourceTurnRevisions: [TurnID: StateRevision] = [:],
        pendingRequests: [CodexTranscriptRequestPresentation] = []
    ) {
        self.threadID = threadID
        self.sourceRevision = sourceRevision
        self.requestSourceRevision = requestSourceRevision
        self.turnOrder = turnOrder
        self.turnsByID = turnsByID
        self.sourceTurnRevisions = sourceTurnRevisions
        self.pendingRequests = pendingRequests
    }

    public var transcript: CodexTranscriptV2 {
        CodexTranscriptV2(turns: turnOrder.compactMap { turnsByID[$0] })
    }

    /// Retained UTF-8 bytes used by prepared file-change presentation data.
    ///
    /// Exact canonical patches remain owned by their rows. This measures only
    /// the disposable, bounded render preparation duplicated by warm caches.
    public var retainedPreparedUTF8ByteCount: Int {
        var total = 0
        for turnID in turnOrder {
            guard let turn = turnsByID[turnID] else { continue }
            for entry in turn.narrative {
                guard case .workGroup(let group) = entry else { continue }
                for row in group.rows {
                    guard case .fileChange(let fileChange) = row else { continue }
                    let (sum, overflow) = total.addingReportingOverflow(
                        fileChange.retainedPreparedUTF8ByteCount
                    )
                    total = overflow ? .max : sum
                }
            }
        }
        return total
    }
}

/// Continuation-free request presentation. The pending interaction inbox is
/// the source of truth; this value only supplies stable placement and copy to
/// the transcript renderer.
public struct CodexTranscriptRequestPresentation: Identifiable, Sendable, Equatable {
    public var id: CodexServerRequestKey
    public var kind: CodexServerRequestKind
    public var turnID: TurnID?
    public var itemID: ItemID?
    public var summary: String

    public init(
        id: CodexServerRequestKey,
        kind: CodexServerRequestKind,
        turnID: TurnID? = nil,
        itemID: ItemID? = nil,
        summary: String
    ) {
        self.id = id
        self.kind = kind
        self.turnID = turnID
        self.itemID = itemID
        self.summary = summary
    }
}

/// The smallest update the presentation store needs to apply after a canonical
/// state change. `turnOrder` is nil when structure did not change.
public struct CodexCanonicalTranscriptRenderUpdate: Sendable, Equatable {
    public var threadID: ThreadID
    public var sourceRevision: StateRevision
    public var requestSourceRevision: UInt64
    public var turnOrder: [TurnID]?
    public var upsertedTurns: [CodexTurnV2]
    public var removedTurnIDs: Set<TurnID>
    public var dirtyTurnIDs: Set<TurnID>
    public var pendingRequests: [CodexTranscriptRequestPresentation]
    public var isFullRebuild: Bool

    public init(
        threadID: ThreadID,
        sourceRevision: StateRevision,
        requestSourceRevision: UInt64,
        turnOrder: [TurnID]?,
        upsertedTurns: [CodexTurnV2],
        removedTurnIDs: Set<TurnID>,
        dirtyTurnIDs: Set<TurnID>,
        pendingRequests: [CodexTranscriptRequestPresentation],
        isFullRebuild: Bool
    ) {
        self.threadID = threadID
        self.sourceRevision = sourceRevision
        self.requestSourceRevision = requestSourceRevision
        self.turnOrder = turnOrder
        self.upsertedTurns = upsertedTurns
        self.removedTurnIDs = removedTurnIDs
        self.dirtyTurnIDs = dirtyTurnIDs
        self.pendingRequests = pendingRequests
        self.isFullRebuild = isFullRebuild
    }
}

public struct CodexCanonicalTranscriptProjectionResult: Sendable, Equatable {
    public var presentation: CodexCanonicalTranscriptPresentation
    public var update: CodexCanonicalTranscriptRenderUpdate

    public init(
        presentation: CodexCanonicalTranscriptPresentation,
        update: CodexCanonicalTranscriptRenderUpdate
    ) {
        self.presentation = presentation
        self.update = update
    }
}

public enum CodexCanonicalTranscriptProjectionError: Error, Sendable, Equatable {
    case staleSourceRevision(previous: StateRevision, incoming: StateRevision)
    case staleRequestRevision(previous: UInt64, incoming: UInt64)
}
