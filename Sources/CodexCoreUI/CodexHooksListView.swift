import SwiftUI

/// Read-only projection of the resolved hook policy returned by `hooks/list`.
/// Blocking and trust are intentionally prominent because they explain tool
/// denials that would otherwise look like generic permission failures.
public struct CodexHooksListView: View {
    @Environment(\.codexAgentTheme) private var theme

    public let catalog: CodexHooksCatalog
    public let isLoading: Bool
    public let errorMessage: String?
    public let onRefresh: () -> Void

    public init(
        catalog: CodexHooksCatalog,
        isLoading: Bool = false,
        errorMessage: String? = nil,
        onRefresh: @escaping () -> Void
    ) {
        self.catalog = catalog
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hooks").font(theme.fonts.sheetTitle)
                    Text("Tool gates and lifecycle automation")
                        .foregroundStyle(theme.colors.textSecondary)
                }
                Spacer()
                if isLoading { CodexSpinner(size: .small) }
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                    .accessibilityLabel("Refresh hooks")
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(theme.colors.danger)
            }
            ForEach(catalog.errors, id: \.self) { Text($0).foregroundStyle(theme.colors.danger) }
            ForEach(catalog.warnings, id: \.self) { Text($0).foregroundStyle(theme.colors.warning) }

            if !isLoading && catalog.hooks.isEmpty && errorMessage == nil {
                Text("No hooks configured").foregroundStyle(theme.colors.textTertiary)
            } else {
                List(catalog.hooks) { hook in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: hook.enabled ? "bolt.shield.fill" : "bolt.slash")
                            .foregroundStyle(color(for: hook))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(hook.eventLabel).font(theme.fonts.label)
                                if let matcher = hook.matcher?.nilIfBlank {
                                    Text(matcher)
                                        .font(theme.fonts.micro.monospaced())
                                        .foregroundStyle(theme.colors.textSecondary)
                                }
                                Spacer()
                                Text(hook.sourceLabel)
                                Text(hook.trustLabel)
                                    .foregroundStyle(color(for: hook))
                            }
                            .font(theme.fonts.caption)
                            Text(hook.command?.nilIfBlank ?? hook.handlerType.rawValue)
                                .foregroundStyle(theme.colors.textSecondary)
                                .lineLimit(2)
                            if let statusMessage = hook.statusMessage?.nilIfBlank {
                                Text(statusMessage).foregroundStyle(theme.colors.danger)
                            }
                            Text(hook.sourcePath)
                                .font(theme.fonts.micro.monospaced())
                                .foregroundStyle(theme.colors.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .listStyle(.inset)
            }
        }
        .font(theme.fonts.caption)
        .padding(20)
    }

    private func color(for hook: CodexHookSummary) -> Color {
        guard hook.enabled else { return theme.colors.textTertiary }
        switch hook.trustStatus {
        case .managed, .trusted: return theme.colors.success
        case .untrusted, .modified: return theme.colors.danger
        case .unrecognized: return theme.colors.warning
        }
    }
}
