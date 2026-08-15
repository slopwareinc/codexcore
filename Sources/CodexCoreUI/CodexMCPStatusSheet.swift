import SwiftUI

public struct CodexMCPStatusSheet: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.openURL) private var openURL

    public let servers: [CodexMCPServerStatus]
    public let configurations: [String: CodexMCPServerConfiguration]
    public let isLoading: Bool
    public let errorMessage: String?
    public let threadID: String?
    public let provider: (any CodexIntegrationControlPlaneProvider)?
    public let onClose: () -> Void
    public let onRefresh: () -> Void

    @State private var editor: CodexMCPServerConfiguration?
    @State private var serverPendingRemoval: CodexMCPServerStatus?
    @State private var expandedServerNames: Set<String> = []
    @State private var activityMessage: String?
    @State private var isMutating = false

    public init(
        servers: [CodexMCPServerStatus],
        configurations: [String: CodexMCPServerConfiguration] = [:],
        isLoading: Bool,
        errorMessage: String?,
        threadID: String? = nil,
        provider: (any CodexIntegrationControlPlaneProvider)? = nil,
        onClose: @escaping () -> Void,
        onRefresh: @escaping () -> Void
    ) {
        self.servers = servers
        self.configurations = configurations
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.threadID = threadID
        self.provider = provider
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
                Button {
                    editor = .init(name: "")
                } label: {
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

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(servers) { server in
                        MCPServerStatusRow(
                            server: server,
                            isExpanded: expandedServerNames.contains(server.name),
                            isMutating: isMutating,
                            canManage: provider != nil,
                            onToggleExpanded: { toggleExpanded(server.name) },
                            onSetEnabled: { setEnabled(server, enabled: $0) },
                            onLogin: { login(server) },
                            onEdit: { editor = configurations[server.name] ?? configurationStub(for: server) },
                            onRemove: { serverPendingRemoval = server }
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
            CodexMCPServerEditor(configuration: configuration) { editor = nil } onSave: { save($0) }
                .codexAgentTheme(theme)
        }
        .confirmationDialog(
            "Remove MCP server?",
            isPresented: Binding(
                get: { serverPendingRemoval != nil },
                set: { if !$0 { serverPendingRemoval = nil } }
            ),
            presenting: serverPendingRemoval
        ) { server in
            Button("Remove \(server.displayName)", role: .destructive) { remove(server) }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            Text("This removes the \(server.name) configuration and reloads MCP servers.")
        }
        .task(id: provider != nil) { await observeStartupStatus() }
    }

    private func configurationStub(for server: CodexMCPServerStatus) -> CodexMCPServerConfiguration {
        .init(
            name: server.name,
            enabled: server.enabled ?? true,
            enabledTools: server.enabledTools,
            disabledTools: server.disabledTools,
            defaultToolsApprovalMode: server.defaultToolsApprovalMode,
            toolApprovalModes: Dictionary(uniqueKeysWithValues: server.tools.compactMap { tool in
                tool.approvalMode.map { (tool.name, $0) }
            })
        )
    }

    private func toggleExpanded(_ name: String) {
        if !expandedServerNames.insert(name).inserted { expandedServerNames.remove(name) }
    }

    private func save(_ configuration: CodexMCPServerConfiguration) {
        guard let provider else { return }
        isMutating = true
        Task {
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

    private func setEnabled(_ server: CodexMCPServerStatus, enabled: Bool) {
        guard let provider else { return }
        isMutating = true
        Task {
            do {
                _ = try await provider.perform(CodexMCPProtocolMutation.setEnabled(name: server.name, enabled: enabled))
                _ = try await provider.perform(.mcpReload)
                activityMessage = "\(enabled ? "Enabled" : "Disabled") \(server.displayName)."
                onRefresh()
            } catch {
                activityMessage = error.localizedDescription
            }
            isMutating = false
        }
    }

    private func remove(_ server: CodexMCPServerStatus) {
        guard let provider else { return }
        serverPendingRemoval = nil
        isMutating = true
        Task {
            do {
                _ = try await provider.perform(CodexMCPProtocolMutation.remove(name: server.name))
                _ = try await provider.perform(.mcpReload)
                activityMessage = "Removed \(server.displayName)."
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
        Task {
            do {
                let completions = try await provider.observeMCPServerOAuthLogin(name: server.name, threadID: threadID)
                let response = try await provider.perform(.mcpOAuthLogin(.init(name: server.name, threadID: threadID)))
                if case .dictionary(let object) = response,
                   case .string(let authorizationURL)? = object["authorizationUrl"],
                   let url = URL(string: authorizationURL) {
                    openURL(url)
                }
                for try await completion in completions {
                    if completion.success {
                        activityMessage = "Logged in to \(server.displayName)."
                        onRefresh()
                    } else {
                        activityMessage = CodexMCPAuthenticationError(message: completion.error ?? "OAuth login failed.").localizedDescription
                    }
                    break
                }
            } catch {
                activityMessage = CodexMCPAuthenticationError(message: error.localizedDescription).localizedDescription
            }
            isMutating = false
        }
    }

    private func observeStartupStatus() async {
        guard let provider,
              let updates = try? await provider.observeMCPServerStartupStatus(threadID: threadID) else { return }
        for await _ in updates {
            guard !Task.isCancelled else { return }
            onRefresh()
        }
    }
}

private struct MCPServerStatusRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let server: CodexMCPServerStatus
    let isExpanded: Bool
    let isMutating: Bool
    let canManage: Bool
    let onToggleExpanded: () -> Void
    let onSetEnabled: (Bool) -> Void
    let onLogin: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Button(action: onToggleExpanded) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right").frame(width: 16)
                }
                .buttonStyle(.plain)
                Image(systemName: statusImage).foregroundStyle(statusColor).frame(width: 18)
                Text(server.displayName).font(theme.fonts.label).lineLimit(1)
                if let version = server.version?.nilIfBlank {
                    Text(version).foregroundStyle(theme.colors.textTertiary)
                }
                Spacer()
                if server.authStatus == "notLoggedIn" {
                    Button("Log in", action: onLogin).buttonStyle(.bordered).controlSize(.small)
                } else {
                    Text(server.authStatusLabel).foregroundStyle(theme.colors.textSecondary)
                }
                Toggle("", isOn: Binding(get: { server.enabled ?? true }, set: { onSetEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help((server.enabled ?? true) ? "Disable server" : "Enable server")
                Menu {
                    Button("Edit", action: onEdit)
                    Button("Remove", role: .destructive, action: onRemove)
                } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
            }
            .disabled(isMutating || !canManage)

            HStack(spacing: 8) {
                Text((server.enabled ?? true) ? (server.startupState?.rawValue ?? "Status unavailable") : "Disabled")
                    .foregroundStyle(statusColor)
                Text(server.inventorySummary).foregroundStyle(theme.colors.textSecondary)
                if let failure = server.failureReason {
                    Text(failure.rawValue).foregroundStyle(theme.colors.danger)
                }
                if let error = server.error?.nilIfBlank {
                    Text(error).foregroundStyle(theme.colors.danger).lineLimit(2)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let defaultMode = server.defaultToolsApprovalMode {
                        Text("Default tool approval: \(defaultMode.rawValue)")
                    }
                    if let enabledTools = server.enabledTools {
                        Text("Allowed tools: \(enabledTools.joined(separator: ", "))")
                    }
                    if !server.disabledTools.isEmpty {
                        Text("Disabled tools: \(server.disabledTools.joined(separator: ", "))")
                    }
                    ForEach(server.tools) { tool in MCPToolRow(tool: tool) }
                    ForEach(server.resources) { resource in
                        Label(resource.displayName, systemImage: "doc")
                    }
                    ForEach(server.resourceTemplates) { resource in
                        Label(resource.displayName, systemImage: "doc.badge.gearshape")
                    }
                }
                .padding(.leading, 42)
            } else if let detail = server.detail?.nilIfBlank {
                Text(detail).foregroundStyle(theme.colors.textTertiary).lineLimit(2)
            }
        }
        .padding(11)
        .background(theme.colors.surfaceElevated.opacity(0.78), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous).stroke(theme.colors.border))
    }

    private var statusImage: String {
        guard server.enabled ?? true else { return "pause.circle" }
        switch server.startupState {
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .starting: return "clock"
        case .cancelled: return "minus.circle"
        case .unrecognized, nil: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        guard server.enabled ?? true else { return theme.colors.textTertiary }
        switch server.startupState {
        case .ready: return theme.colors.success
        case .failed: return theme.colors.danger
        case .starting: return theme.colors.textSecondary
        case .cancelled, .unrecognized, nil: return theme.colors.textTertiary
        }
    }
}

private struct MCPToolRow: View {
    @Environment(\.codexAgentTheme) private var theme
    let tool: CodexMCPServerStatus.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label(tool.displayName, systemImage: "hammer")
                Spacer()
                ForEach(badges, id: \.self) { badge in
                    Text(badge).font(theme.fonts.micro).foregroundStyle(theme.colors.textSecondary)
                }
            }
            if !tool.parameters.isEmpty {
                Text("Parameters: \(tool.parameters.joined(separator: ", "))")
                    .foregroundStyle(theme.colors.textTertiary)
            }
            if let detail = tool.detail?.nilIfBlank {
                Text(detail).foregroundStyle(theme.colors.textTertiary)
            }
        }
    }

    private var badges: [String] {
        var values: [String] = []
        if tool.readOnlyHint == true { values.append("Read-only") }
        if tool.destructiveHint == true { values.append("Destructive") }
        if tool.idempotentHint == true { values.append("Idempotent") }
        if tool.openWorldHint == true { values.append("Open world") }
        if let approvalMode = tool.approvalMode { values.append(approvalMode.rawValue.capitalized) }
        return values
    }
}

