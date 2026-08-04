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
        VStack(spacing: 18) {
            Text("What should we work on?")
                .font(theme.fonts.routeTitle)
                .foregroundStyle(theme.colors.textPrimary)

            VStack(spacing: 8) {
                ForEach(Self.defaultPrompts, id: \.prompt) { item in
                    Button {
                        onSelect(item.prompt)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.systemImage)
                                .font(theme.fonts.chat)
                                .foregroundStyle(theme.colors.accent)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.prompt)
                                    .font(theme.fonts.chat)
                                    .foregroundStyle(theme.colors.textPrimary)
                                    .multilineTextAlignment(.leading)
                                if let detail = item.detail {
                                    Text(detail)
                                        .font(theme.fonts.caption)
                                        .foregroundStyle(theme.colors.textTertiary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "arrow.up.left")
                                .font(theme.fonts.caption)
                                .foregroundStyle(theme.colors.textTertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(maxWidth: 420, alignment: .leading)
                        .codexGlass(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous), role: .control)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 440, alignment: .center)
    }
}
