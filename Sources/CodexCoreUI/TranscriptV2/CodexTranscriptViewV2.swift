import SwiftUI

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
    private let transcript: CodexTranscriptV2
    private let threadID: String
    private let sessionStore: CodexThreadUISessionStore?
    private let productToolRenderer: CodexProductToolRendererV2?
    private let emptyState: EmptyState
    private let contentHorizontalOffset: CGFloat
    private let bottomContentInset: CGFloat
    private let onOpenSubagent: (String) -> Void
    private let onEditUserMessage: (String) -> Void
    private let onForkChat: (() -> Void)?
    private let pendingApprovals: [CodexApprovalPrompt]
    private let onResolveApproval: (String, Bool) -> Void
    @State private var fallbackPresentedAt = Date()
    @State private var projectionError: String?
    @State private var projectionRetryRevision = 0

    public init(
        transcript: CodexTranscriptV2,
        threadID: String = "standalone",
        sessionStore: CodexThreadUISessionStore? = nil,
        productToolRenderer: CodexProductToolRendererV2? = nil,
        contentHorizontalOffset: CGFloat = 0,
        bottomContentInset: CGFloat = 170,
        onOpenSubagent: @escaping (String) -> Void = { _ in },
        onEditUserMessage: @escaping (String) -> Void = { _ in },
        onForkChat: (() -> Void)? = nil,
        pendingApprovals: [CodexApprovalPrompt] = [],
        onResolveApproval: @escaping (String, Bool) -> Void = { _, _ in },
        @ViewBuilder emptyState: () -> EmptyState
    ) {
        self.transcript = transcript
        self.threadID = threadID
        self.sessionStore = sessionStore
        self.productToolRenderer = productToolRenderer
        self.contentHorizontalOffset = contentHorizontalOffset
        self.onOpenSubagent = onOpenSubagent
        self.onEditUserMessage = onEditUserMessage
        self.onForkChat = onForkChat
        self.pendingApprovals = pendingApprovals
        self.onResolveApproval = onResolveApproval
        self.emptyState = emptyState()
        self.bottomContentInset = max(0, bottomContentInset)
    }

    public var body: some View {
        Group {
            if effectivePresentation.transcript.turns.isEmpty {
                emptyState
                    .padding(.horizontal, 28)
                    .padding(.top, 58)
                    .padding(.bottom, 150)
                    .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
                    .offset(x: contentHorizontalOffset)
            } else {
                CodexTranscriptListHost(
                    presentation: effectivePresentation,
                    sessionStore: sessionStore,
                    bottomContentInset: bottomContentInset,
                    contentHorizontalOffset: contentHorizontalOffset,
                    productToolRenderer: productToolRenderer,
                    onOpenSubagent: onOpenSubagent,
                    onEditUserMessage: onEditUserMessage,
                    onForkChat: onForkChat,
                    onResolveApproval: onResolveApproval,
                    retryRevision: projectionRetryRevision,
                    onProjectionError: { projectionError = $0 }
                )
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
        if var presentation = sessionStore?.activePresentation {
            presentation.pendingApprovals = pendingApprovals.filter { $0.threadId == nil || $0.threadId == presentation.threadID }
            return presentation
        }
        return CodexThreadUIPresentation(
            threadID: threadID,
            transcript: transcript,
            presentedAtByTurnID: Dictionary(uniqueKeysWithValues: transcript.turns.map { ($0.id, fallbackPresentedAt) }),
            pendingApprovals: pendingApprovals
        )
    }
}

public extension CodexTranscriptViewV2 where EmptyState == EmptyView {
    init(
        transcript: CodexTranscriptV2,
        threadID: String = "standalone",
        sessionStore: CodexThreadUISessionStore? = nil,
        productToolRenderer: CodexProductToolRendererV2? = nil,
        contentHorizontalOffset: CGFloat = 0,
        bottomContentInset: CGFloat = 170
    ) {
        self.init(
            transcript: transcript,
            threadID: threadID,
            sessionStore: sessionStore,
            productToolRenderer: productToolRenderer,
            contentHorizontalOffset: contentHorizontalOffset,
            bottomContentInset: bottomContentInset
        ) { EmptyView() }
    }
}
