import SwiftUI
import CodexCore

struct CodexTranscriptEmptyStateLayout: Equatable, Sendable {
    var viewportWidth: CGFloat
    var contentWidth: CGFloat
    var horizontalOffset: CGFloat

    init(
        viewportWidth: CGFloat,
        requestedHorizontalOffset: CGFloat,
        horizontalPadding: CGFloat,
        maximumContentWidth: CGFloat
    ) {
        self.viewportWidth = max(0, viewportWidth)
        let padding = max(0, horizontalPadding)
        let availableWidth = max(0, self.viewportWidth - padding * 2)
        contentWidth = min(availableWidth, max(0, maximumContentWidth))
        let maximumOffset = max(0, (self.viewportWidth - contentWidth) / 2 - padding)
        horizontalOffset = min(
            max(requestedHorizontalOffset, -maximumOffset),
            maximumOffset
        )
    }

    var contentFrame: CGRect {
        CGRect(
            x: (viewportWidth - contentWidth) / 2 + horizontalOffset,
            y: 0,
            width: contentWidth,
            height: 1
        )
    }
}

/// Host hook for product-specific dynamic tool-call presentation.
public struct CodexProductToolRendererV2 {
    private let body: @MainActor (CodexProductToolCallV2) -> AnyView?

    public init(_ body: @escaping @MainActor (CodexProductToolCallV2) -> AnyView?) {
        self.body = body
    }

    @MainActor
    func render(_ call: CodexProductToolCallV2) -> AnyView? { body(call) }
}

/// A turn-centric transcript with automatic bottom anchoring.
public struct CodexTranscriptViewV2<EmptyState: View>: View {
    @Environment(\.codexAgentTheme) private var theme

    private let transcript: CodexTranscriptV2
    private let threadID: String
    private let presentationStore: CodexPresentationStore?
    private let productToolRenderer: CodexProductToolRendererV2?
    private let emptyState: EmptyState
    private let contentHorizontalOffset: CGFloat
    private let bottomContentInset: CGFloat
    private let supplementalTurns: [CodexTurnV2]
    private let supplementalPresentedAtByTurnID: [String: Date]
    private let responseAnnotations: [CodexResponseTextAnnotation]
    private let onUpsertResponseAnnotation: (CodexResponseTextAnnotation) -> Void
    private let onRemoveResponseAnnotation: (String) -> Void
    private let onOpenSubagent: (String) -> Void
    private let onEditUserMessage: (String) -> Void
    private let onForkChat: (() -> Void)?
    private let pendingApprovals: [CodexApprovalPrompt]
    private let agentDisplayNameByThreadID: [String: String]
    private let onResolveApproval: (CodexServerRequestKey, Bool) -> Void
    @State private var fallbackPresentedAt = Date()
    @State private var projectionError: String?
    @State private var projectionRetryRevision = 0

    public init(
        presentationStore: CodexPresentationStore,
        productToolRenderer: CodexProductToolRendererV2? = nil,
        contentHorizontalOffset: CGFloat = 0,
        bottomContentInset: CGFloat = 170,
        supplementalTurns: [CodexTurnV2] = [],
        supplementalPresentedAtByTurnID: [String: Date] = [:],
        responseAnnotations: [CodexResponseTextAnnotation] = [],
        onUpsertResponseAnnotation: @escaping (CodexResponseTextAnnotation) -> Void = { _ in },
        onRemoveResponseAnnotation: @escaping (String) -> Void = { _ in },
        onOpenSubagent: @escaping (String) -> Void = { _ in },
        onEditUserMessage: @escaping (String) -> Void = { _ in },
        onForkChat: (() -> Void)? = nil,
        agentDisplayNameByThreadID: [String: String] = [:],
        pendingApprovals: [CodexApprovalPrompt] = [],
        onResolveApproval: @escaping (CodexServerRequestKey, Bool) -> Void = { _, _ in },
        @ViewBuilder emptyState: () -> EmptyState
    ) {
        self.transcript = .init()
        self.threadID = "unassigned"
        self.presentationStore = presentationStore
        self.productToolRenderer = productToolRenderer
        self.contentHorizontalOffset = contentHorizontalOffset
        self.supplementalTurns = supplementalTurns
        self.supplementalPresentedAtByTurnID = supplementalPresentedAtByTurnID
        self.responseAnnotations = responseAnnotations
        self.onUpsertResponseAnnotation = onUpsertResponseAnnotation
        self.onRemoveResponseAnnotation = onRemoveResponseAnnotation
        self.onOpenSubagent = onOpenSubagent
        self.onEditUserMessage = onEditUserMessage
        self.onForkChat = onForkChat
        self.agentDisplayNameByThreadID = agentDisplayNameByThreadID
        self.pendingApprovals = pendingApprovals
        self.onResolveApproval = onResolveApproval
        self.emptyState = emptyState()
        self.bottomContentInset = max(0, bottomContentInset)
    }

