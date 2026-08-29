import SwiftUI

/// Presentation-only state for an inline user-message edit.
public enum CodexInlineMessageEditPhase: String, Sendable, Equatable {
    case editing
    case saving
    case failed
    case committed
    case cancelled
}

public struct CodexInlineMessageEditorState: Sendable, Equatable {
    public var messageID: String
    public var text: String
    public let originalText: String
    public var phase: CodexInlineMessageEditPhase
    public var errorMessage: String?
    /// The original message is retained locally so an unsuccessful save can
    /// restore attachments/context exactly; it is never written to canonical
    /// state by this value type.
    public let originalMessage: CodexUserMessageV2?

    public init(
        messageID: String,
        text: String,
        originalMessage: CodexUserMessageV2? = nil,
        phase: CodexInlineMessageEditPhase = .editing,
        errorMessage: String? = nil
    ) {
        self.messageID = messageID
        self.text = text
        self.originalText = originalMessage?.rawText ?? text
        self.phase = phase
        self.errorMessage = errorMessage
        self.originalMessage = originalMessage
    }

    public init(message: CodexUserMessageV2) {
        self.init(
            messageID: message.id,
            text: message.text,
            originalMessage: message
        )
    }

    public var canCommit: Bool {
        phase == .editing && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public mutating func updateText(_ value: String) {
        guard phase == .editing || phase == .failed else { return }
        text = value
        errorMessage = nil
        phase = .editing
    }

    public mutating func beginSaving() -> Bool {
        guard canCommit else { return false }
        phase = .saving
        errorMessage = nil
        return true
    }

    public mutating func markSaved() {
        phase = .committed
        errorMessage = nil
    }

    public mutating func markFailed(_ message: String) {
        text = originalText
        phase = .failed
        errorMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    public mutating func cancel() {
        text = originalText
        phase = .cancelled
        errorMessage = nil
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
