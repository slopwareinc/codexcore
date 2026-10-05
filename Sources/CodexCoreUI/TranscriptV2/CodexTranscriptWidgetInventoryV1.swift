import Foundation

/// The stable identifiers used by the audited official transcript inventory.
///
/// This is intentionally a small, handwritten protocol-to-presentation
/// boundary.  The JSON inventory is audit evidence and is not loaded by the
/// application at runtime; keeping its identifiers here lets tests and host
/// products prove that every audited surface has a typed adapter without
/// coupling production code to documentation files.
public enum CodexTranscriptWidgetID: String, CaseIterable, Sendable, Equatable, Hashable {
    case todoList = "todo-list"
    case proposedPlan = "proposed-plan"
    case planImplementation = "plan-implementation"
    case mcpTypedContent = "mcp-typed-content"
    case mcpAppWidget = "mcp-app-widget"
    case automaticApprovalReview = "automatic-approval-review"
    case strictReviewAndInterruption = "strict-review-and-interruption"
    case reconnectingAndOverload = "reconnecting-and-overload"
    case historyAndTurnRecovery = "history-and-turn-recovery"
    case writerConflictAndRollback = "writer-conflict-and-rollback"
    case modelReroutePersonality = "model-reroute-personality"
    case forkWorktreeRemoteHook = "fork-worktree-remote-hook"
    case attachmentsContextProvenance = "attachments-context-provenance"
    case bookmarksBadgesInlineEdit = "bookmarks-badges-inline-edit"
    case mathMermaidVisualization = "math-mermaid-visualization"
    case streamingAccessibilityFocus = "streaming-accessibility-focus"

    public enum Family: String, CaseIterable, Sendable, Equatable, Hashable {
        case plan
        case mcp
        case safety
        case recovery
        case event
        case content
        case interaction
        case richContent = "rich-content"
        case accessibility
    }

    public var family: Family {
        switch self {
        case .todoList, .proposedPlan, .planImplementation: .plan
        case .mcpTypedContent, .mcpAppWidget: .mcp
        case .automaticApprovalReview, .strictReviewAndInterruption: .safety
        case .reconnectingAndOverload, .historyAndTurnRecovery, .writerConflictAndRollback: .recovery
        case .modelReroutePersonality, .forkWorktreeRemoteHook: .event
        case .attachmentsContextProvenance: .content
        case .bookmarksBadgesInlineEdit: .interaction
        case .mathMermaidVisualization: .richContent
        case .streamingAccessibilityFocus: .accessibility
        }
    }
}

/// One typed coverage declaration.  `eventAdapterIDs` and `rendererIDs` are
/// stable seams, rather than implementation names, so a host can replace an
/// adapter without changing canonical state or the audit contract.
public struct CodexTranscriptWidgetCoverageV1: Identifiable, Sendable, Equatable {
    public let id: CodexTranscriptWidgetID
    public let family: CodexTranscriptWidgetID.Family
    public let eventAdapterIDs: [String]
    public let rendererIDs: [String]
    public let canonicalFacts: String
    public let presentationFacts: String
    public let lazyHeavyContent: Bool

    public init(
        id: CodexTranscriptWidgetID,
        eventAdapterIDs: [String],
        rendererIDs: [String],
        canonicalFacts: String,
        presentationFacts: String,
        lazyHeavyContent: Bool = false
    ) {
        self.id = id
        self.family = id.family
        self.eventAdapterIDs = eventAdapterIDs
        self.rendererIDs = rendererIDs
        self.canonicalFacts = canonicalFacts
        self.presentationFacts = presentationFacts
        self.lazyHeavyContent = lazyHeavyContent
    }
}

