import CodexCore
import Foundation

extension CodexCanonicalTranscriptPresentation {
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

    /// A conservative logical-size estimate for the complete disposable
    /// projection.
    ///
    /// Swift does not expose the allocated capacity or sharing state of its
    /// copy-on-write collections, so this is intentionally not described as an
    /// exact heap measurement. It includes every retained UTF-8 payload, the
    /// bounded prepared diff payload, and deterministic collection/value
    /// overhead. Cache limits use this inclusive estimate rather than treating
    /// raw patches and non-diff transcript content as free.
    public var estimatedRetainedByteCount: Int {
        retentionMetrics().estimatedRetainedByteCount
    }
}

extension CodexCanonicalTranscriptPresentation {
    func retentionMetrics(
        previous: CodexCanonicalTranscriptRetentionMetrics? = nil,
        update: CodexCanonicalTranscriptRenderUpdate? = nil
    ) -> CodexCanonicalTranscriptRetentionMetrics {
        CodexCanonicalTranscriptRetentionMetrics.updating(
            presentation: self,
            previous: previous,
            update: update
        )
    }
}

/// Incremental conservative footprint for high-frequency child projections.
///
/// Only dirty/upserted turns are remeasured. Stable turn payloads retain their
/// prior weights, preventing byte-budget enforcement from turning incremental
/// projection back into a full-history traversal.
struct CodexCanonicalTranscriptRetentionMetrics: Sendable {
    var threadID: ThreadID
    var sourceRevision: StateRevision
    var turnBytesByID: [TurnID: Int]
    var turnByteCount: Int
    var requestByteCount: Int
    var structuralByteCount: Int
    var requestSourceRevision: UInt64
    var estimatedRetainedByteCount: Int

    static func updating(
        presentation: CodexCanonicalTranscriptPresentation,
        previous: Self?,
        update: CodexCanonicalTranscriptRenderUpdate?
    ) -> Self {
        guard let previous,
              let update,
              !update.isFullRebuild,
              previous.threadID == presentation.threadID,
              previous.sourceRevision <= presentation.sourceRevision,
              update.threadID == presentation.threadID,
              update.sourceRevision == presentation.sourceRevision,
              update.requestSourceRevision == presentation.requestSourceRevision
        else {
            return full(presentation)
        }

        var turnBytes = previous.turnBytesByID
        var turnTotal = previous.turnByteCount
        for turnID in update.removedTurnIDs {
            subtract(turnBytes.removeValue(forKey: turnID), from: &turnTotal)
        }

        let upsertedIDs = Set(update.upsertedTurns.map { TurnID($0.id) })
        for turn in update.upsertedTurns {
            let turnID = TurnID(turn.id)
            subtract(turnBytes[turnID], from: &turnTotal)
            let bytes = turn.estimatedRetainedByteCount
            turnBytes[turnID] = bytes
            add(bytes, to: &turnTotal)
        }
        for turnID in update.dirtyTurnIDs
        where !upsertedIDs.contains(turnID) && presentation.turnsByID[turnID] == nil {
            subtract(turnBytes.removeValue(forKey: turnID), from: &turnTotal)
        }
        if turnTotal == .max {
            turnTotal = 0
            for bytes in turnBytes.values { add(bytes, to: &turnTotal) }
        }

        let requestsChanged =
            presentation.requestSourceRevision != previous.requestSourceRevision
        let requestBytes = requestsChanged
            ? requestByteCount(presentation.pendingRequests)
            : previous.requestByteCount
        let turnStructureChanged =
            update.turnOrder != nil
            || turnBytes.count != previous.turnBytesByID.count
        let structuralBytes = turnStructureChanged || requestsChanged
            ? structuralByteCount(presentation)
            : previous.structuralByteCount
        return .init(
            threadID: presentation.threadID,
            sourceRevision: presentation.sourceRevision,
            turnBytesByID: turnBytes,
            turnByteCount: turnTotal,
            requestByteCount: requestBytes,
            structuralByteCount: structuralBytes,
            requestSourceRevision: presentation.requestSourceRevision,
            estimatedRetainedByteCount: saturatedSum(
                structuralBytes,
                turnTotal,
                requestBytes
            )
        )
    }

