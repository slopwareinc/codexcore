import SwiftUI
import CodexCore

struct CodexAppDetailSheet: View {
    @Environment(\.codexAgentTheme) private var theme
    let app: CodexAppSummary
    let threadID: String?
    let provider: (any CodexIntegrationControlPlaneProvider)?
    let onClose: () -> Void
    let onRefresh: () -> Void
    @State private var detail: CodexSchemaConnectorMetadata?
    @State private var configuration: CodexSchemaConfigReadResponse?
    @State private var error: String?
    @State private var isLoading = false
    @State private var isWriting = false
    @State private var pendingRequest: CodexIntegrationControlPlaneRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                CodexPluginIconView(reference: app.icon, size: 46, fallbackSystemName: "app.dashed")
                Text(detail?.name ?? app.name).font(theme.fonts.sheetTitle)
                Spacer()
                if let raw = detail?.installUrl ?? app.installURL, let url = URL(string: raw), ["https", "http"].contains(url.scheme) {
                    Link(app.isInstalled ? "Manage connection" : "Connect app", destination: url).buttonStyle(.borderedProminent)
                }
                Button("Close", systemImage: "xmark", action: onClose).labelStyle(.iconOnly)
            }
            Text(detail?.description ?? app.description ?? "App integration").font(theme.fonts.chat).textSelection(.enabled)
            if isLoading { ProgressView("Loading app tools") }
            if let error { Text(error).foregroundStyle(theme.colors.danger) }
            if let plugins = detail?.pluginDisplayNames, !plugins.isEmpty {
                Text("Plugins: \(plugins.joined(separator: ", "))").foregroundStyle(theme.colors.textSecondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(detail?.toolSummaries ?? [], id: \.name) { tool in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(tool.title ?? tool.name).font(theme.fonts.label)
                                if tool.isReadOnly == true { Text("Read-only").foregroundStyle(theme.colors.textSecondary) }
                                Spacer()
                                Toggle("Enabled", isOn: Binding(get: { tool.isEnabled ?? true }, set: {
                                    propose(tool: tool.name, enabled: $0)
                                })).labelsHidden().toggleStyle(.switch)
                                Menu("Approval") {
                                    ForEach(CodexSchemaAppToolApproval.allCases, id: \.rawValue) { mode in
                                        Button(mode.rawValue.capitalized) { propose(tool: tool.name, approval: mode) }
                                    }
                                }
                            }
                            Text(tool.description).foregroundStyle(theme.colors.textSecondary)
                            if let reason = tool.disabledReason { Text(reason).foregroundStyle(theme.colors.warning) }
                        }
                        .disabled(configuration == nil || isWriting)
                        Divider()
                    }
                    if !isLoading && (detail?.toolSummaries?.isEmpty ?? true) {
                        Text("No tools reported for this app.").foregroundStyle(theme.colors.textSecondary)
                    }
                }
            }
        }
        .font(theme.fonts.caption).padding(24).frame(width: 700, height: 580).background(theme.colors.surface)
        .task(id: app.id) { await load() }
        .confirmationDialog("Update app tool policy?", isPresented: Binding(
            get: { pendingRequest != nil }, set: { if !$0 { pendingRequest = nil } }
        )) {
            Button("Update policy") { save() }
        } message: { Text("This changes which tools Codex can use and when they require approval.") }
    }

    private func load() async {
        guard let provider else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await provider.perform(.appRead(.init(appIDs: [app.id], includeTools: true, threadID: threadID)))
                .decode(CodexSchemaAppsReadResponse.self)
            try Task.checkCancellation()
            guard let value = response.apps.first(where: { $0.id == app.id }) else {
                throw CodexIntegrationControlPlaneError("This app is no longer available.")
            }
            detail = value
            configuration = try await provider.perform(.configRead(.init(includeLayers: true))).decode(CodexSchemaConfigReadResponse.self)
            try Task.checkCancellation()
            error = nil
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }

    private func propose(tool: String, enabled: Bool? = nil, approval: CodexSchemaAppToolApproval? = nil) {
        guard let configuration else { return }
        do {
            pendingRequest = try CodexIntegrationFeatureWorkflows.appToolPolicyRequest(
                appID: app.id, tool: tool, enabled: enabled, approval: approval, config: configuration
            )
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard let provider, let request = pendingRequest else { return }
        pendingRequest = nil
        isWriting = true
        Task {
            defer { isWriting = false }
            do { _ = try await provider.perform(request); onRefresh(); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
}
