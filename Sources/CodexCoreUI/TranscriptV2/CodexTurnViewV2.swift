import SwiftUI

/// The official three-part turn presentation: user, work, final answer.
public struct CodexTurnViewV2: View {
    @Environment(\.codexAgentTheme) private var theme

    private let turn: CodexTurnV2
    private let productToolRenderer: CodexProductToolRendererV2?
    private let onOpenSubagent: (String) -> Void
    private let onOpenThread: (CodexThreadReferenceV2) -> Void

    public init(turn: CodexTurnV2, productToolRenderer: CodexProductToolRendererV2? = nil, onOpenSubagent: @escaping (String) -> Void = { _ in }, onOpenThread: @escaping (CodexThreadReferenceV2) -> Void = { _ in }) {
        self.turn = turn
        self.productToolRenderer = productToolRenderer
        self.onOpenSubagent = onOpenSubagent
        self.onOpenThread = onOpenThread
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let user = turn.userMessage {
                CodexUserMessageBubbleV2(message: user, onOpenThread: onOpenThread)
            }

            CodexWorkBlockViewV2(
                conversationSegments: turn.conversationSegments,
                narrative: turn.narrative,
                liveTail: turn.liveTail,
                status: turn.status,
                finalAnswer: turn.finalAnswer,
                productToolRenderer: productToolRenderer,
                onOpenSubagent: onOpenSubagent,
                onOpenThread: onOpenThread
            )

            if turn.finalAnswer?.text.isEmpty == false
                || !turn.generatedImages.isEmpty
                || !turn.imageGenerationFailures.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if let answer = turn.finalAnswer, !answer.text.isEmpty {
                        CodexAssistantContentView(
                            text: answer.text,
                            isStreaming: answer.isStreaming,
                            cacheNamespace: "transcript-v2-final-\(answer.id)"
                        )
                    }
                    ForEach(turn.generatedImages) { image in
                        CodexGeneratedImageViewV2(image: image)
                    }
                    ForEach(turn.imageGenerationFailures) { failure in
                        Label(failure.message, systemImage: "photo.badge.exclamationmark")
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.danger)
                            .padding(10)
                            .background(
                                theme.colors.danger.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: theme.radii.medium)
                            )
                            .accessibilityLabel(failure.message)
                    }
                    if let answer = turn.finalAnswer, !answer.text.isEmpty, let sentAt = answer.sentAt {
                        timestamp(sentAt, alignment: .leading)
                    }
                }
                .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timestamp(_ date: Date, alignment: Alignment) -> some View {
        Text(date.formatted(date: .omitted, time: .shortened))
            .font(theme.fonts.micro)
            .foregroundStyle(theme.colors.textTertiary)
            .frame(maxWidth: theme.spacing.userBubbleMaxWidth, alignment: alignment)
    }
}

private struct CodexGeneratedImageViewV2: View {
    @Environment(\.openURL) private var openURL
    let image: CodexGeneratedImageV2

    var body: some View {
        Group {
            if let path = CodexTranscriptImageSource.localFilePath(image.source) {
                Button {
                    openURL(URL(fileURLWithPath: path))
                } label: {
                    preview
                }
                .buttonStyle(.plain)
                .help("Open generated image")
            } else {
                preview
            }
        }
        .accessibilityLabel("Generated image")
    }

    private var preview: some View {
        CodexTranscriptImageThumbnail(
            source: image.source,
            label: "Generated image",
            side: 360,
            aspectRatio: CodexTranscriptImageSource.aspectRatio(image.source) ?? 1
        )
    }
}

struct CodexUserMessageBubbleV2: View {
    @Environment(\.codexAgentTheme) private var theme

    let message: CodexUserMessageV2
    let onOpenThread: (CodexThreadReferenceV2) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            if let source = message.delegationSource {
                Button {
                    onOpenThread(source)
                } label: {
                    Label("Sent by Codex from another chat", systemImage: "bubble.left.and.bubble.right")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
            Text(message.displayText)
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, theme.interfaceStyle == .t3Code ? 12 : 14)
                .padding(.vertical, theme.interfaceStyle == .t3Code ? 12 : 10)
                .background(theme.colors.userBubble)
                .clipShape(RoundedRectangle(cornerRadius: theme.radii.bubble, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radii.bubble, style: .continuous)
                        .stroke(theme.colors.userBubbleStroke, lineWidth: theme.interfaceStyle == .t3Code ? 0 : 1)
                }
                .frame(maxWidth: theme.spacing.userBubbleMaxWidth, alignment: .trailing)
            if let sentAt = message.sentAt {
                Text(sentAt.formatted(date: .omitted, time: .shortened))
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(maxWidth: theme.spacing.userBubbleMaxWidth, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