    private static func full(
        _ presentation: CodexCanonicalTranscriptPresentation
    ) -> Self {
        var turnBytes: [TurnID: Int] = [:]
        turnBytes.reserveCapacity(presentation.turnsByID.count)
        var turnTotal = 0
        for (turnID, turn) in presentation.turnsByID {
            let bytes = turn.estimatedRetainedByteCount
            turnBytes[turnID] = bytes
            add(bytes, to: &turnTotal)
        }
        let requestBytes = requestByteCount(presentation.pendingRequests)
        let structuralBytes = structuralByteCount(presentation)
        return .init(
            threadID: presentation.threadID,
            sourceRevision: presentation.sourceRevision,
            turnBytesByID: turnBytes,
            turnByteCount: turnTotal,
            requestByteCount: requestBytes,
            structuralByteCount: structuralBytes,
            requestSourceRevision: presentation.requestSourceRevision,
            estimatedRetainedByteCount: saturatedSum(
                structuralBytes,
                turnTotal,
                requestBytes
            )
        )
    }

    /// Includes the auxiliary incremental-metrics dictionary and the ordered
    /// transcript array retained by `CodexSubagentV2`. Nested turn payloads are
    /// shared copy-on-write with the canonical presentation and are therefore
    /// charged only once by `estimatedRetainedByteCount`.
    func estimatedProjectionByteCount(transcriptTurnCount: Int) -> Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        estimate.add(estimatedRetainedByteCount)

        estimate.addCollectionAllocation(count: turnBytesByID.count)
        estimate.addProduct(
            turnBytesByID.count,
            MemoryLayout<TurnID>.stride + MemoryLayout<Int>.stride
        )
        estimate.addStringValues(turnBytesByID.keys.lazy.map(\.rawValue))

        estimate.add(MemoryLayout<CodexTranscriptV2>.stride)
        estimate.addCollectionAllocation(count: transcriptTurnCount)
        estimate.addProduct(
            transcriptTurnCount,
            MemoryLayout<CodexTurnV2>.stride
        )
        return estimate.total
    }

    private static func structuralByteCount(
        _ presentation: CodexCanonicalTranscriptPresentation
    ) -> Int {
        var estimate = CodexPresentationRetentionEstimate(
            CodexCanonicalTranscriptPresentation.self
        )
        estimate.addString(presentation.threadID.rawValue)
        estimate.addStringValues(presentation.turnOrder.lazy.map(\.rawValue))

        estimate.addCollectionAllocation(count: presentation.turnsByID.count)
        for turnID in presentation.turnsByID.keys {
            estimate.add(MemoryLayout<TurnID>.stride)
            estimate.addString(turnID.rawValue)
        }

        estimate.addCollectionAllocation(count: presentation.sourceTurnRevisions.count)
        for turnID in presentation.sourceTurnRevisions.keys {
            estimate.add(
                MemoryLayout<TurnID>.stride + MemoryLayout<StateRevision>.stride
            )
            estimate.addString(turnID.rawValue)
        }
        estimate.addCollectionAllocation(count: presentation.pendingRequests.count)
        return estimate.total
    }

    private static func requestByteCount(
        _ requests: [CodexTranscriptRequestPresentation]
    ) -> Int {
        var total = 0
        for request in requests {
            add(request.estimatedRetainedByteCount, to: &total)
        }
        return total
    }

    private static func add(_ value: Int, to total: inout Int) {
        guard value > 0, total != .max else { return }
        let (sum, overflow) = total.addingReportingOverflow(value)
        total = overflow ? .max : sum
    }

    private static func subtract(_ value: Int?, from total: inout Int) {
        guard let value, total != .max else { return }
        total = max(0, total - value)
    }

    private static func saturatedSum(_ values: Int...) -> Int {
        var total = 0
        for value in values { add(value, to: &total) }
        return total
    }
}

