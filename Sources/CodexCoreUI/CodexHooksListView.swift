import SwiftUI

/// Projection and state controls for the resolved hook policy returned by
/// `hooks/list`. Hook definitions stay with their owning config/plugin file;
/// enablement and trust write only `hooks.state` through the control plane.
public struct CodexHooksListView: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var mutatingHookIDs: Set<String> = []
    @State private var activityMessage: String?

    public let catalog: CodexHooksCatalog
    public let isLoading: Bool
    public let errorMessage: String?
    public let onRefresh: () -> Void
    public let provider: (any CodexIntegrationControlPlaneProvider)?

    public init(
        catalog: CodexHooksCatalog,
        isLoading: Bool = false,
        errorMessage: String? = nil,
        provider: (any CodexIntegrationControlPlaneProvider)? = nil,
        onRefresh: @escaping () -> Void
    ) {
        self.catalog = catalog
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.provider = provider
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
            if let activityMessage {
                Text(activityMessage).foregroundStyle(theme.colors.textSecondary)
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
                                if !hook.managed, let provider {
                                    Toggle("", isOn: Binding(
                                        get: { hook.enabled },
                                        set: { setEnabled($0, hook: hook, provider: provider) }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                    .disabled(mutatingHookIDs.contains(hook.id))
                                    if hook.trustStatus == .untrusted || hook.trustStatus == .modified {
                                        Button("Trust") { trust(hook, provider: provider) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                            .disabled(mutatingHookIDs.contains(hook.id))
                                    }
                                }
                            }
                            .font(theme.fonts.caption)
                            Text(hook.handlerDescription)
                                .foregroundStyle(theme.colors.textSecondary)
                                .lineLimit(2)
                            HStack(spacing: 8) {
                                Text("Timeout \(hook.timeoutSeconds)s")
                                if let limit = hook.additionalContextLimit {
                                    Text("Context limit \(limit)")
                                }
                                if let pluginID = hook.pluginID {
                                    Text("Plugin \(pluginID)")
                                }
                            }
                            .font(theme.fonts.micro)
                            .foregroundStyle(theme.colors.textTertiary)
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

    private func setEnabled(
        _ enabled: Bool,
        hook: CodexHookSummary,
        provider: any CodexIntegrationControlPlaneProvider
    ) {
        mutate(hook, request: CodexHookProtocolMutation.setEnabled(enabled, for: hook), provider: provider)
    }

    private func trust(
        _ hook: CodexHookSummary,
        provider: any CodexIntegrationControlPlaneProvider
    ) {
        do {
            mutate(hook, request: try CodexHookProtocolMutation.trust(hook), provider: provider)
        } catch {
            activityMessage = error.localizedDescription
        }
    }

    private func mutate(
        _ hook: CodexHookSummary,
        request: CodexIntegrationControlPlaneRequest,
        provider: any CodexIntegrationControlPlaneProvider
    ) {
        guard mutatingHookIDs.insert(hook.id).inserted else { return }
        Task {
            defer { mutatingHookIDs.remove(hook.id) }
            do {
                _ = try await provider.perform(request)
                activityMessage = "Updated \(hook.eventLabel) hook."
                onRefresh()
            } catch {
                activityMessage = error.localizedDescription
            }
        }
    }
}
