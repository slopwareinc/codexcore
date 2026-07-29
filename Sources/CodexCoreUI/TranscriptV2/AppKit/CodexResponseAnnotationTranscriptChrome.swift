import AppKit
import SwiftUI

@MainActor
final class CodexResponseAnnotationMarkerButton: NSButton {
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

        NSColor(srgbRed: 2 / 255, green: 133 / 255, blue: 1, alpha: 1).setFill()
        tail.fill()
        body.fill()
        NSColor.white.withAlphaComponent(0.96).setStroke()
        body.lineWidth = 1.5
        body.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white
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

struct CodexResponseSelectionActionView: View {
    @Environment(\.codexAgentTheme) private var theme

    let onAddToChat: () -> Void

    var body: some View {
        Button(action: onAddToChat) {
            Text("Add to chat")
                .font(theme.fonts.caption.weight(.medium))
                .foregroundStyle(theme.colors.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add selected response text to chat")
        .codexGlass(
            RoundedRectangle(cornerRadius: 8, style: .continuous),
            tint: theme.colors.surface.opacity(0.5)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.colors.borderStrong.opacity(0.7), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
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
                    .font(.system(size: 15, weight: .semibold))
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
            tint: theme.colors.surface.opacity(0.55)
        )
        .overlay {
            Capsule()
                .stroke(theme.colors.borderStrong.opacity(0.72), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
        .onAppear { isFocused = true }
    }
}