// MARK: - Conservative cache retention estimates

/// Deterministic, saturating accounting used by the warm-presentation caches.
///
/// Each nested value contributes its inline stride. Dynamically retained
/// strings contribute their UTF-8 payload, and collections contribute a stable
/// allocation/bucket allowance. The estimate deliberately errs high when
/// copy-on-write values share storage; under-counting would defeat eviction.
struct CodexPresentationRetentionEstimate {
    private(set) var total: Int

    init<T>(_ type: T.Type) {
        total = MemoryLayout<T>.stride
    }

    init(startingAt value: Int = 0) {
        total = max(0, value)
    }

    mutating func add(_ value: Int) {
        guard value > 0, total != .max else { return }
        let (sum, overflow) = total.addingReportingOverflow(value)
        total = overflow ? .max : sum
    }

    mutating func addProduct(_ lhs: Int, _ rhs: Int) {
        guard lhs > 0, rhs > 0 else { return }
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        add(overflow ? .max : product)
    }

    mutating func addString(_ value: String?) {
        guard let value else { return }
        add(value.utf8.count)
    }

    mutating func addStringValues<S: Sequence>(_ values: S) where S.Element == String {
        var count = 0
        for value in values {
            count &+= 1
            add(MemoryLayout<String>.stride + 8)
            addString(value)
        }
        if count > 0 {
            add(32)
        }
    }

    mutating func addCollectionAllocation(count: Int) {
        guard count > 0 else { return }
        // Heap object bookkeeping plus conservative per-element/bucket slack.
        add(32)
        addProduct(count, 8)
    }
}

extension CodexTurnV2 {
    var estimatedRetainedByteCount: Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        estimate.addString(id)
        if let userMessage {
            estimate.add(userMessage.estimatedRetainedByteCount)
        }

        estimate.addCollectionAllocation(count: steeredMessages.count)
        for message in steeredMessages {
            estimate.add(message.estimatedRetainedByteCount)
        }

        estimate.addCollectionAllocation(count: conversationSegments.count)
        for segment in conversationSegments {
            estimate.add(segment.estimatedRetainedByteCount)
        }

        estimate.addCollectionAllocation(count: narrative.count)
        for entry in narrative {
            estimate.add(entry.estimatedRetainedByteCount)
        }

        if let finalAnswer {
            estimate.add(finalAnswer.estimatedRetainedByteCount)
        }
        estimate.addCollectionAllocation(count: generatedImages.count)
        for image in generatedImages {
            estimate.add(image.estimatedRetainedByteCount)
        }
        estimate.addString(liveTail)
        if case .failed(let message) = status {
            estimate.addString(message)
        }
        return estimate.total
    }
}

private extension CodexTurnConversationSegmentV2 {
    var estimatedRetainedByteCount: Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        estimate.addString(id)
        if let steeredMessage {
            estimate.add(steeredMessage.estimatedRetainedByteCount)
        }
        estimate.addCollectionAllocation(count: narrative.count)
        for entry in narrative {
            estimate.add(entry.estimatedRetainedByteCount)
        }
        return estimate.total
    }
}

private extension CodexUserMessageV2 {
    var estimatedRetainedByteCount: Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        estimate.addString(id)
        estimate.addString(clientID)
        estimate.addString(text)
        estimate.addString(rawText)
        estimate.addCollectionAllocation(count: referencedFiles.count)
        for file in referencedFiles {
            estimate.add(MemoryLayout<CodexReferencedFile>.stride)
            estimate.addString(file.id)
            estimate.addString(file.path)
            estimate.addString(file.displayName)
        }
        return estimate.total
    }
}

private extension CodexAssistantTextV2 {
    var estimatedRetainedByteCount: Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        estimate.addString(id)
        estimate.addString(text)
        return estimate.total
    }
}

private extension CodexGeneratedImageV2 {
    var estimatedRetainedByteCount: Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        estimate.addString(id)
        estimate.addString(source)
        estimate.addString(revisedPrompt)
        return estimate.total
    }
}

