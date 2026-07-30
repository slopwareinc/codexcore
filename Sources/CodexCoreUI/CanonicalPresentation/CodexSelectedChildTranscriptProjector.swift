import CodexCore

struct CodexSelectedChildProjectionOutput: Sendable {
    var projection: CodexCanonicalTranscriptProjectionResult
    var upsertedTurnDisplayCosts: [TurnID: CodexSelectedTurnDisplayCost]
}

enum CodexSelectedTurnDisplayCostRecordingResult {
    case withinLimit
    case exceedsLimit
}

struct CodexSelectedTurnDisplayCostRecording {
    var limit: Int
    var sink: (TurnID, CodexSelectedTurnDisplayCost) -> Void

    func record(
        _ turnID: TurnID,
        projected: CodexTurnV2,
        items: [CanonicalItem],
        intents: [SubmissionIntent],
        checkpoint: () throws -> Void
    ) rethrows -> CodexSelectedTurnDisplayCostRecordingResult {
        let cost = try CodexSelectedTurnDisplayCostRecorder.measure(
            projected: projected,
            items: items,
            intents: intents,
            stoppingAfter: limit,
            checkpoint: checkpoint
        )
        sink(turnID, cost)
        return cost.exceedsLimit ? .exceedsLimit : .withinLimit
    }
}

extension CodexCanonicalTranscriptProjector {
    /// Selected-only projection seam. General transcript projection does not
    /// pay for cost recording and no accounting enters canonical state.
    func projectSelectedChild(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        previous: CodexCanonicalTranscriptPresentation?,
        excludingTurnIDs excludedTurnIDs: Set<TurnID> = [],
        displayCostLimit: Int
    ) throws -> CodexSelectedChildProjectionOutput {
        try Task.checkCancellation()
        if let previous,
           previous.threadID == threadID,
           snapshot.revision < previous.sourceRevision {
            throw CodexCanonicalTranscriptProjectionError.staleSourceRevision(
                previous: previous.sourceRevision,
                incoming: snapshot.revision
            )
        }

        var costs: [TurnID: CodexSelectedTurnDisplayCost] = [:]
        let costRecording = CodexSelectedTurnDisplayCostRecording(
            limit: displayCostLimit,
            sink: { costs[$0] = $1 }
        )
        let projection = try projectCore(
            snapshot: snapshot,
            threadID: threadID,
            previous: previous,
            excludedTurnIDs: excludedTurnIDs,
            selectedTurnCostRecording: costRecording,
            checkpoint: { try Task.checkCancellation() }
        )
        return .init(
            projection: projection,
            upsertedTurnDisplayCosts: costs
        )
    }
}
