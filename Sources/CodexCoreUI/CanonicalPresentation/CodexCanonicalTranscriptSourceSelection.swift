import CodexCore
import Foundation

/// Canonical ordering and dirty-source selection for transcript projection.
///
/// This extension deliberately contains no row rendering. It decides which
/// turns and pending interactions belong in the next incremental projection.
extension CodexCanonicalTranscriptProjector {
    func unresolvedIntents(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID
    ) -> [SubmissionIntent] {
        snapshot.submissionIntents.values
            .filter { intent in
                guard intent.threadID == threadID else { return false }
                if case .reconciled = intent.state { return false }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.localOrdinal != rhs.localOrdinal {
                    return lhs.localOrdinal < rhs.localOrdinal
                }
                return lhs.id < rhs.id
            }
    }

    func intentsByTurn(
        _ intents: [SubmissionIntent]
    ) -> [TurnID: [SubmissionIntent]] {
        Dictionary(grouping: intents) { intent in
            intent.expectedTurnID ?? provisionalTurnID(intent.id)
        }
    }

    func echoedIntentIDs(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        checkpoint: () throws -> Void = {}
    ) rethrows -> Set<SubmissionIntentID> {
        var result: Set<SubmissionIntentID> = []
        for turnID in snapshot.threads[threadID]?.turnOrder ?? [] {
            try checkpoint()
            guard let turn = snapshot.turns[
                TurnKey(threadID: threadID, turnID: turnID)
            ] else { continue }
            for itemID in turn.itemOrder {
                try checkpoint()
                let key = ItemKey(
                    threadID: threadID,
                    turnID: turn.key.turnID,
                    itemID: itemID
                )
                guard let item = snapshot.items[key],
                      item.kind == .userMessage,
                      let intentID = item.clientUserMessageID
                else {
                    continue
                }
                result.insert(intentID)
            }
        }
        return result
    }

    func projectedTurnOrder(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        intents: [SubmissionIntent],
        checkpoint: () throws -> Void = {}
    ) rethrows -> [TurnID] {
        var result: [TurnID] = []
        var seen: Set<TurnID> = []
        if let thread = snapshot.threads[threadID] {
            let hasUnboundSubmission = intents.contains { $0.expectedTurnID == nil }
            for turnID in thread.turnOrder {
                try checkpoint()
                let key = TurnKey(threadID: threadID, turnID: turnID)
                guard let turn = snapshot.turns[key] else { continue }

                // `turn/started` can arrive before the first user-message item.
                // While the local submission intent is still unbound, rendering
                // that server turn first produces a transient Thinking row above
                // the optimistic user bubble. Keep the server placeholder out of
                // the order until its user item arrives; the intent already owns
                // the visible provisional turn during this handshake window.
                if hasUnboundSubmission,
                   !turn.status.isTerminal,
                   !containsUserMessage(turn, snapshot: snapshot) {
                    continue
                }
                if seen.insert(turnID).inserted {
                    result.append(turnID)
                }
            }
        }
        for intent in intents {
            try checkpoint()
            let turnID = intent.expectedTurnID ?? provisionalTurnID(intent.id)
            if seen.insert(turnID).inserted {
                result.append(turnID)
            }
        }
        return result
    }

    func containsUserMessage(
        _ turn: CanonicalTurn,
        snapshot: CanonicalStateSnapshot
    ) -> Bool {
        turn.itemOrder.contains { itemID in
            snapshot.items[ItemKey(
                threadID: turn.key.threadID,
                turnID: turn.key.turnID,
                itemID: itemID
            )]?.kind == .userMessage
        }
    }

    func provisionalTurnID(_ intentID: SubmissionIntentID) -> TurnID {
        TurnID("local-\(intentID.rawValue)")
    }

    func turnSourceRevisions(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        order: [TurnID],
        intentsByTurn: [TurnID: [SubmissionIntent]],
        recomputing dirtyTurnIDs: Set<TurnID>,
        previous: [TurnID: StateRevision],
        checkpoint: () throws -> Void = {}
    ) rethrows -> [TurnID: StateRevision] {
        var result: [TurnID: StateRevision] = [:]
        for turnID in order {
            try checkpoint()
            if !dirtyTurnIDs.contains(turnID),
               let previousRevision = previous[turnID] {
                result[turnID] = previousRevision
                continue
            }
            let turnKey = TurnKey(threadID: threadID, turnID: turnID)
            var revision = snapshot.turns[turnKey]?.lastChangedRevision ?? .zero
            if let turn = snapshot.turns[turnKey] {
                for itemID in turn.itemOrder {
                    try checkpoint()
                    let key = ItemKey(
                        threadID: threadID,
                        turnID: turnID,
                        itemID: itemID
                    )
                    if let itemRevision = snapshot.items[key]?.lastChangedRevision,
                       revision < itemRevision {
                        revision = itemRevision
                    }
                }
            }
            for intent in intentsByTurn[turnID] ?? [] {
                try checkpoint()
                if revision < intent.lastChangedRevision {
                    revision = intent.lastChangedRevision
                }
            }
            result[turnID] = revision
        }
        return result
    }

    func requestPresentations(
        _ requests: [CodexPendingInteractionSnapshot],
        threadID: ThreadID
    ) -> [CodexTranscriptRequestPresentation] {
        requests
            .filter { request in
                request.scope.threadID.map { ThreadID($0) } == threadID
            }
            .sorted { lhs, rhs in
                if lhs.arrivalOrdinal != rhs.arrivalOrdinal {
                    return lhs.arrivalOrdinal < rhs.arrivalOrdinal
                }
                if lhs.key.connectionEpoch != rhs.key.connectionEpoch {
                    return lhs.key.connectionEpoch < rhs.key.connectionEpoch
                }
                return lhs.key.requestID.description
                    < rhs.key.requestID.description
            }
            .map { request in
                CodexTranscriptRequestPresentation(
                    id: request.key,
                    kind: request.kind,
                    turnID: request.scope.turnID.map { TurnID($0) },
                    itemID: request.scope.itemID.map { ItemID($0) },
                    summary: requestSummary(request.kind)
                )
            }
    }

    func requestSummary(_ kind: CodexServerRequestKind) -> String {
        switch kind {
        case .commandApproval, .legacyExecCommandApproval: "Run command"
        case .fileChangeApproval, .legacyApplyPatchApproval: "Edit files"
        case .permissionsApproval: "Grant permissions"
        case .userInput: "Answer a question"
        case .mcpElicitation: "Respond to an app"
        case .dynamicToolCall: "Run a tool"
        case .tokenRefresh: "Refresh authentication"
        case .attestation: "Verify this device"
        case .currentTime: "Read current time"
        case .unknown: "Respond to Codex"
        }
    }

    func requestDirtyTurns(
        previous: [CodexTranscriptRequestPresentation],
        current: [CodexTranscriptRequestPresentation]
    ) -> Set<TurnID> {
        let previousByID = Dictionary(
            uniqueKeysWithValues: previous.map { ($0.id, $0) }
        )
        let currentByID = Dictionary(
            uniqueKeysWithValues: current.map { ($0.id, $0) }
        )
        let changedIDs = Set(previousByID.keys)
            .union(currentByID.keys)
            .filter { previousByID[$0] != currentByID[$0] }
        return Set(changedIDs.flatMap { id in
            [previousByID[id]?.turnID, currentByID[id]?.turnID]
                .compactMap { $0 }
        })
    }
}
