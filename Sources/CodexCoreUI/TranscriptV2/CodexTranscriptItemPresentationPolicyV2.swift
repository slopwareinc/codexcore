import CodexCore
import Foundation

/// Normalized canonical context supplied to a host transcript presentation policy.
///
/// `payload` contains the canonical item's current arguments and result fields.
/// Treat it as untrusted input and keep mapping work inexpensive.
public struct CodexTranscriptItemContextV2: Sendable, Equatable {
    public var threadID: ThreadID
    public var turnID: TurnID
    public var itemID: ItemID
    public var kind: ThreadItemKind
    public var payload: [String: CodexJSONValue]
    public var status: CodexWorkItemStatusV2

    public init(
        threadID: ThreadID,
        turnID: TurnID,
        itemID: ItemID,
        kind: ThreadItemKind,
        payload: [String: CodexJSONValue],
        status: CodexWorkItemStatusV2
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.kind = kind
        self.payload = payload
        self.status = status
    }
}

/// A host decision for one canonical item in the transcript projection.
public enum CodexTranscriptItemPresentationV2: Sendable, Equatable {
    /// Preserve CodexCoreUI's built-in projection and rendering.
    case standard
    /// Omit the item from the visible transcript.
    case hidden
    /// Replace the built-in projection with a compact semantic activity line.
    case inlineActivity(CodexInlineActivityV2)
}

/// Reusable host hook for semantic transcript activity projection.
public struct CodexTranscriptItemPresentationPolicyV2: Sendable {
    private let body: @Sendable (CodexTranscriptItemContextV2) -> CodexTranscriptItemPresentationV2

    public init(
        _ body: @escaping @Sendable (CodexTranscriptItemContextV2) -> CodexTranscriptItemPresentationV2
    ) {
        self.body = body
    }

    public func presentation(
        for context: CodexTranscriptItemContextV2
    ) -> CodexTranscriptItemPresentationV2 {
        body(context)
    }
}
