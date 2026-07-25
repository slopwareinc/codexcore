import SwiftUI
import CodexCore

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
    private let presentationStore: CodexPresentationStore?
    private let productToolRenderer: CodexProductToolRendererV2?
    private let emptyState: EmptyState
    private let contentHorizontalOffset: CGFloat
    private let bottomContentInset: CGFloat
    private let supplementalTurns: [CodexTurnV2]
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
                emptyState
                    .padding(.horizontal, 28)
                    .padding(.top, 58)
                    .padding(.bottom, 150)
                    .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
                    .offset(x: contentHorizontalOffset)
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
        guard !supplementalTurns.isEmpty else { return }

        var seenSupplementalSignatures: Set<String> = []
        var additions = supplementalTurns.filter { turn in
            let signature = [
                turn.userMessage?.text ?? "",
                turn.finalAnswer?.text ?? "",
            ].joined(separator: "\u{1f}")
            return seenSupplementalSignatures.insert(signature).inserted
        }

        let voiceAnswersWithUser = Set(additions.compactMap { turn -> String? in
            guard turn.userMessage != nil else { return nil }
            return normalizedAnswer(turn.finalAnswer?.text)
        })
        if !voiceAnswersWithUser.isEmpty {
            presentation.transcript.turns.removeAll { turn in
                guard isSimpleAssistantOnlyTurn(turn),
                      let answer = normalizedAnswer(turn.finalAnswer?.text)
                else { return false }
                return voiceAnswersWithUser.contains(answer)
            }
        }

        let canonicalAnswers = Set(presentation.transcript.turns.compactMap {
            normalizedAnswer($0.finalAnswer?.text)
        })
        additions.removeAll { turn in
            guard turn.userMessage == nil,
                  let answer = normalizedAnswer(turn.finalAnswer?.text)
            else { return false }
            return canonicalAnswers.contains(answer)
        }

        let canonicalIDs = Set(presentation.transcript.turns.map(\.id))
        additions.removeAll { canonicalIDs.contains($0.id) }
        presentation.transcript.turns.append(contentsOf: additions)
        for turn in additions where presentation.presentedAtByTurnID[turn.id] == nil {
            presentation.presentedAtByTurnID[turn.id] = fallbackPresentedAt
        }
    }

    private func normalizedAnswer(_ text: String?) -> String? {
        guard let value = text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !value.isEmpty
        else { return nil }
        return value
    }

    private func isSimpleAssistantOnlyTurn(_ turn: CodexTurnV2) -> Bool {
        turn.userMessage == nil
            && turn.steeredMessages.isEmpty
            && turn.conversationSegments.allSatisfy {
                $0.steeredMessage == nil && $0.narrative.isEmpty
            }
            && turn.finalAnswer != nil
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
