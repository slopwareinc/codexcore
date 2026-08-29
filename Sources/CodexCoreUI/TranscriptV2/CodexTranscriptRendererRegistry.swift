import Foundation

/// A renderer-independent node. AppKit and SwiftUI adapters can bind the same
/// node without reparsing canonical JSON or duplicating event classification.
public enum CodexTranscriptRenderNodeV2: Sendable, Equatable {
    case structuredCard(CodexStructuredTranscriptCardV2)
    case mcpContent([CodexMCPContentBlockV2])
    case productTool(CodexProductToolCallV2)
    case approvalReview(CodexApprovalReviewCardV2)
    case hookActivity(CodexHookActivityV2)
    case recovery(CodexTranscriptRecoveryNoticeV2)
    case text(id: String, text: String)

    public var id: String {
        switch self {
        case .structuredCard(let card): card.id
        case .mcpContent: "mcp-content"
        case .productTool(let call): call.id
        case .approvalReview(let review): review.id
        case .hookActivity(let hook): hook.id
        case .recovery(let notice): notice.id
        case .text(let id, _): id
        }
    }
}

/// Narrow adapter used by host products that want to own one semantic node.
public struct CodexTranscriptRendererAdapter: Sendable {
    public let identifier: String
    private let body: @Sendable (CodexNarrativeEntry) -> CodexTranscriptRenderNodeV2?

    public init(
        identifier: String,
        body: @escaping @Sendable (CodexNarrativeEntry) -> CodexTranscriptRenderNodeV2?
    ) {
        self.identifier = identifier
        self.body = body
    }

    public func node(for entry: CodexNarrativeEntry) -> CodexTranscriptRenderNodeV2? {
        body(entry)
    }
}

/// Typed renderer registry. It composes narrow adapters in declaration order;
/// no caller needs to switch over protocol discriminants.
public struct CodexTranscriptRendererRegistry: Sendable {
    private let adapters: [CodexTranscriptRendererAdapter]

    public init(adapters: [CodexTranscriptRendererAdapter] = CodexTranscriptRendererRegistry.defaultAdapters) {
        self.adapters = adapters
    }

    public func node(for entry: CodexNarrativeEntry) -> CodexTranscriptRenderNodeV2? {
        adapters.lazy.compactMap { $0.node(for: entry) }.first
    }

    public static let `default`: Self = .init()

    public static let defaultAdapters: [CodexTranscriptRendererAdapter] = [
        .init(identifier: "structured-card") { entry in
            guard case .structuredCard(let card) = entry else { return nil }
            return .structuredCard(card)
        },
        .init(identifier: "mcp-content") { entry in
            guard case .workGroup(let group) = entry else { return nil }
            let blocks = group.rows.compactMap { row -> [CodexMCPContentBlockV2]? in
                guard case .mcpToolCall(let value) = row else { return nil }
                return value.contentBlocks
            }.flatMap { $0 }
            return blocks.isEmpty ? nil : .mcpContent(blocks)
        },
        .init(identifier: "product-tool") { entry in
            guard case .productToolCall(let call) = entry else { return nil }
            return .productTool(call)
        },
        .init(identifier: "approval-review") { entry in
            guard case .approvalReview(let review) = entry else { return nil }
            return .approvalReview(review)
        },
        .init(identifier: "hook-activity") { entry in
            guard case .hookActivity(let hook) = entry else { return nil }
            return .hookActivity(hook)
        },
        .init(identifier: "recovery") { entry in
            guard case .recovery(let notice) = entry else { return nil }
            return .recovery(notice)
        },
        .init(identifier: "text") { entry in
            guard case .notice(let notice) = entry else { return nil }
            return .text(id: notice.id, text: notice.message)
        },
    ]
}