    /// Standalone renderer Interface for previews and deterministic fixtures.
    /// Production hosts should use the canonical `presentationStore` initializer.
    public init(
        transcript: CodexTranscriptV2,
        threadID: String = "standalone",
        productToolRenderer: CodexProductToolRendererV2? = nil,
        contentHorizontalOffset: CGFloat = 0,
        bottomContentInset: CGFloat = 170,
        supplementalTurns: [CodexTurnV2] = [],
        supplementalPresentedAtByTurnID: [String: Date] = [:],
        responseAnnotations: [CodexResponseTextAnnotation] = [],
        onUpsertResponseAnnotation: @escaping (CodexResponseTextAnnotation) -> Void = { _ in },
        onRemoveResponseAnnotation: @escaping (String) -> Void = { _ in },
        onOpenSubagent: @escaping (String) -> Void = { _ in },
        onEditUserMessage: @escaping (String) -> Void = { _ in },
        onForkChat: (() -> Void)? = nil,
        agentDisplayNameByThreadID: [String: String] = [:],
        pendingApprovals: [CodexApprovalPrompt] = [],
        onResolveApproval: @escaping (CodexServerRequestKey, Bool) -> Void = { _, _ in },
        @ViewBuilder emptyState: () -> EmptyState
    ) {
        self.transcript = transcript
        self.threadID = threadID
        self.presentationStore = nil
        self.productToolRenderer = productToolRenderer
        self.contentHorizontalOffset = contentHorizontalOffset
        self.supplementalTurns = supplementalTurns
        self.supplementalPresentedAtByTurnID = supplementalPresentedAtByTurnID
        self.responseAnnotations = responseAnnotations
        self.onUpsertResponseAnnotation = onUpsertResponseAnnotation
        self.onRemoveResponseAnnotation = onRemoveResponseAnnotation
        self.onOpenSubagent = onOpenSubagent
        self.onEditUserMessage = onEditUserMessage
        self.onForkChat = onForkChat
        self.agentDisplayNameByThreadID = agentDisplayNameByThreadID
        self.pendingApprovals = pendingApprovals
        self.onResolveApproval = onResolveApproval
        self.emptyState = emptyState()
        self.bottomContentInset = max(0, bottomContentInset)
    }

