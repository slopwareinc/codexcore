import SwiftUI
import CodexCoreUI

struct CodexBottomTerminalPanel: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var model: CodexCoreAppModel
    let maxHeight: CGFloat

    @State private var dragStartHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            panelToolbar
            Divider()
                .overlay(theme.colors.border)
            outputView
        }
        .frame(height: model.bottomTerminalHeight)
        .frame(maxWidth: .infinity)
        .background(theme.colors.surfaceSunken.opacity(0.88))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.colors.border)
                .frame(height: 1)
        }
    }

    private var dragHandle: some View {
        ZStack {
            Rectangle()
                .fill(.clear)
                .frame(height: 12)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStartHeight == nil {
                                dragStartHeight = model.bottomTerminalHeight
                            }
                            let start = dragStartHeight ?? model.bottomTerminalHeight
                            model.setBottomTerminalHeight(start - value.translation.height, maxHeight: maxHeight)
                        }
                        .onEnded { _ in
                            dragStartHeight = nil
                        }
                )

            Capsule(style: .continuous)
                .fill(theme.colors.textTertiary.opacity(0.45))
                .frame(width: 42, height: 4)
        }
        .help("Drag to resize")
    }

    private var panelToolbar: some View {
        HStack(spacing: 10) {
            Label("Terminal", systemImage: "terminal.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.colors.textPrimary)

            Text(model.bottomTerminalStatus)
                .font(.system(size: 11))
                .foregroundStyle(theme.colors.textTertiary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                Task { await model.openBottomTerminalDemo() }
            } label: {
                Label(model.isBottomTerminalRunning ? "Running…" : "Open terminal", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.colors.accent)
            .disabled(model.isBottomTerminalRunning)

            Button {
                model.clearBottomTerminalOutput()
            } label: {
                Label("Clear", systemImage: "trash")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.colors.textSecondary)
            .help("Clear output")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var outputView: some View {
        ScrollView {
            Text(terminalText)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(theme.colors.surfaceSunken.opacity(0.6))
    }

    private var terminalText: String {
        if model.bottomTerminalText.isEmpty {
            return "No terminal output yet.\nUse Open terminal to run a demo command."
        }
        return model.bottomTerminalText
    }
}