private extension CodexNarrativeEntry {
    var estimatedRetainedByteCount: Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        switch self {
        case .prose(let prose):
            estimate.add(prose.estimatedRetainedByteCount)
        case .workGroup(let group):
            estimate.add(group.estimatedRetainedByteCount)
        case .productToolCall(let toolCall):
            estimate.add(toolCall.estimatedRetainedByteCount)
        case .inlineActivity(let activity):
            estimate.add(activity.estimatedRetainedByteCount)
        case .notice(let notice):
            estimate.add(MemoryLayout<CodexTurnNoticeV2>.stride)
            estimate.addString(notice.id)
            estimate.addString(notice.message)
        }
        return estimate.total
    }
}

private extension CodexWorkGroupV2 {
    var estimatedRetainedByteCount: Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        estimate.addString(id)
        estimate.addString(header)
        estimate.addCollectionAllocation(count: rows.count)
        for row in rows {
            estimate.add(row.estimatedRetainedByteCount)
        }
        return estimate.total
    }
}

private extension CodexWorkRowV2 {
    var estimatedRetainedByteCount: Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        switch self {
        case .command(let row):
            estimate.add(MemoryLayout<CodexCommandRowV2>.stride)
            estimate.addString(row.id)
            estimate.addString(row.command)
            estimate.addString(row.label)
            estimate.addString(row.output)
            estimate.add(row.status.estimatedRetainedPayloadByteCount)
            estimate.add(row.action.estimatedRetainedPayloadByteCount)
        case .fileChange(let row):
            estimate.add(row.estimatedRetainedByteCount)
        case .mcpToolCall(let row):
            estimate.add(MemoryLayout<CodexMCPToolCallRowV2>.stride)
            estimate.addString(row.id)
            estimate.addString(row.appName)
            estimate.addString(row.server)
            estimate.addString(row.tool)
            estimate.addString(row.errorFirstLine)
            estimate.add(row.status.estimatedRetainedPayloadByteCount)
            estimate.add(row.arguments?.estimatedRetainedByteCount ?? 0)
            estimate.add(row.result?.estimatedRetainedByteCount ?? 0)
        case .webSearch(let row):
            estimate.add(MemoryLayout<CodexWebSearchRowV2>.stride)
            estimate.addString(row.id)
            estimate.addString(row.query)
            estimate.add(row.status.estimatedRetainedPayloadByteCount)
        case .collabAgent(let row):
            estimate.add(row.estimatedRetainedByteCount)
        case .other(let row):
            estimate.add(MemoryLayout<CodexOtherWorkRowV2>.stride)
            estimate.addString(row.id)
            estimate.addString(row.label)
            estimate.add(row.status.estimatedRetainedPayloadByteCount)
        }
        return estimate.total
    }
}

private extension CodexFileChangeRowV2 {
    var estimatedRetainedByteCount: Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        estimate.addString(id)
        if changes.isEmpty {
            estimate.addStringValues(files)
        }
        estimate.addString(diff)
        estimate.add(status.estimatedRetainedPayloadByteCount)

        estimate.addCollectionAllocation(count: changes.count)
        for change in changes {
            estimate.add(MemoryLayout<CodexFileChangeV2>.stride)
            estimate.addString(change.id)
            estimate.addString(change.path)
            estimate.addString(change.destinationPath)
            estimate.add(change.kind.estimatedRetainedPayloadByteCount)
            estimate.addString(change.diff)
            estimate.add(change.wireValue?.estimatedRetainedByteCount ?? 0)
        }

