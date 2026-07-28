import CodexCore

public extension CodexCanonicalTranscriptProjector {
    /// Rebuilds without observing ambient task cancellation.
    ///
    /// This public synchronous API always returns a complete disposable
    /// presentation. Async owners that need cancellation should call `project`
    /// with a nil previous presentation instead.
    func rebuild(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        requests: [CodexPendingInteractionSnapshot] = [],
        requestRevision: UInt64 = 0
    ) -> CodexCanonicalTranscriptProjectionResult {
        projectCore(
            snapshot: snapshot,
            threadID: threadID,
            requests: requests,
            requestRevision: requestRevision,
            previous: nil,
            checkpoint: {}
        )
    }

    /// Projects incrementally and cooperatively stops when its task is canceled.
    func project(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        requests: [CodexPendingInteractionSnapshot] = [],
        requestRevision: UInt64 = 0,
        previous: CodexCanonicalTranscriptPresentation?
    ) throws -> CodexCanonicalTranscriptProjectionResult {
        try Task.checkCancellation()
        if let previous,
           previous.threadID == threadID,
           snapshot.revision < previous.sourceRevision {
            throw CodexCanonicalTranscriptProjectionError.staleSourceRevision(
                previous: previous.sourceRevision,
                incoming: snapshot.revision
            )
        }
        if let previous,
           previous.threadID == threadID,
           requestRevision < previous.requestSourceRevision {
            throw CodexCanonicalTranscriptProjectionError.staleRequestRevision(
                previous: previous.requestSourceRevision,
                incoming: requestRevision
            )
        }
        return try projectCore(
            snapshot: snapshot,
            threadID: threadID,
            requests: requests,
            requestRevision: requestRevision,
            previous: previous,
            checkpoint: { try Task.checkCancellation() }
        )
    }
}
