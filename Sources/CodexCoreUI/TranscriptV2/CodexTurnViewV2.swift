import SwiftUI

/// The official three-part turn presentation: user, work, final answer.
public struct CodexTurnViewV2: View {
    @Environment(\.codexAgentTheme) private var theme

    private let turn: CodexTurnV2
    private let productToolRenderer: CodexProductToolRendererV2?
    @State private var presentedAt = Date()

    public init(turn: CodexTurnV2, productToolRenderer: CodexProductToolRendererV2? = nil) {
        self.turn = turn
        self.productToolRenderer = productToolRenderer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let user = turn.userMessage {
                userBubble(user)
            }

            CodexWorkBlockViewV2(
                narrative: turn.narrative,
                liveTail: turn.liveTail,
                status: turn.status,
                productToolRenderer: productToolRenderer
            )

            if let answer = turn.finalAnswer, !answer.text.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    CodexAssistantContentView(
                        text: answer.text,
                        isStreaming: answer.isStreaming,
                        cacheNamespace: "transcript-v2-final-\(answer.id)"
                    )
                    timestamp(alignment: .leading)
                }
                .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func userBubble(_ message: CodexUserMessageV2) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(message.text)
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(theme.colors.userBubble)
                .clipShape(RoundedRectangle(cornerRadius: theme.radii.bubble, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radii.bubble, style: .continuous)
                        .stroke(theme.colors.userBubbleStroke, lineWidth: 1)
                }
            timestamp(alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func timestamp(alignment: Alignment) -> some View {
        Text(presentedAt.formatted(date: .omitted, time: .shortened))
            .font(theme.fonts.micro)
            .foregroundStyle(theme.colors.textTertiary)
            .frame(maxWidth: theme.spacing.userBubbleMaxWidth, alignment: alignment)
    }
}
