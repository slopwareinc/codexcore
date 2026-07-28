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
        previous: CodexFileChangeRowV2?,
        checkpoint: () throws -> Void = {}
    ) rethrows -> CodexFileChangeRowV2 {
        try checkpoint()
        if var previous,
           previous.canonicalSourceRevision == item.lastChangedRevision {
            previous.status = status
            previous.durationMs = durationMs
            try checkpoint()
            return previous
        }

        let changes = try decodeChanges(
            item,
            previous: previous?.changes ?? [],
            checkpoint: checkpoint
        )
        let prepared = try diffPreparer.prepare(
            changes: changes,
            legacyDiff: nil,
            checkpoint: checkpoint
        )
        try checkpoint()
        return .init(
            id: item.key.itemID.rawValue,
            sourceRevision: item.lastChangedRevision,
            changes: changes,
            status: status,
            durationMs: durationMs,
            preparedFileChanges: prepared
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
        var wireFingerprint: UInt64
        var contentFingerprint: UInt64
    }

    struct StructuralIdentity: Hashable {
        var path: String
        var destinationPath: String?
        var kind: String
    }

    enum WireFingerprintFrame {
        case value(CodexJSONValue)
        case array([CodexJSONValue], Int)
        case dictionary([(String, CodexJSONValue)], Int)
    }

    func decodeChanges(
        _ item: CanonicalItem,
        previous: [CodexFileChangeV2],
        checkpoint: () throws -> Void
    ) rethrows -> [CodexFileChangeV2] {
        let rawChanges: [CodexJSONValue]
        if case .array(let liveChanges) = item.liveFields["fileChanges"] {
            rawChanges = liveChanges
        } else {
            rawChanges = item.payload.fileChangeArray("changes") ?? []
        }

        var drafts: [Draft] = []
        drafts.reserveCapacity(rawChanges.count)
        for rawChange in rawChanges {
            try checkpoint()
            if let draft = try decodeChange(
                rawChange,
                checkpoint: checkpoint
            ) {
                drafts.append(draft)
            }
        }
        var exactOccurrences: [UInt64: Int] = [:]
        var changes: [CodexFileChangeV2] = []
        changes.reserveCapacity(drafts.count)
        for draft in drafts {
            try checkpoint()
            let occurrence = exactOccurrences[draft.contentFingerprint, default: 0]
            exactOccurrences[draft.contentFingerprint] = occurrence + 1
            let suffix = occurrence == 0 ? "" : ":\(occurrence)"
            changes.append(CodexFileChangeV2(
                id: "\(item.key.itemID.rawValue):file:"
                    + "\(String(draft.contentFingerprint, radix: 16))\(suffix)",
                path: draft.path,
                destinationPath: draft.destinationPath,
                kind: draft.kind,
                diff: draft.diff,
                isMalformed: draft.isMalformed,
                wireValue: draft.isMalformed ? draft.wireValue : nil,
                wireFingerprint: draft.wireFingerprint
            ))
        }
        try reconcileEvolvingIDs(
            &changes,
            previous: previous,
            checkpoint: checkpoint
        )
        return changes
    }

    /// Content-derived IDs make duplicate siblings deterministic across rebuilds
    /// and reordering. When an incremental projection can see the prior row,
    /// reconcile unmatched members of each structural group so ordinary live
    /// patch evolution does not churn identity merely because bytes changed.
    func reconcileEvolvingIDs(
        _ changes: inout [CodexFileChangeV2],
        previous: [CodexFileChangeV2],
        checkpoint: () throws -> Void
    ) rethrows {
        guard !changes.isEmpty, !previous.isEmpty else { return }
        var priorByID: [String: CodexFileChangeV2] = [:]
        priorByID.reserveCapacity(previous.count)
        for prior in previous {
            try checkpoint()
            priorByID[prior.id] = prior
        }
        var usedPriorIDs: Set<String> = []
        for change in changes {
            try checkpoint()
            guard let prior = priorByID[change.id],
                  structuralIdentity(change) == structuralIdentity(prior)
            else {
                continue
            }
            usedPriorIDs.insert(prior.id)
        }

        var unmatchedPrevious: [StructuralIdentity: [CodexFileChangeV2]] = [:]
        for prior in previous where !usedPriorIDs.contains(prior.id) {
            try checkpoint()
            unmatchedPrevious[structuralIdentity(prior), default: []].append(prior)
        }
        var unmatchedCurrent: [StructuralIdentity: [Int]] = [:]
        for index in changes.indices where !usedPriorIDs.contains(changes[index].id) {
            try checkpoint()
            unmatchedCurrent[structuralIdentity(changes[index]), default: []]
                .append(index)
        }
        for (identity, indices) in unmatchedCurrent {
            try checkpoint()
            guard let candidates = unmatchedPrevious[identity] else { continue }
            for (index, prior) in zip(indices, candidates) {
                try checkpoint()
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

    func decodeChange(
        _ rawChange: CodexJSONValue,
        checkpoint: () throws -> Void
    ) rethrows -> Draft? {
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
        let isMalformed = kindIsMalformed
            || movePathIsMalformed
            || diffIsMalformed

        var contentHasher = CodexStableFingerprint()
        try contentHasher.combine(path, checkpoint: checkpoint)
        try contentHasher.combine(
            destinationPath ?? "",
            checkpoint: checkpoint
        )
        try contentHasher.combine(kind.stableValue, checkpoint: checkpoint)
        try contentHasher.combine(diff, checkpoint: checkpoint)
        let wireFingerprint = isMalformed
            ? try malformedWireFingerprint(
                change,
                checkpoint: checkpoint
            )
            : 0
        return Draft(
            path: path,
            destinationPath: destinationPath,
            kind: kind,
            diff: diff,
            isMalformed: isMalformed,
            wireValue: rawChange,
            wireFingerprint: wireFingerprint,
            contentFingerprint: contentHasher.value
        )
    }

    /// Hashes only malformed/unknown wire structure. A valid string `diff` is
    /// excluded because the parser fingerprint already covers those bytes.
    func malformedWireFingerprint(
        _ change: [String: CodexJSONValue],
        checkpoint: () throws -> Void
    ) rethrows -> UInt64 {
        var hasher = CodexStableFingerprint()
        hasher.combine("malformed-wire")
        for key in change.keys.sorted() {
            try checkpoint()
            guard key != "path", let value = change[key] else {
                continue
            }
            hasher.combine(key)
            if key == "diff", value.fileChangeStringValue != nil {
                hasher.combine("normalized-string")
                continue
            }
            try combineWireValue(
                value,
                into: &hasher,
                checkpoint: checkpoint
            )
        }
        return hasher.value
    }

    func combineWireValue(
        _ value: CodexJSONValue,
        into hasher: inout CodexStableFingerprint,
        checkpoint: () throws -> Void
    ) rethrows {
        var stack: [WireFingerprintFrame] = [.value(value)]
        while let frame = stack.popLast() {
            try checkpoint()
            switch frame {
            case .value(.string(let string)):
                hasher.combine("string")
                try hasher.combine(string, checkpoint: checkpoint)
            case .value(.int(let integer)):
                hasher.combine("int")
                hasher.combine(UInt64(bitPattern: Int64(integer)))
            case .value(.double(let double)):
                hasher.combine("double")
                hasher.combine(double.bitPattern)
            case .value(.bool(let bool)):
                hasher.combine(bool ? "true" : "false")
            case .value(.array(let values)):
                hasher.combine("array")
                hasher.combine(UInt64(values.count))
                stack.append(.array(values, 0))
            case .value(.dictionary(let dictionary)):
                hasher.combine("dictionary")
                hasher.combine(UInt64(dictionary.count))
                stack.append(.dictionary(
                    dictionary.sorted { $0.key < $1.key },
                    0
                ))
            case .value(.null):
                hasher.combine("null")
            case .array(let values, let index):
                guard values.indices.contains(index) else { continue }
                stack.append(.array(values, index + 1))
                stack.append(.value(values[index]))
            case .dictionary(let entries, let index):
                guard entries.indices.contains(index) else { continue }
                stack.append(.dictionary(entries, index + 1))
                hasher.combine(entries[index].0)
                stack.append(.value(entries[index].1))
            }
        }
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
