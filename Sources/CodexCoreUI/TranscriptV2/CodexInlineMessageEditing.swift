import SwiftUI

/// Presentation-only state for an inline user-message edit.
public struct CodexInlineMessageEditorState: Sendable, Equatable {
    public var messageID: String
    public var text: String

    public init(messageID: String, text: String) {
        self.messageID = messageID
        self.text = text
    }
}

/// Native inline editor used by SwiftUI hosts. The host owns submission and
/// decides whether the committed text becomes a new turn or a steer.
public struct CodexInlineMessageEditor: View {
    @Environment(\.codexAgentTheme) private var theme
    @Binding private var text: String
    private let onCommit: () -> Void
    private let onCancel: () -> Void

    public init(
        text: Binding<String>,
        onCommit: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._text = text
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            TextEditor(text: $text)
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 54, maxHeight: 180)
                .background(theme.colors.userBubble, in: RoundedRectangle(cornerRadius: theme.radii.bubble, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radii.bubble, style: .continuous)
                        .stroke(theme.colors.userBubbleStroke, lineWidth: 1)
                }
                .accessibilityLabel("Edit message")
            HStack(spacing: 8) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                Button("Save", action: onCommit)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(theme.fonts.caption)
        }
        .frame(maxWidth: theme.spacing.userBubbleMaxWidth, alignment: .trailing)
    }
}

