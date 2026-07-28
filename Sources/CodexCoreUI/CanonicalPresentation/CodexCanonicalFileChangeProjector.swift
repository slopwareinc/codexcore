import CodexCore
import Foundation

/// The single canonical seam for one file-change item.
///
/// It owns lossless wire decoding, stable per-change identity, revision-based
/// reuse, and bounded render preparation. The general transcript grammar only
/// supplies item lifecycle state and duration.
struct CodexCanonicalFileChangeProjector: Sendable {
    private let diffPreparer: CodexFileChangeDiffPreparer

    init(diffPreparer: CodexFileChangeDiffPreparer = .init()) {
        self.diffPreparer = diffPreparer
    }

    func project(
        item: CanonicalItem,
        status: CodexWorkItemStatusV2,
        durationMs: Int?,
        previous: CodexFileChangeRowV2?
    ) -> CodexFileChangeRowV2 {
        let key = CodexFileChangePreparationKey(
            itemKey: item.key,
            sourceRevision: item.lastChangedRevision,
            contentFingerprint: 0
        )
        if let previous, previous.preparationKey == key {
            return CodexFileChangeRowV2(
                id: item.key.itemID.rawValue,
                changes: previous.changes,
                status: status,
                durationMs: durationMs,
                preparationKey: key,
                preparedFileChanges: previous.preparedFileChanges
            )
        }

        let changes = decodeChanges(
            item,
            previous: previous?.changes ?? []
        )
        return CodexFileChangeRowV2(
            id: item.key.itemID.rawValue,
            changes: changes,
            status: status,
            durationMs: durationMs,
            preparationKey: key,
            preparedFileChanges: diffPreparer.prepare(
                changes: changes,
                legacyDiff: nil
            )
        )
    }
}

private extension CodexCanonicalFileChangeProjector {
    struct Draft {
        var path: String
        var destinationPath: String?
        var kind: CodexFileChangeKindV2
        var diff: String
        var isMalformed: Bool
        var wireValue: CodexJSONValue
        var contentFingerprint: UInt64
    }

    struct StructuralIdentity: Hashable {
        var path: String
        var destinationPath: String?
        var kind: String
    }

    func decodeChanges(
        _ item: CanonicalItem,
        previous: [CodexFileChangeV2]
    ) -> [CodexFileChangeV2] {
        let rawChanges: [CodexJSONValue]
        if case .array(let liveChanges) = item.liveFields["fileChanges"] {
            rawChanges = liveChanges
        } else {
            rawChanges = item.payload.fileChangeArray("changes") ?? []
        }

        let drafts = rawChanges.compactMap(decodeChange)
        var exactOccurrences: [UInt64: Int] = [:]
        var changes = drafts.map { draft in
            let occurrence = exactOccurrences[draft.contentFingerprint, default: 0]
            exactOccurrences[draft.contentFingerprint] = occurrence + 1
            let suffix = occurrence == 0 ? "" : ":\(occurrence)"
            return CodexFileChangeV2(
                id: "\(item.key.itemID.rawValue):file:"
                    + "\(String(draft.contentFingerprint, radix: 16))\(suffix)",
                path: draft.path,
                destinationPath: draft.destinationPath,
                kind: draft.kind,
                diff: draft.diff,
                isMalformed: draft.isMalformed,
                wireValue: draft.isMalformed ? draft.wireValue : nil
            )
        }
        reconcileEvolvingIDs(&changes, previous: previous)
        return changes
    }

