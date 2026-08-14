import AppKit
import SwiftUI

@MainActor
final class CodexResponseAnnotationMarkerButton: NSButton {
    var markerColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .noImage
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = min(bounds.width / 26, bounds.height / 25)
        let body = NSBezierPath(
            roundedRect: NSRect(
                x: 1.5 * scale,
                y: 2.2 * scale,
                width: 23.8 * scale,
                height: 21.2 * scale
            ),
            xRadius: 10.6 * scale,
            yRadius: 10.6 * scale
        )
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 4.1 * scale, y: 5.2 * scale))
        tail.line(to: NSPoint(x: 2.7 * scale, y: 0.9 * scale))
        tail.line(to: NSPoint(x: 7.7 * scale, y: 3.0 * scale))
        tail.close()

        markerColor.setFill()
        tail.fill()
        body.fill()
        NSColor.selectedControlTextColor.withAlphaComponent(0.86).setStroke()
        body.lineWidth = 1.5
        body.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.selectedControlTextColor
        ]
        let label = title as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2 + 0.5
            ),
            withAttributes: attributes
        )
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

@MainActor
final class CodexResponseAnnotationEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CodexResponseSelectionActionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct CodexResponseSelectionActionView: View {
    @Environment(\.codexAgentTheme) private var theme

    let onAddToChat: () -> Void
    let onMoreDetails: (() -> Void)?
    let onAskInSideChat: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            selectionAction("Add to chat", action: onAddToChat)
            if let onMoreDetails {
                divider
                selectionAction("More details", action: onMoreDetails)
            }
            if let onAskInSideChat {
                divider
                selectionAction("Ask in side chat", action: onAskInSideChat)
            }
        }
        .fixedSize()
        .background(
            theme.colors.surfaceElevated.opacity(0.96),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.colors.border.opacity(0.7), lineWidth: 1)
        }
        .shadow(color: theme.colors.shadow.opacity(0.28), radius: 10, y: 5)
    }

    private func selectionAction(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        CodexResponseSelectionActionButton(title: title, action: action)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.colors.border.opacity(0.7))
            .frame(width: 1, height: 30)
    }
}

private struct CodexResponseSelectionActionButton: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var isHovered = false

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.fonts.caption.weight(.medium))
                .foregroundStyle(theme.colors.textPrimary)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(
                    isHovered ? theme.colors.hover.opacity(theme.effects.hoverOpacity) : .clear
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
    }
}

struct CodexResponseAnnotationNoteEditor: View {
    @Environment(\.codexAgentTheme) private var theme
    @FocusState private var isFocused: Bool
    @State private var note: String

    let isCreating: Bool
    let onSave: (String) -> Void
    let onDelete: () -> Void

    init(
        initialNote: String,
        isCreating: Bool,
        onSave: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        _note = State(initialValue: initialNote)
        self.isCreating = isCreating
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Add an optional comment…", text: $note, axis: .vertical)
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textPrimary)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .focused($isFocused)
                .accessibilityLabel("Note")
                .onSubmit { onSave(note) }

            if !isCreating {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Remove annotation")
            }

            Button {
                onSave(note)
            } label: {
                Image(systemName: "checkmark")
                    .font(theme.fonts.label.weight(.semibold))
                    .foregroundStyle(theme.colors.canvas)
                    .frame(width: 34, height: 34)
                    .background(theme.colors.textPrimary, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Save annotation")
            .accessibilityLabel("Save annotation")
        }
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .frame(width: 294, height: 44)
        .codexGlass(
            Capsule(),
            role: .panel
        )
        .onAppear { isFocused = true }
    }
}
