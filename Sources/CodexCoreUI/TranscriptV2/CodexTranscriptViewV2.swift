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
    @Environment(\.codexAgentTheme) private var theme

    private let transcript: CodexTranscriptV2
    private let productToolRenderer: CodexProductToolRendererV2?
    private let emptyState: EmptyState
    private let contentHorizontalOffset: CGFloat

    public init(
        transcript: CodexTranscriptV2,
        productToolRenderer: CodexProductToolRendererV2? = nil,
        contentHorizontalOffset: CGFloat = 0,
        @ViewBuilder emptyState: () -> EmptyState
    ) {
        self.transcript = transcript
        self.productToolRenderer = productToolRenderer
        self.contentHorizontalOffset = contentHorizontalOffset
        self.emptyState = emptyState()
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if transcript.turns.isEmpty {
                    emptyState
                        .padding(.horizontal, 28)
                        .padding(.top, 58)
                        .padding(.bottom, 150)
                        .frame(maxWidth: theme.spacing.transcriptOuterMaxWidth)
                        .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
                        .offset(x: contentHorizontalOffset)
                } else {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(transcript.turns) { turn in
                            CodexTurnViewV2(turn: turn, productToolRenderer: productToolRenderer)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .frame(maxWidth: theme.spacing.transcriptOuterMaxWidth, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 58 + 20)
                    .padding(.bottom, 150 + 20)
                    .frame(maxWidth: .infinity)
                    .offset(x: contentHorizontalOffset)
                }
            }
            .scrollContentBackground(.hidden)
            .onAppear { scrollToBottom(proxy, animated: false) }
            .onChange(of: transcript) { _, _ in scrollToBottom(proxy, animated: true) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static var bottomID: String { "codex-transcript-v2-bottom" }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !transcript.turns.isEmpty else { return }
        if animated {
            withAnimation(.easeOut(duration: theme.animations.defaultDuration)) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }
}

public extension CodexTranscriptViewV2 where EmptyState == EmptyView {
    init(
        transcript: CodexTranscriptV2,
        productToolRenderer: CodexProductToolRendererV2? = nil,
        contentHorizontalOffset: CGFloat = 0
    ) {
        self.init(
            transcript: transcript,
            productToolRenderer: productToolRenderer,
            contentHorizontalOffset: contentHorizontalOffset
        ) { EmptyView() }
    }
}