/// Machine-checkable mapping for all 16 records in
/// `docs/reference/official-transcript-widget-inventory.v1.json`.
public enum CodexTranscriptWidgetInventoryV1 {
    public static let records: [CodexTranscriptWidgetCoverageV1] = [
        .init(id: .todoList, eventAdapterIDs: ["plan"], rendererIDs: ["structured-card"], canonicalFacts: "turn item plan payload", presentationFacts: "local disclosure and count", lazyHeavyContent: false),
        .init(id: .proposedPlan, eventAdapterIDs: ["plan", "turn-plan"], rendererIDs: ["structured-card"], canonicalFacts: "turn plan and plan item", presentationFacts: "turn-level disclosure and implementation action", lazyHeavyContent: false),
        .init(id: .planImplementation, eventAdapterIDs: ["plan"], rendererIDs: ["structured-card", "recovery"], canonicalFacts: "implementation request lifecycle", presentationFacts: "reconciled request status", lazyHeavyContent: false),
        .init(id: .mcpTypedContent, eventAdapterIDs: ["mcp-tool-call"], rendererIDs: ["mcp-content"], canonicalFacts: "MCP result content union", presentationFacts: "typed block stack and explicit raw action", lazyHeavyContent: true),
        .init(id: .mcpAppWidget, eventAdapterIDs: ["mcp-tool-call"], rendererIDs: ["mcp-app-widget"], canonicalFacts: "MCP app resource metadata", presentationFacts: "sandbox host lifecycle", lazyHeavyContent: true),
        .init(id: .automaticApprovalReview, eventAdapterIDs: ["auto-approval-review"], rendererIDs: ["approval-review"], canonicalFacts: "approval review start/completion", presentationFacts: "durable decision card", lazyHeavyContent: false),
        .init(id: .strictReviewAndInterruption, eventAdapterIDs: ["strict-review"], rendererIDs: ["approval-review", "recovery"], canonicalFacts: "strict review and turn outcome", presentationFacts: "persistent interruption guidance", lazyHeavyContent: false),
        .init(id: .reconnectingAndOverload, eventAdapterIDs: ["session-recovery", "turn-recovery"], rendererIDs: ["recovery"], canonicalFacts: "connection epoch and error", presentationFacts: "attempt/countdown and scoped retry", lazyHeavyContent: false),
        .init(id: .historyAndTurnRecovery, eventAdapterIDs: ["history-recovery", "turn-recovery"], rendererIDs: ["recovery"], canonicalFacts: "history coverage and failed turn", presentationFacts: "scoped retry without duplicate intent", lazyHeavyContent: false),
        .init(id: .writerConflictAndRollback, eventAdapterIDs: ["writer-safety"], rendererIDs: ["recovery"], canonicalFacts: "consistency and rollback result", presentationFacts: "non-replay warning and verification action", lazyHeavyContent: false),
        .init(id: .modelReroutePersonality, eventAdapterIDs: ["model-events"], rendererIDs: ["notice"], canonicalFacts: "model/rerouted and personality facts", presentationFacts: "ordered compact notice", lazyHeavyContent: false),
        .init(id: .forkWorktreeRemoteHook, eventAdapterIDs: ["thread-notices", "hook"], rendererIDs: ["notice", "hook-activity"], canonicalFacts: "thread source/environment and hook run", presentationFacts: "stable destination and bounded output", lazyHeavyContent: true),
        .init(id: .attachmentsContextProvenance, eventAdapterIDs: ["user-context", "memory-citation", "output-resource"], rendererIDs: ["text", "mcp-content"], canonicalFacts: "typed input and output provenance", presentationFacts: "chips, source links, lazy previews", lazyHeavyContent: true),
        .init(id: .bookmarksBadgesInlineEdit, eventAdapterIDs: ["presentation-navigation", "inline-edit"], rendererIDs: ["text", "notice"], canonicalFacts: "original user input remains canonical", presentationFacts: "bookmark/edit/focus state", lazyHeavyContent: false),
        .init(id: .mathMermaidVisualization, eventAdapterIDs: ["rich-markdown"], rendererIDs: ["math", "mermaid", "visualization"], canonicalFacts: "assistant markdown source", presentationFacts: "lazy renderer and textual fallback", lazyHeavyContent: true),
        .init(id: .streamingAccessibilityFocus, eventAdapterIDs: ["lifecycle-announcer"], rendererIDs: ["accessibility-status"], canonicalFacts: "turn/item phase", presentationFacts: "coalesced announcements and focus restoration", lazyHeavyContent: false),
    ]

    public static let ids: [CodexTranscriptWidgetID] = records.map(\.id)

    public static func coverage(for id: CodexTranscriptWidgetID) -> CodexTranscriptWidgetCoverageV1? {
        records.first { $0.id == id }
    }

    public static var isComplete: Bool {
        Set(ids) == Set(CodexTranscriptWidgetID.allCases)
            && records.count == CodexTranscriptWidgetID.allCases.count
            && records.allSatisfy { !$0.eventAdapterIDs.isEmpty && !$0.rendererIDs.isEmpty }
    }
}

public extension CodexTranscriptEventRegistry {
    /// Stable audit-facing adapter identifiers.  This intentionally does not
    /// expose closures or canonical payloads.
    static let officialInventoryAdapterIDs: Set<String> = Set(
        CodexTranscriptWidgetInventoryV1.records.flatMap(\.eventAdapterIDs)
    )
}

public extension CodexTranscriptRendererRegistry {
    /// Stable audit-facing renderer identifiers used by inventory coverage
    /// checks and host diagnostics.
    static let officialInventoryRendererIDs: Set<String> = Set(
        CodexTranscriptWidgetInventoryV1.records.flatMap(\.rendererIDs)
    )
}
