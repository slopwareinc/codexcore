import SwiftUI

/// The official three-part turn presentation: user, work, final answer.
public struct CodexTurnViewV2: View {
    @Environment(\.codexAgentTheme) private var theme

    private let turn: CodexTurnV2
    private let productToolRenderer: CodexProductToolRendererV2?
    private let onOpenSubagent: (String) -> Void
    private let onOpenThread: (CodexThreadReferenceV2) -> Void
    private let onEditMessage: ((CodexUserMessageV2, String) -> Void)?
    @State private var isEditingUserMessage = false
    @State private var editingText = ""
    @State private var presentedAt = Date()

    public init(turn: CodexTurnV2, productToolRenderer: CodexProductToolRendererV2? = nil, onOpenSubagent: @escaping (String) -> Void = { _ in }, onOpenThread: @escaping (CodexThreadReferenceV2) -> Void = { _ in }, onEditMessage: ((CodexUserMessageV2, String) -> Void)? = nil, initiallyEditing: Bool = false) {
        self.turn = turn
        self.productToolRenderer = productToolRenderer
        self.onOpenSubagent = onOpenSubagent
        self.onOpenThread = onOpenThread
        self.onEditMessage = onEditMessage
        self._isEditingUserMessage = State(initialValue: initiallyEditing)
        self._editingText = State(initialValue: turn.userMessage?.rawText ?? turn.userMessage?.text ?? "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let user = turn.userMessage {
                if isEditingUserMessage {
                    CodexInlineMessageEditor(
                        text: $editingText,
                        onCommit: {
                            onEditMessage?(user, editingText)
                            isEditingUserMessage = false
                        },
                        onCancel: { isEditingUserMessage = false }
                    )
                } else {
                    CodexUserMessageBubbleV2(message: user, presentedAt: presentedAt, onOpenThread: onOpenThread)
                }
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
                    if let answer = turn.finalAnswer {
                        ForEach(answer.memoryCitations) { citation in
                            Label(
                                "\(citation.path):\(citation.lineStart)-\(citation.lineEnd)",
                                systemImage: "book.closed"
                            )
                            .font(theme.fonts.micro)
                            .foregroundStyle(theme.colors.textTertiary)
                            .accessibilityLabel("Memory citation \(citation.path), lines \(citation.lineStart) through \(citation.lineEnd)")
                        }
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
                    if turn.finalAnswer?.text.isEmpty == false {
                        timestamp(alignment: .leading)
                    }
                }
                .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timestamp(alignment: Alignment) -> some View {
        Text(presentedAt.formatted(date: .omitted, time: .shortened))
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
    let presentedAt: Date
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
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(theme.colors.userBubble)
                .clipShape(RoundedRectangle(cornerRadius: theme.radii.bubble, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radii.bubble, style: .continuous)
                        .stroke(theme.colors.userBubbleStroke, lineWidth: 1)
                }
            Text(presentedAt.formatted(date: .omitted, time: .shortened))
                .font(theme.fonts.micro)
                .foregroundStyle(theme.colors.textTertiary)
                .frame(maxWidth: theme.spacing.userBubbleMaxWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
