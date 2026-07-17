import Foundation

/// Presentation-safe metadata for one pending server-originated interaction.
///
/// The parsed request body and any future response value are deliberately not
/// retained here. `arrivalOrdinal` provides stable process-local ordering only;
/// it is not a protocol sequence or a state revision.
struct CodexPendingInteractionSnapshot: Sendable, Equatable {
    let key: CodexServerRequestKey
    let method: String
    let kind: CodexServerRequestKind
    let scope: CodexServerRequestScope
    let approvalCorrelation: CodexApprovalCorrelation?
    let arrivalOrdinal: UInt64
}

/// Sanitized prompt content derived from a pending parsed request.
struct CodexInteractionInboxEntry: Sendable, Equatable {
    let snapshot: CodexPendingInteractionSnapshot
    let body: CodexServerRequestInboxBody

    var key: CodexServerRequestKey { snapshot.key }
}

enum CodexInteractionRegistrationResult: Sendable, Equatable {
    case registered(CodexPendingInteractionSnapshot)
    case identicalDuplicate(CodexPendingInteractionSnapshot)
    case conflictingDuplicate(existing: CodexPendingInteractionSnapshot)
}

/// Synchronous pending-only state owned by the ordered `CodexSession` actor.
///
/// The inbox owns each parsed request exactly once. Metadata and presentation
/// entries are disposable projections. Taking an entry removes the sole stored
/// request, so response results remain one-shot values in the caller and cannot
/// leak into later snapshots.
struct CodexInteractionInbox: Sendable {
    private struct StoredInteraction: Sendable {
        let request: CodexParsedServerRequest
        let arrivalOrdinal: UInt64

        var snapshot: CodexPendingInteractionSnapshot {
            let registration = request.registration
            return CodexPendingInteractionSnapshot(
                key: registration.key,
                method: registration.method,
                kind: registration.kind,
                scope: registration.scope,
                approvalCorrelation: registration.approvalCorrelation,
                arrivalOrdinal: arrivalOrdinal
            )
        }
    }

    private var entries: [CodexServerRequestKey: StoredInteraction] = [:]
    private var nextArrivalOrdinal: UInt64 = 0

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    func parsedRequest(
        for key: CodexServerRequestKey
    ) -> CodexParsedServerRequest? {
        entries[key]?.request
    }

    func pendingSnapshots() -> [CodexPendingInteractionSnapshot] {
        orderedEntries().map(\.snapshot)
    }

    func inboxEntries() -> [CodexInteractionInboxEntry] {
        orderedEntries().map { stored in
            CodexInteractionInboxEntry(
                snapshot: stored.snapshot,
                body: CodexServerRequestInboxBody(
                    presentationBody: stored.request.body
                )
            )
        }
    }

    @discardableResult
    mutating func register(
        _ request: CodexParsedServerRequest
    ) -> CodexInteractionRegistrationResult {
        if let existing = entries[request.key] {
            return existing.request == request
                ? .identicalDuplicate(existing.snapshot)
                : .conflictingDuplicate(existing: existing.snapshot)
        }

        precondition(
            nextArrivalOrdinal < UInt64.max,
            "Interaction arrival ordinal space exhausted"
        )
        let stored = StoredInteraction(
            request: request,
            arrivalOrdinal: nextArrivalOrdinal
        )
        nextArrivalOrdinal += 1
        entries[request.key] = stored
        return .registered(stored.snapshot)
    }

    /// Removes and returns the exact request selected for a local reply.
    mutating func takeForLocalReply(
        _ key: CodexServerRequestKey
    ) -> CodexParsedServerRequest? {
        entries.removeValue(forKey: key)?.request
    }

    /// Removes and returns the exact request cleared by the server.
    /// Unknown or already-removed requests are benign no-ops.
    mutating func takeOnServerResolved(
        _ key: CodexServerRequestKey
    ) -> CodexParsedServerRequest? {
        entries.removeValue(forKey: key)?.request
    }

    /// Removes pending requests belonging to one sealed physical connection.
    /// Returned requests retain their stable arrival order for deterministic
    /// cleanup of handler tasks and thread retention.
    mutating func disconnect(
        connectionEpoch: UInt64
    ) -> [CodexParsedServerRequest] {
        let removed = orderedEntries().filter {
            $0.request.key.connectionEpoch == connectionEpoch
        }
        for entry in removed {
            entries.removeValue(forKey: entry.request.key)
        }
        return removed.map(\.request)
    }

    private func orderedEntries() -> [StoredInteraction] {
        entries.values.sorted {
            $0.arrivalOrdinal < $1.arrivalOrdinal
        }
    }
}
