import SwiftUI

/// MCP configuration management backed by app-server `config/value/write` and
/// `config/mcpServer/reload`. The current protocol has no dedicated MCP CRUD RPC.
public struct CodexMCPStatusSheet: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.openURL) private var openURL

    public let servers: [CodexMCPServerStatus]
    public let isLoading: Bool
    public let errorMessage: String?
    public let provider: (any CodexIntegrationControlPlaneProvider)?
    public let threadID: String?
    public let onClose: () -> Void
    public let onRefresh: () -> Void

    @State private var editor: CodexMCPServerConfiguration?
    @State private var activityMessage: String?
    @State private var isMutating = false

    public init(
        servers: [CodexMCPServerStatus],
        isLoading: Bool,
        errorMessage: String?,
        provider: (any CodexIntegrationControlPlaneProvider)? = nil,
        threadID: String? = nil,
        onClose: @escaping () -> Void,
        onRefresh: @escaping () -> Void
    ) {
        self.servers = servers
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.provider = provider
        self.threadID = threadID
        self.onClose = onClose
        self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(theme.fonts.panelTitle)
                    .foregroundStyle(theme.colors.textSecondary)
                Text("MCP servers")
                    .font(theme.fonts.sheetTitle)
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer()
                Button { editor = CodexMCPServerConfiguration(name: "") } label: {
                    Label("Add server", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(provider == nil || isMutating)
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Refresh")
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            if isLoading {
                HStack(spacing: 8) {
                    CodexSpinner(size: .small)
                    Text("Loading").foregroundStyle(theme.colors.textSecondary)
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(theme.colors.danger)
            } else if servers.isEmpty {
                Text("No MCP servers").foregroundStyle(theme.colors.textTertiary)
            }
            if let activityMessage {
                Text(activityMessage)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            if !servers.isEmpty {
                Text("Existing servers are shown from runtime status. Edit and remove require complete configuration provenance and are unavailable here.")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(servers) { server in
                        MCPServerStatusRow(
                            server: server,
                            isMutating: isMutating,
                            canAuthenticate: provider != nil,
                            onLogin: { login(server) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .font(theme.fonts.caption)
        .padding(18)
        .frame(width: 720, height: 620)
        .sheet(item: $editor) { configuration in
            CodexMCPServerEditor(configuration: configuration, onCancel: { editor = nil }) { save($0) }
                .codexAgentTheme(theme)
        }
    }

    private func save(_ configuration: CodexMCPServerConfiguration) {
        guard let provider else { return }
        isMutating = true
        Task { @MainActor in
            do {
                _ = try await provider.perform(CodexMCPProtocolMutation.save(configuration))
                _ = try await provider.perform(.mcpReload)
                activityMessage = "Saved \(configuration.name) and reloaded MCP servers."
                editor = nil
                onRefresh()
            } catch {
                activityMessage = error.localizedDescription
            }
            isMutating = false
        }
    }

    private func login(_ server: CodexMCPServerStatus) {
        guard let provider else { return }
        isMutating = true
        Task { @MainActor in
            do {
                let response = try await provider.perform(.mcpOAuthLogin(.init(name: server.name, threadID: threadID)))
                if case .dictionary(let object) = response,
                   case .string(let authorizationURL)? = object["authorizationUrl"],
                   let url = URL(string: authorizationURL) {
                    openURL(url)
                    activityMessage = "Continue MCP sign-in in your browser."
                } else {
                    activityMessage = "MCP sign-in started."
                }
            } catch {
                activityMessage = error.localizedDescription
            }
            isMutating = false
        }
    }
}

private struct MCPServerStatusRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let server: CodexMCPServerStatus
    let isMutating: Bool
    let canAuthenticate: Bool
    let onLogin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: statusImage)
                    .font(theme.fonts.label)
                    .foregroundStyle(statusColor)
                    .frame(width: 18)
                Text(server.displayName)
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                if let version = server.version?.nilIfBlank {
                    Text(version).foregroundStyle(theme.colors.textTertiary)
                }
                Spacer()
                if server.authStatus == "notLoggedIn" {
                    Button("Log in", action: onLogin)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canAuthenticate)
                } else {
                    Text(server.authStatusLabel).foregroundStyle(theme.colors.textSecondary)
                }
                Text("Configuration read-only")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            .disabled(isMutating)

            HStack(spacing: 8) {
                Text(runtimeStatusLabel)
                    .foregroundStyle(statusColor)
                Text(server.inventorySummary).foregroundStyle(theme.colors.textSecondary)
                if let error = server.error?.nilIfBlank {
                    Text(error).foregroundStyle(theme.colors.danger).lineLimit(2)
                }
            }
            if let detail = server.detail?.nilIfBlank {
                Text(detail).foregroundStyle(theme.colors.textTertiary).lineLimit(2)
            }
        }
        .padding(11)
        .background(theme.colors.surfaceElevated.opacity(0.78), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous).stroke(theme.colors.border))
    }

    private var runtimeStatusLabel: String {
        if server.enabled == false { return "Disabled" }
        if let startupStatus = server.startupStatus?.nilIfBlank { return startupStatus.capitalized }
        return server.enabled == true ? "Enabled; runtime status unavailable" : "Configuration enablement unknown"
    }

    private var statusImage: String {
        if server.enabled == false { return "pause.circle" }
        switch server.startupStatus {
        case "ready": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "starting": return "clock"
        case "cancelled": return "minus.circle"
        default: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        if server.enabled == false { return theme.colors.textTertiary }
        switch server.startupStatus {
        case "ready": return theme.colors.success
        case "failed": return theme.colors.danger
        case "starting": return theme.colors.textSecondary
        default: return theme.colors.textTertiary
        }
    }
}

private struct CodexMCPServerEditor: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var draft: CodexMCPServerConfiguration
    @State private var arguments: String
    @State private var environment: String
    @State private var environmentVariableNames: String
    @State private var headers: String
    @State private var environmentHTTPHeaders: String
    @State private var enabledTools: String
    @State private var disabledTools: String

    let onCancel: () -> Void
    let onSave: (CodexMCPServerConfiguration) -> Void

    init(configuration: CodexMCPServerConfiguration, onCancel: @escaping () -> Void, onSave: @escaping (CodexMCPServerConfiguration) -> Void) {
        _draft = State(initialValue: configuration)
        _arguments = State(initialValue: configuration.arguments.joined(separator: "\n"))
        _environment = State(initialValue: Self.lines(configuration.environment))
        _environmentVariableNames = State(initialValue: configuration.environmentVariableNames.joined(separator: "\n"))
        _headers = State(initialValue: Self.lines(configuration.httpHeaders))
        _environmentHTTPHeaders = State(initialValue: Self.lines(configuration.environmentHTTPHeaders))
        _enabledTools = State(initialValue: configuration.enabledTools?.joined(separator: "\n") ?? "")
        _disabledTools = State(initialValue: configuration.disabledTools.joined(separator: "\n"))
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.name.isEmpty ? "Add MCP server" : "Edit MCP server").font(theme.fonts.sheetTitle)
            Form {
                TextField("Name", text: $draft.name)
                Toggle("Enabled", isOn: $draft.enabled)
                Picker("Transport", selection: $draft.transport) {
                    Text("stdio").tag(CodexMCPServerConfiguration.Transport.stdio)
                    Text("Streamable HTTP").tag(CodexMCPServerConfiguration.Transport.streamableHTTP)
                }
                if draft.transport == .stdio {
                    TextField("Command", text: $draft.command)
                    TextField("Arguments (one per line)", text: $arguments, axis: .vertical).lineLimit(2...5)
                    TextField("Environment (NAME=value)", text: $environment, axis: .vertical).lineLimit(2...5)
                    TextField("Environment variables to pass through (one per line)", text: $environmentVariableNames, axis: .vertical).lineLimit(2...4)
                    TextField("Working directory", text: Binding($draft.workingDirectory, replacingNilWith: ""))
                } else {
                    TextField("URL", text: $draft.url)
                    TextField("Bearer token environment variable", text: Binding($draft.bearerTokenEnvironmentVariable, replacingNilWith: ""))
                    TextField("HTTP headers (Name=value)", text: $headers, axis: .vertical).lineLimit(2...5)
                    TextField("Environment-backed headers (Name=ENV_VAR)", text: $environmentHTTPHeaders, axis: .vertical).lineLimit(2...5)
                }
                TextField("Enabled tools (one per line; blank means all)", text: $enabledTools, axis: .vertical).lineLimit(2...4)
                TextField("Disabled tools (one per line)", text: $disabledTools, axis: .vertical).lineLimit(2...4)
                TextField("Startup timeout (seconds)", value: Binding($draft.startupTimeoutSeconds, replacingNilWith: 10), format: .number)
                TextField("Tool timeout (seconds)", value: Binding($draft.toolTimeoutSeconds, replacingNilWith: 60), format: .number)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(finalizedDraft) }.buttonStyle(.borderedProminent).disabled(!isValid)
            }
        }
        .padding(22)
        .frame(width: 620, height: 560)
    }

    private var finalizedDraft: CodexMCPServerConfiguration {
        var result = draft
        result.arguments = Self.values(arguments)
        result.environment = Self.dictionary(environment)
        result.environmentVariableNames = Self.values(environmentVariableNames)
        result.httpHeaders = Self.dictionary(headers)
        result.environmentHTTPHeaders = Self.dictionary(environmentHTTPHeaders)
        let enabled = Self.values(enabledTools)
        result.enabledTools = enabled.isEmpty ? nil : enabled
        result.disabledTools = Self.values(disabledTools)
        return result
    }

    private var isValid: Bool {
        let validName = !draft.name.isEmpty && draft.name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0)
        }
        return validName && (draft.transport == .stdio ? !draft.command.nilIfBlank.isNilOrEmpty : !draft.url.nilIfBlank.isNilOrEmpty)
    }

    private static func values(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init).compactMap(\.nilIfBlank)
    }

    private static func dictionary(_ text: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values(text).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        })
    }

    private static func lines(_ values: [String: String]) -> String {
        values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
}

private extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith replacement: String) {
        self.init(get: { source.wrappedValue ?? replacement }, set: { source.wrappedValue = $0.nilIfBlank })
    }
}

private extension Binding where Value == Int {
    init(_ source: Binding<Int?>, replacingNilWith replacement: Int) {
        self.init(get: { source.wrappedValue ?? replacement }, set: { source.wrappedValue = $0 })
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