        // The preparer already measures every retained display string against
        // its byte budget. Add deterministic object/entry/hunk/line structure
        // without reparsing or rematerializing a patch.
        estimate.add(64)
        estimate.add(retainedPreparedUTF8ByteCount)
        estimate.addCollectionAllocation(count: preparedChanges.count)
        for prepared in preparedChanges {
            estimate.add(MemoryLayout<CodexPreparedFileChangeV2>.stride)
            estimate.addString(prepared.changeID)
            estimate.addString(prepared.path)
            estimate.addString(prepared.previousPath)
            estimate.add(prepared.kind.estimatedRetainedPayloadByteCount)
            estimate.addString(prepared.file.path)
            estimate.addString(prepared.file.kind)
            estimate.addCollectionAllocation(count: prepared.file.hunks.count)
            for hunk in prepared.file.hunks {
                estimate.add(MemoryLayout<CodexDiffHunk>.stride)
                estimate.addCollectionAllocation(count: hunk.lines.count)
                estimate.addProduct(hunk.lines.count, MemoryLayout<CodexDiffLine>.stride)
            }
        }
        return estimate.total
    }
}

private extension CodexCollabAgentRowV2 {
    var estimatedRetainedByteCount: Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        estimate.addString(id)
        estimate.addStringValues(agentNames)
        estimate.addStringValues(agentThreadIDs)
        estimate.addString(instructions)
        estimate.addCollectionAllocation(count: agentMessages.count)
        for (key, value) in agentMessages {
            estimate.add(MemoryLayout<String>.stride * 2)
            estimate.addString(key)
            estimate.addString(value)
        }
        estimate.addCollectionAllocation(count: timeline.count)
        estimate.addProduct(timeline.count, MemoryLayout<CodexCollabActionV2>.stride)
        estimate.add(status.estimatedRetainedPayloadByteCount)
        return estimate.total
    }
}

private extension CodexProductToolCallV2 {
    var estimatedRetainedByteCount: Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        estimate.addString(id)
        estimate.addString(tool)
        estimate.addString(namespace)
        estimate.add(arguments?.estimatedRetainedByteCount ?? 0)
        estimate.add(status.estimatedRetainedPayloadByteCount)
        estimate.addCollectionAllocation(count: contentItems.count)
        for item in contentItems {
            estimate.add(item.estimatedRetainedByteCount)
        }
        return estimate.total
    }
}

private extension CodexInlineActivityV2 {
    var estimatedRetainedByteCount: Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        estimate.addString(id)
        estimate.addString(label)
        estimate.addString(systemImage)
        estimate.addString(detail)
        estimate.addString(imagePath)
        estimate.add(status.estimatedRetainedPayloadByteCount)
        return estimate.total
    }
}

private extension CodexWorkItemStatusV2 {
    var estimatedRetainedPayloadByteCount: Int {
        guard case .unknown(let value) = self else { return 0 }
        return value.utf8.count
    }
}

private extension CodexFileChangeKindV2 {
    var estimatedRetainedPayloadByteCount: Int {
        guard case .unknown(let value) = self else { return 0 }
        return value.utf8.count
    }
}

private extension CodexWorkCategoryV2 {
    var estimatedRetainedPayloadByteCount: Int {
        guard case .mcp(let value) = self else { return 0 }
        return value.utf8.count
    }
}

extension CodexJSONValue {
    var estimatedRetainedByteCount: Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        switch self {
        case .string(let value):
            estimate.addString(value)
        case .array(let values):
            estimate.addCollectionAllocation(count: values.count)
            for value in values {
                estimate.add(value.estimatedRetainedByteCount)
            }
        case .dictionary(let values):
            estimate.addCollectionAllocation(count: values.count)
            for (key, value) in values {
                estimate.add(MemoryLayout<String>.stride)
                estimate.addString(key)
                estimate.add(value.estimatedRetainedByteCount)
            }
        case .int, .double, .bool, .null:
            break
        }
        return estimate.total
    }
}

extension CodexTranscriptRequestPresentation {
    var estimatedRetainedByteCount: Int {
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        if case .string(let requestID) = id.requestID {
            estimate.addString(requestID)
        }
        if case .unknown(let method) = kind {
            estimate.addString(method)
        }
        estimate.addString(turnID?.rawValue)
        estimate.addString(itemID?.rawValue)
        estimate.addString(summary)
        return estimate.total
    }
}