    /// Content-derived IDs make duplicate siblings deterministic across rebuilds
    /// and reordering. When an incremental projection can see the prior row,
    /// reconcile unmatched members of each structural group so ordinary live
    /// patch evolution does not churn identity merely because bytes changed.
    func reconcileEvolvingIDs(
        _ changes: inout [CodexFileChangeV2],
        previous: [CodexFileChangeV2]
    ) {
        guard !changes.isEmpty, !previous.isEmpty else { return }
        let priorByID = Dictionary(
            uniqueKeysWithValues: previous.map { ($0.id, $0) }
        )
        var usedPriorIDs: Set<String> = []
        for change in changes {
            guard let prior = priorByID[change.id],
                  structuralIdentity(change) == structuralIdentity(prior)
            else {
                continue
            }
            usedPriorIDs.insert(prior.id)
        }

        let unmatchedPrevious = Dictionary(
            grouping: previous.filter { !usedPriorIDs.contains($0.id) },
            by: structuralIdentity
        )
        let unmatchedCurrent = Dictionary(
            grouping: changes.indices.filter {
                !usedPriorIDs.contains(changes[$0].id)
            },
            by: { structuralIdentity(changes[$0]) }
        )
        for (identity, indices) in unmatchedCurrent {
            guard let candidates = unmatchedPrevious[identity] else { continue }
            for (index, prior) in zip(indices, candidates) {
                changes[index].id = prior.id
            }
        }
    }

    func structuralIdentity(
        _ change: CodexFileChangeV2
    ) -> StructuralIdentity {
        .init(
            path: change.path,
            destinationPath: change.destinationPath,
            kind: change.kind.stableValue
        )
    }

    func decodeChange(_ rawChange: CodexJSONValue) -> Draft? {
        guard let change = rawChange.fileChangeObject,
              let path = change.fileChangeString("path"),
              !path.isEmpty
        else {
            return nil
        }

        let kindPayload = change.fileChangeObject("kind")
        let rawKind = kindPayload?.fileChangeString("type")
            ?? change.fileChangeString("kind")
        let destinationPath = kindPayload?.fileChangeString("move_path")
            ?? kindPayload?.fileChangeString("movePath")
        let kindValue = change["kind"]
        let kindIsMalformed: Bool = {
            guard let kindValue else { return true }
            if kindValue.fileChangeStringValue != nil { return false }
            guard let object = kindValue.fileChangeObject else { return true }
            return object.fileChangeString("type") == nil
        }()
        let movePathIsMalformed: Bool = {
            guard let kindPayload else { return false }
            for key in ["move_path", "movePath"] {
                guard let value = kindPayload[key] else { continue }
                if value != .null, value.fileChangeStringValue == nil {
                    return true
                }
            }
            return false
        }()
        let kind: CodexFileChangeKindV2 = switch rawKind {
        case "add": .added
        case "delete": .deleted
        case "update" where destinationPath != nil: .renamed
        case "update": .modified
        case .some(let value): .unknown(value)
        case nil: .unknown("unknown")
        }
        let diff = change.fileChangeString("diff") ?? ""
        let diffIsMalformed = change["diff"]?.fileChangeStringValue == nil

        var contentHasher = CodexStableFingerprint()
        contentHasher.combine(path)
        contentHasher.combine(destinationPath ?? "")
        contentHasher.combine(kind.stableValue)
        contentHasher.combine(diff)
        return Draft(
            path: path,
            destinationPath: destinationPath,
            kind: kind,
            diff: diff,
            isMalformed: kindIsMalformed || movePathIsMalformed || diffIsMalformed,
            wireValue: rawChange,
            contentFingerprint: contentHasher.value
        )
    }
}

private extension CodexJSONValue {
    var fileChangeObject: [String: CodexJSONValue]? {
        if case .dictionary(let value) = self { value } else { nil }
    }

    var fileChangeStringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }
}

private extension Dictionary where Key == String, Value == CodexJSONValue {
    func fileChangeString(_ key: String) -> String? {
        self[key]?.fileChangeStringValue
    }

    func fileChangeObject(_ key: String) -> [String: CodexJSONValue]? {
        self[key]?.fileChangeObject
    }

    func fileChangeArray(_ key: String) -> [CodexJSONValue]? {
        if case .array(let value) = self[key] { value } else { nil }
    }
}