private struct CodexMCPServerEditor: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var draft: CodexMCPServerConfiguration
    @State private var arguments = ""
    @State private var environment = ""
    @State private var passthrough = ""
    @State private var headers = ""
    @State private var environmentHeaders = ""
    @State private var enabledTools = ""
    @State private var disabledTools = ""
    @State private var toolApprovals = ""

    let onCancel: () -> Void
    let onSave: (CodexMCPServerConfiguration) -> Void

    init(
        configuration: CodexMCPServerConfiguration,
        onCancel: @escaping () -> Void,
        onSave: @escaping (CodexMCPServerConfiguration) -> Void
    ) {
        _draft = State(initialValue: configuration)
        _arguments = State(initialValue: configuration.arguments.joined(separator: "\n"))
        _environment = State(initialValue: Self.lines(configuration.environment))
        _passthrough = State(initialValue: configuration.environmentPassthrough.joined(separator: "\n"))
        _headers = State(initialValue: Self.lines(configuration.httpHeaders))
        _environmentHeaders = State(initialValue: Self.lines(configuration.environmentHTTPHeaders))
        _enabledTools = State(initialValue: configuration.enabledTools?.joined(separator: "\n") ?? "")
        _disabledTools = State(initialValue: configuration.disabledTools.joined(separator: "\n"))
        _toolApprovals = State(initialValue: configuration.toolApprovalModes
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.rawValue)" }
            .joined(separator: "\n"))
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
                    TextField("Working directory", text: Binding($draft.workingDirectory, replacingNilWith: ""))
                    TextField("Environment (NAME=value)", text: $environment, axis: .vertical).lineLimit(2...5)
                    TextField("Environment passthrough (one name per line)", text: $passthrough, axis: .vertical).lineLimit(2...4)
                } else {
                    TextField("URL", text: $draft.url)
                    TextField("Bearer token environment variable", text: Binding($draft.bearerTokenEnvironmentVariable, replacingNilWith: ""))
                    TextField("HTTP headers (Name=value)", text: $headers, axis: .vertical).lineLimit(2...5)
                    TextField("Environment HTTP headers (Name=ENV_VAR)", text: $environmentHeaders, axis: .vertical).lineLimit(2...5)
                }
                TextField("Startup timeout (seconds)", value: $draft.startupTimeoutSeconds, format: .number)
                TextField("Tool timeout (seconds)", value: $draft.toolTimeoutSeconds, format: .number)
                TextField("Enabled tools (one per line, blank means all)", text: $enabledTools, axis: .vertical).lineLimit(2...4)
                TextField("Disabled tools (one per line)", text: $disabledTools, axis: .vertical).lineLimit(2...4)
                Picker("Default tool approval", selection: $draft.defaultToolsApprovalMode) {
                    Text("Runtime default").tag(CodexMCPToolApprovalMode?.none)
                    ForEach(CodexMCPToolApprovalMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                }
                TextField("Per-tool approval (tool=auto|prompt|writes|approve)", text: $toolApprovals, axis: .vertical)
                    .lineLimit(2...5)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(finalizedDraft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(22)
        .frame(width: 620, height: 650)
    }

    private var finalizedDraft: CodexMCPServerConfiguration {
        var result = draft
        result.arguments = Self.values(arguments)
        result.environment = Self.dictionary(environment)
        result.environmentPassthrough = Self.values(passthrough)
        result.httpHeaders = Self.dictionary(headers)
        result.environmentHTTPHeaders = Self.dictionary(environmentHeaders)
        let allowed = Self.values(enabledTools)
        result.enabledTools = allowed.isEmpty ? nil : allowed
        result.disabledTools = Self.values(disabledTools)
        result.toolApprovalModes = Self.dictionary(toolApprovals).reduce(into: [:]) { modes, entry in
            if let mode = CodexMCPToolApprovalMode(rawValue: entry.value) { modes[entry.key] = mode }
        }
        return result
    }

    private var isValid: Bool {
        let validName = !draft.name.isEmpty && draft.name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return validName && (draft.transport == .stdio ? !draft.command.isEmpty : URL(string: draft.url)?.scheme != nil)
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

extension CodexMCPServerConfiguration: Identifiable {
    public var id: String { name }
}
