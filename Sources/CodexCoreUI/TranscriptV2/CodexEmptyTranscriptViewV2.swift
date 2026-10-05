import SwiftUI

public struct CodexEmptyTranscriptView: View {
    @Environment(\.codexAgentTheme) private var theme

    public struct Prompt: Equatable, Sendable {
        public var systemImage: String
        public var prompt: String
        public var detail: String?
        public init(systemImage: String = "sparkles", prompt: String, detail: String? = nil) {
            self.systemImage = systemImage
            self.prompt = prompt
            self.detail = detail
        }
    }

    public static let defaultPrompts = [
        Prompt(
            systemImage: "ladybug",
            prompt: "Debug an issue",
            detail: "Trace a failure, warning, or unexpected result"
        ),
        Prompt(
            systemImage: "list.bullet.clipboard",
            prompt: "Plan implementation",
            detail: "Turn a goal into concrete steps"
        ),
        Prompt(
            systemImage: "text.magnifyingglass",
            prompt: "Explain this project",
            detail: "Get a concise map of the current workspace"
        ),
        Prompt(
            systemImage: "scope",
            prompt: "Find relevant code",
            detail: "Search symbols, files, and call sites"
        )
    ]
    private let onSelect: (String) -> Void
    public init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

    public var body: some View {
        VStack(spacing: theme.spacing.xl) {
            VStack(spacing: theme.spacing.xs) {
                Text("What should we work on?")
                    .font(theme.fonts.heroTitle)
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Pick a starting point, or just ask.")
                    .font(theme.fonts.body)
                    .foregroundStyle(theme.colors.textSecondary)
            }

            // A 2x2 of glass tiles. Grouped so the system renders them in one
            // pass; merge spacing stays below the gutter so they never fuse.
            CodexGlassGroup(spacing: theme.spacing.xs) {
                Grid(horizontalSpacing: theme.spacing.sm + 2, verticalSpacing: theme.spacing.sm + 2) {
                    ForEach(0..<(Self.defaultPrompts.count + 1) / 2, id: \.self) { row in
                        GridRow {
                            ForEach(Self.defaultPrompts[(row * 2)..<min(row * 2 + 2, Self.defaultPrompts.count)], id: \.prompt) { item in
                                StarterTile(item: item) { onSelect(item.prompt) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 560)
        }
        .padding(.horizontal, theme.spacing.xl)
        .frame(maxWidth: .infinity, minHeight: 440, alignment: .center)
    }
}

private struct StarterTile: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var isHovered = false

    let item: CodexEmptyTranscriptView.Prompt
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: theme.spacing.sm + 2) {
                Image(systemName: item.systemImage)
                    .font(theme.fonts.panelTitle)
                    .foregroundStyle(theme.colors.accentText)
                    .frame(width: 30, height: 30)
                    .background(
                        theme.colors.accentSoft.opacity(isHovered ? 1 : 0.75),
                        in: RoundedRectangle(cornerRadius: theme.radii.small + 2, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.prompt)
                        .font(theme.fonts.chat.weight(.medium))
                        .foregroundStyle(theme.colors.textPrimary)
                    if let detail = item.detail {
                        Text(detail)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textSecondary)
                            .lineLimit(2, reservesSpace: true)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(theme.spacing.md + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous))
            .codexGlass(RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous), role: .control)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: theme.animations.snappyDuration), value: isHovered)
        .accessibilityLabel(item.prompt)
        .accessibilityHint(item.detail ?? "")
    }
}
