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
        var estimate = CodexPresentationRetentionEstimate(Self.self)
        estimate.addString(threadID.rawValue)
        estimate.addStringValues(turnOrder.lazy.map(\.rawValue))

        estimate.addCollectionAllocation(count: turnsByID.count)
        for (turnID, turn) in turnsByID {
            estimate.add(MemoryLayout<TurnID>.stride)
            estimate.addString(turnID.rawValue)
            estimate.add(turn.estimatedRetainedByteCount)
        }

        estimate.addCollectionAllocation(count: sourceTurnRevisions.count)
        for turnID in sourceTurnRevisions.keys {
            estimate.add(MemoryLayout<TurnID>.stride + MemoryLayout<StateRevision>.stride)
            estimate.addString(turnID.rawValue)
        }

        estimate.addCollectionAllocation(count: pendingRequests.count)
        for request in pendingRequests {
            estimate.add(request.estimatedRetainedByteCount)
        }
        return estimate.total
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

private extension CodexTurnV2 {
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

private extension CodexTranscriptRequestPresentation {
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