    public var body: some View {
        let presentation = effectivePresentation
        let isEmpty = presentation.transcript.turns.isEmpty

        return ZStack {
            CodexTranscriptListHost(
                presentation: presentation,
                // Supplemental realtime turns are UI-owned and therefore do
                // not advance the canonical render-update revision. Force a
                // projection for each Voice presentation change.
                renderUpdate: supplementalTurns.isEmpty
                    ? presentationStore?.activeRenderUpdate
                    : nil,
                presentationStore: presentationStore,
                bottomContentInset: bottomContentInset,
                contentHorizontalOffset: contentHorizontalOffset,
                responseAnnotations: responseAnnotations,
                onUpsertResponseAnnotation: onUpsertResponseAnnotation,
                onRemoveResponseAnnotation: onRemoveResponseAnnotation,
                productToolRenderer: productToolRenderer,
                onOpenSubagent: onOpenSubagent,
                onEditUserMessage: onEditUserMessage,
                onForkChat: onForkChat,
                onResolveApproval: onResolveApproval,
                retryRevision: projectionRetryRevision,
                onProjectionError: { projectionError = $0 }
            )
            .opacity(isEmpty ? 0 : 1)
            .allowsHitTesting(!isEmpty)
            .accessibilityHidden(isEmpty)

            if isEmpty {
                GeometryReader { proxy in
                    let layout = CodexTranscriptEmptyStateLayout(
                        viewportWidth: proxy.size.width,
                        requestedHorizontalOffset: contentHorizontalOffset,
                        horizontalPadding: 28,
                        maximumContentWidth: theme.spacing.transcriptMaxWidth
                    )
                    emptyState
                        .frame(width: layout.contentWidth)
                        .frame(maxHeight: .infinity)
                        .clipped()
                        .padding(.top, 58)
                        .padding(.bottom, 150)
                        .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
                        .offset(x: layout.horizontalOffset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if let projectionError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(projectionError).lineLimit(2)
                    Button("Retry") {
                        self.projectionError = nil
                        projectionRetryRevision &+= 1
                    }
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 12)
            }
        }
    }

    private var effectivePresentation: CodexThreadUIPresentation {
        if var presentation = presentationStore?.activePresentation {
            // The independently revisioned request-inbox facet supplies rich
            // prompt bodies; the thread facet supplies transcript state and
            // ledger placement metadata. This disposable composition is not a
            // second protocol reducer.
            presentation.pendingApprovals = pendingApprovals.filter {
                $0.threadId == presentation.threadID
            }
            presentation.agentDisplayNameByThreadID = agentDisplayNameByThreadID
            appendSupplementalTurns(to: &presentation)
            return presentation
        }
        var presentation = CodexThreadUIPresentation(
            threadID: threadID,
            transcript: transcript,
            agentDisplayNameByThreadID: agentDisplayNameByThreadID,
            presentedAtByTurnID: Dictionary(uniqueKeysWithValues: transcript.turns.map { ($0.id, fallbackPresentedAt) }),
            pendingApprovals: pendingApprovals
        )
        appendSupplementalTurns(to: &presentation)
        return presentation
    }

    private func appendSupplementalTurns(to presentation: inout CodexThreadUIPresentation) {
        CodexSupplementalTranscriptTimeline.merge(
            supplementalTurns,
            presentedAtByTurnID: supplementalPresentedAtByTurnID,
            fallbackPresentedAt: fallbackPresentedAt,
            into: &presentation
        )
    }
}

public extension CodexTranscriptViewV2 where EmptyState == EmptyView {
    init(
        presentationStore: CodexPresentationStore,
        productToolRenderer: CodexProductToolRendererV2? = nil,
        contentHorizontalOffset: CGFloat = 0,
        bottomContentInset: CGFloat = 170
    ) {
        self.init(
            presentationStore: presentationStore,
            productToolRenderer: productToolRenderer,
            contentHorizontalOffset: contentHorizontalOffset,
            bottomContentInset: bottomContentInset
        ) { EmptyView() }
    }

    init(
        transcript: CodexTranscriptV2,
        threadID: String = "standalone",
        productToolRenderer: CodexProductToolRendererV2? = nil,
        contentHorizontalOffset: CGFloat = 0,
        bottomContentInset: CGFloat = 170
    ) {
        self.init(
            transcript: transcript,
            threadID: threadID,
            productToolRenderer: productToolRenderer,
            contentHorizontalOffset: contentHorizontalOffset,
            bottomContentInset: bottomContentInset
        ) { EmptyView() }
    }
}
