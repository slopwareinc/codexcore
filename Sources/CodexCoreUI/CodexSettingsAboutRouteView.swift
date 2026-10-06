import SwiftUI
import CodexCore

public enum CodexSettingsRoute: String, CaseIterable, Identifiable, Sendable {
    case general
    case appearance
    case profile
    case configuration
    case agents
    case integrations
    case sections
    case hooks
    case runtime
    case about

    public var id: String { rawValue }

    static var availableRoutes: [CodexSettingsRoute] {
        allCases
    }

    public var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .profile: return "Profile"
        case .configuration: return "Configuration"
        case .agents: return "Agent instructions"
        case .integrations: return "Integrations"
        case .sections: return "Chat sections"
        case .runtime: return "Runtime features"
        case .hooks: return "Hooks"
        case .about: return "About"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "sun.max"
        case .profile: return "person.crop.circle"
        case .configuration: return "slider.horizontal.3"
        case .agents: return "doc.text.magnifyingglass"
        case .integrations: return "puzzlepiece.extension"
        case .sections: return "rectangle.3.group"
        case .runtime: return "square.stack.3d.up"
        case .hooks: return "bolt.shield"
        case .about: return "info.circle"
        }
    }

    var groupTitle: String {
        switch self {
        case .general, .appearance, .profile, .configuration:
            return "Personal"
        case .agents, .sections, .hooks, .runtime:
            return "Coding"
        case .integrations:
            return "Integrations"
        case .about:
            return "CodexCore"
        }
    }

    var searchTerms: [String] {
        switch self {
        case .general:
            return ["approval", "permissions", "model", "reasoning", "bottom panel", "new chat"]
        case .appearance:
            return ["theme", "light", "dark", "font", "sidebar", "color", "contrast", "glass"]
        case .profile:
            return ["account", "profile", "plan", "server", "signed in"]
        case .configuration:
            return ["config", "sandbox", "workspace", "dependencies", "app server"]
        case .agents:
            return ["AGENTS.md", "instructions", "trusted", "authorization", "precedence", "project"]
        case .integrations:
            return ["mcp", "browser", "computer use", "plugins"]
        case .sections:
            return ["chats", "groups", "icons", "colors", "pinned"]
        case .runtime:
            return ["account", "gateway", "verification", "voice", "memory", "attachments", "projects", "files", "processes", "import", "experiments", "remote"]
        case .hooks:
            return ["automation", "command", "async", "mcp", "trust", "tool gates"]
        case .about:
            return ["version", "build", "metadata", "about"]
        }
    }
}

public struct CodexSettingsAboutRouteView: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var selectedRoute: CodexSettingsRoute = .general
    @State private var searchText = ""

    public let metadata: CodexAboutMetadata
    public let accountSummary: CodexAccountMenuSummary
    public let mcpServers: [CodexMCPServerStatus]
    public let isLoadingMCPServers: Bool
    public let serverDiagnostics: CodexSchemaServerDiagnosticsResponse?
    public let isLoadingServerDiagnostics: Bool
    public let serverDiagnosticsError: String?
    public let onRefreshServerDiagnostics: (() -> Void)?
    public let threadSections: [CodexSchemaThreadSection]
    public let isLoadingThreadSections: Bool
    public let threadSectionsError: String?
    public let onRefreshThreadSections: (() -> Void)?
    public let onCreateThreadSection: ((String, CodexSchemaThreadSectionAppearance?) -> Void)?
    public let onUpdateThreadSection: ((String, String, CodexAppServerOptionalField<CodexSchemaThreadSectionAppearance>) -> Void)?
    public let onDeleteThreadSection: ((String) -> Void)?
    public let hooksCatalog: CodexHooksCatalog
    public let isLoadingHooks: Bool
    public let hooksError: String?
    public let hooksProvider: (any CodexIntegrationControlPlaneProvider)?
    public let onRefreshHooks: (() -> Void)?
    public let runtimeFeatures: AnyView?
    public let onBackToApp: (() -> Void)?

    @Binding private var appearanceSettings: CodexAppearanceSettings
    @Binding private var approvalSelection: CodexApprovalSelection
    private let approvalOptions: [CodexApprovalSelection]
    private let managedPolicyRequirements: CodexManagedPolicyRequirements?
    private let agentsDocumentStore: CodexAgentsDocumentStore?
    private let codexHomePath: String?
    private let workingDirectory: String?
    @Binding private var modelSelection: CodexModelSelection
    private let modelOptions: [CodexModelSelection]
    @Binding private var reasoningSelection: CodexReasoningSelection
    @Binding private var isBottomPanelVisible: Bool
    @Binding private var newThreadHistoryMode: CodexNewThreadHistoryMode

    public init(
        metadata: CodexAboutMetadata,
        accountSummary: CodexAccountMenuSummary = CodexAccountMenuSummary(displayName: "Codex", detail: "Available"),
        appearanceSettings: Binding<CodexAppearanceSettings>,
        approvalSelection: Binding<CodexApprovalSelection> = .constant(.askForApproval),
        approvalOptions: [CodexApprovalSelection] = CodexApprovalSelection.defaultOptions,
        managedPolicyRequirements: CodexManagedPolicyRequirements? = nil,
        agentsDocumentStore: CodexAgentsDocumentStore? = nil,
        codexHomePath: String? = nil,
        workingDirectory: String? = nil,
        modelSelection: Binding<CodexModelSelection> = .constant(.appServerDefault),
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        reasoningSelection: Binding<CodexReasoningSelection> = .constant(.medium),
        isBottomPanelVisible: Binding<Bool> = .constant(false),
        newThreadHistoryMode: Binding<CodexNewThreadHistoryMode> = .constant(
            .defaultForPinnedRelease
        ),
        mcpServers: [CodexMCPServerStatus] = [],
        isLoadingMCPServers: Bool = false,
        serverDiagnostics: CodexSchemaServerDiagnosticsResponse? = nil,
        isLoadingServerDiagnostics: Bool = false,
        serverDiagnosticsError: String? = nil,
        onRefreshServerDiagnostics: (() -> Void)? = nil,
        threadSections: [CodexSchemaThreadSection] = [],
        isLoadingThreadSections: Bool = false,
        threadSectionsError: String? = nil,
        onRefreshThreadSections: (() -> Void)? = nil,
        onCreateThreadSection: ((String, CodexSchemaThreadSectionAppearance?) -> Void)? = nil,
        onUpdateThreadSection: ((String, String, CodexAppServerOptionalField<CodexSchemaThreadSectionAppearance>) -> Void)? = nil,
        onDeleteThreadSection: ((String) -> Void)? = nil,
        hooksCatalog: CodexHooksCatalog = .init(),
        isLoadingHooks: Bool = false,
        hooksError: String? = nil,
        hooksProvider: (any CodexIntegrationControlPlaneProvider)? = nil,
        onRefreshHooks: (() -> Void)? = nil,
        runtimeFeatures: AnyView? = nil,
        onBackToApp: (() -> Void)? = nil
    ) {
        self.metadata = metadata
        self.accountSummary = accountSummary
        self._appearanceSettings = appearanceSettings
        self._approvalSelection = approvalSelection
        self.approvalOptions = approvalOptions
        self.managedPolicyRequirements = managedPolicyRequirements
        self.agentsDocumentStore = agentsDocumentStore
        self.codexHomePath = codexHomePath
        self.workingDirectory = workingDirectory
        self._modelSelection = modelSelection
        self.modelOptions = modelOptions
        self._reasoningSelection = reasoningSelection
        self._isBottomPanelVisible = isBottomPanelVisible
        self._newThreadHistoryMode = newThreadHistoryMode
        self.mcpServers = mcpServers
        self.isLoadingMCPServers = isLoadingMCPServers
        self.serverDiagnostics = serverDiagnostics
        self.isLoadingServerDiagnostics = isLoadingServerDiagnostics
        self.serverDiagnosticsError = serverDiagnosticsError
        self.onRefreshServerDiagnostics = onRefreshServerDiagnostics
        self.threadSections = threadSections
        self.isLoadingThreadSections = isLoadingThreadSections
        self.threadSectionsError = threadSectionsError
        self.onRefreshThreadSections = onRefreshThreadSections
        self.onCreateThreadSection = onCreateThreadSection
        self.onUpdateThreadSection = onUpdateThreadSection
        self.onDeleteThreadSection = onDeleteThreadSection
        self.hooksCatalog = hooksCatalog
        self.isLoadingHooks = isLoadingHooks
        self.hooksError = hooksError
        self.hooksProvider = hooksProvider
        self.onRefreshHooks = onRefreshHooks
        self.runtimeFeatures = runtimeFeatures
        self.onBackToApp = onBackToApp
    }

    public var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider().overlay(theme.colors.border.opacity(0.7))
            contentPane
        }
        .background(theme.colors.surface)
        .task(id: selectedRoute) {
            if selectedRoute == .about, serverDiagnostics == nil {
                onRefreshServerDiagnostics?()
            } else if selectedRoute == .sections {
                onRefreshThreadSections?()
            } else if selectedRoute == .hooks {
                onRefreshHooks?()
            }
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let onBackToApp {
                Button(action: onBackToApp) {
                    Label("Back to app", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .settingsBackButton(theme: theme)
            } else {
                Text("Settings")
                    .font(theme.fonts.sheetTitle)
                    .foregroundStyle(theme.colors.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 30, alignment: .leading)
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                TextField("Search settings...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(theme.fonts.label)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(theme.colors.surfaceElevated.opacity(0.40), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groupedRoutes, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title)
                                .font(theme.fonts.caption)
                                .foregroundStyle(theme.colors.textTertiary)
                                .padding(.horizontal, 10)
                            ForEach(group.routes) { route in
                                Button {
                                    selectedRoute = route
                                } label: {
                                    Label(route.title, systemImage: route.systemImage)
                                }
                                .buttonStyle(.plain)
                                .settingsSidebarRow(theme: theme, isSelected: selectedRoute == route)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 34)
        .padding(.horizontal, 14)
        .frame(minWidth: 250, idealWidth: 250, maxWidth: 250, maxHeight: .infinity, alignment: .topLeading)
        .codexGlass(Rectangle(), role: .chrome)
    }

    private var contentPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !normalizedSearchText.isEmpty {
                    searchResults
                } else {
                    routeContent
                }
            }
            .padding(.horizontal, 72)
            .padding(.vertical, 42)
            .frame(maxWidth: 900, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var routeContent: some View {
        switch selectedRoute {
        case .general:
            CodexSettingsGeneralPage(
                approvalSelection: $approvalSelection,
                approvalOptions: effectiveApprovalOptions,
                managedPolicyRequirements: managedPolicyRequirements,
                modelSelection: $modelSelection,
                modelOptions: modelOptions,
                reasoningSelection: $reasoningSelection,
                isBottomPanelVisible: $isBottomPanelVisible
            )
        case .appearance:
            CodexAppearanceSettingsView(settings: $appearanceSettings)
        case .profile:
            CodexSettingsProfilePage(accountSummary: accountSummary, serverName: metadata.serverName)
        case .configuration:
            CodexSettingsConfigurationPage(
                metadata: metadata,
                approvalSelection: approvalSelection,
                newThreadHistoryMode: $newThreadHistoryMode
            )
        case .agents:
            CodexAgentsSettingsPage(
                store: agentsDocumentStore,
                codexHome: codexHomePath,
                workingDirectory: workingDirectory
            )
        case .integrations:
            CodexSettingsIntegrationsPage(mcpServers: mcpServers, isLoadingMCPServers: isLoadingMCPServers)
        case .sections:
            CodexSettingsThreadSectionsPage(
                sections: threadSections,
                isLoading: isLoadingThreadSections,
                errorMessage: threadSectionsError,
                onRefresh: onRefreshThreadSections,
                onCreate: onCreateThreadSection,
                onUpdate: onUpdateThreadSection,
                onDelete: onDeleteThreadSection
            )
        case .hooks:
            CodexHooksListView(
                catalog: hooksCatalog,
                isLoading: isLoadingHooks,
                errorMessage: hooksError,
                provider: hooksProvider,
                onRefresh: { onRefreshHooks?() }
            )
        case .runtime:
            runtimeFeatures
        case .about:
            CodexSettingsAboutPage(
                metadata: metadata,
                diagnostics: serverDiagnostics,
                isLoadingDiagnostics: isLoadingServerDiagnostics,
                diagnosticsError: serverDiagnosticsError,
                onRefreshDiagnostics: onRefreshServerDiagnostics
            )
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 16) {
            CodexSettingsPageTitle("Search results")
            VStack(spacing: 0) {
                ForEach(searchMatches) { route in
                    Button {
                        selectedRoute = route
                        searchText = ""
                    } label: {
                        CodexSettingsReadOnlyRow(
                            title: route.title,
                            detail: route.searchTerms.prefix(3).joined(separator: " · "),
                            value: route.groupTitle,
                            systemImage: route.systemImage
                        )
                    }
                    .buttonStyle(.plain)
                }
                if searchMatches.isEmpty {
                    CodexSettingsReadOnlyRow(
                        title: "No settings found",
                        detail: "Try a different search term.",
                        value: nil,
                        systemImage: "magnifyingglass"
                    )
                }
            }
            .settingsPanel(theme: theme)
        }
    }

    private var groupedRoutes: [(title: String, routes: [CodexSettingsRoute])] {
        let routes = filteredRoutes
        let groupOrder = ["Personal", "Coding", "Integrations", "CodexCore"]
        return groupOrder.compactMap { group in
            let groupRoutes = routes.filter { $0.groupTitle == group }
            return groupRoutes.isEmpty ? nil : (group, groupRoutes)
        }
    }

    private var filteredRoutes: [CodexSettingsRoute] {
        guard !normalizedSearchText.isEmpty else { return supportedRoutes }
        return searchMatches
    }

    private var searchMatches: [CodexSettingsRoute] {
        guard !normalizedSearchText.isEmpty else { return supportedRoutes }
        return supportedRoutes.filter { route in
            ([route.title, route.groupTitle] + route.searchTerms)
                .contains { $0.localizedCaseInsensitiveContains(normalizedSearchText) }
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var supportedRoutes: [CodexSettingsRoute] {
        CodexSettingsRoute.availableRoutes.filter { $0 != .runtime || runtimeFeatures != nil }
    }

    private var effectiveApprovalOptions: [CodexApprovalSelection] {
        managedPolicyRequirements?.narrowApprovalOptions(approvalOptions)
            ?? approvalOptions
    }
}

public struct CodexSettingsPageTitle: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(theme.fonts.routeTitle)
            .foregroundStyle(theme.colors.textPrimary)
    }
}

public struct CodexSettingsGeneralPage: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding var approvalSelection: CodexApprovalSelection
    let approvalOptions: [CodexApprovalSelection]
    let managedPolicyRequirements: CodexManagedPolicyRequirements?
    @Binding var modelSelection: CodexModelSelection
    let modelOptions: [CodexModelSelection]
    @Binding var reasoningSelection: CodexReasoningSelection
    @Binding var isBottomPanelVisible: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CodexSettingsPageTitle("General")
            VStack(spacing: 0) {
                CodexSettingsApprovalRow(selection: $approvalSelection, options: approvalOptions)
                CodexSettingsModelRow(selection: $modelSelection, options: modelOptions)
                CodexSettingsReasoningRow(
                    selection: $reasoningSelection,
                    options: modelSelection.supportedReasoning
                )
            }
            .settingsPanel(theme: theme)
            if let managedPolicyRequirements, managedPolicyRequirements.isManaged {
                CodexManagedPolicyNotice(requirements: managedPolicyRequirements)
            }
        }
    }
}

public struct CodexSettingsProfilePage: View {
    @Environment(\.codexAgentTheme) private var theme

    let accountSummary: CodexAccountMenuSummary
    let serverName: String?

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CodexSettingsPageTitle("Profile")
            VStack(spacing: 0) {
                CodexSettingsReadOnlyRow(
                    title: accountSummary.displayName,
                    detail: "Signed in account",
                    value: accountSummary.detail,
                    systemImage: "person.crop.circle.fill"
                )
                CodexSettingsReadOnlyRow(
                    title: "Server",
                    detail: "Current app-server connection",
                    value: serverName ?? "Unavailable",
                    systemImage: "server.rack"
                )
            }
            .settingsPanel(theme: theme)
        }
    }
}

public struct CodexSettingsConfigurationPage: View {
    @Environment(\.codexAgentTheme) private var theme

    let metadata: CodexAboutMetadata
    let approvalSelection: CodexApprovalSelection
    @Binding var newThreadHistoryMode: CodexNewThreadHistoryMode

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CodexSettingsPageTitle("Configuration")
            VStack(spacing: 0) {
                CodexSettingsReadOnlyRow(
                    title: "Approval policy",
                    detail: "Current composer permission mode",
                    value: approvalSelection.displayName,
                    systemImage: "lock.shield"
                )
                CodexSettingsReadOnlyRow(
                    title: "Sandbox",
                    detail: "Derived from the active permission mode",
                    value: approvalSelection.sandbox.displayName,
                    systemImage: "shippingbox"
                )
                CodexSettingsMenuRow(
                    title: "New chat history",
                    detail: newThreadHistoryMode.detail,
                    value: newThreadHistoryMode.displayName
                ) {
                    ForEach(CodexNewThreadHistoryMode.allCases) { mode in
                        Button(mode.displayName) { newThreadHistoryMode = mode }
                    }
                }
                CodexSettingsReadOnlyRow(
                    title: "Workspace dependencies",
                    detail: "Bundled dependency runtime version",
                    value: metadata.versionLine,
                    systemImage: "archivebox"
                )
            }
            .settingsPanel(theme: theme)
        }
    }
}

private extension Sandbox {
    var displayName: String {
        switch self {
        case .readOnly:
            return "Read only"
        case .workspaceWrite:
            return "Workspace write"
        case .fullAccess:
            return "Full access"
        }
    }
}

public struct CodexSettingsIntegrationsPage: View {
    @Environment(\.codexAgentTheme) private var theme

    let mcpServers: [CodexMCPServerStatus]
    let isLoadingMCPServers: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CodexSettingsPageTitle("Integrations")
            VStack(spacing: 0) {
                CodexSettingsReadOnlyRow(
                    title: "MCP servers",
                    detail: isLoadingMCPServers ? "Loading configured servers" : "Configured external tools and data sources",
                    value: isLoadingMCPServers ? "Loading" : "\(mcpServers.count)",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                ForEach(mcpServers.prefix(6)) { server in
                    CodexSettingsReadOnlyRow(
                        title: server.displayName,
                        detail: server.inventorySummary,
                        value: server.startupStatus ?? server.authStatusLabel,
                        systemImage: "server.rack"
                    )
                }
                CodexSettingsDisabledRow(
                    title: "Browser",
                    detail: "Let CodexCore control the in-app browser",
                    reason: "Use the composer add menu for now"
                )
                CodexSettingsDisabledRow(
                    title: "Computer use",
                    detail: "Let CodexCore control apps on your computer",
                    reason: "Use the composer add menu for now"
                )
            }
            .settingsPanel(theme: theme)
        }
    }
}

public struct CodexSettingsThreadSectionsPage: View {
    public static let pinnedSectionID = "01984de2-8f74-7c91-a3b2-5c5e937cf318"

    @Environment(\.codexAgentTheme) private var theme
    @State private var editingSectionID: String?
    @State private var draftName = ""
    @State private var draftIcon = ""
    @State private var draftColor = ""
    @State private var pendingDelete: CodexSchemaThreadSection?

    let sections: [CodexSchemaThreadSection]
    let isLoading: Bool
    let errorMessage: String?
    let onRefresh: (() -> Void)?
    let onCreate: ((String, CodexSchemaThreadSectionAppearance?) -> Void)?
    let onUpdate: ((String, String, CodexAppServerOptionalField<CodexSchemaThreadSectionAppearance>) -> Void)?
    let onDelete: ((String) -> Void)?

    public init(
        sections: [CodexSchemaThreadSection],
        isLoading: Bool,
        errorMessage: String?,
        onRefresh: (() -> Void)? = nil,
        onCreate: ((String, CodexSchemaThreadSectionAppearance?) -> Void)? = nil,
        onUpdate: ((String, String, CodexAppServerOptionalField<CodexSchemaThreadSectionAppearance>) -> Void)? = nil,
        onDelete: ((String) -> Void)? = nil
    ) {
        self.sections = sections
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onRefresh = onRefresh
        self.onCreate = onCreate
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                CodexSettingsPageTitle("Chat sections")
                Spacer()
                Button { onRefresh?() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading || onRefresh == nil)
            }

            VStack(spacing: 0) {
                if sections.isEmpty {
                    CodexSettingsReadOnlyRow(
                        title: isLoading ? "Loading sections" : "No custom sections",
                        detail: errorMessage ?? "Create a synchronized section below.",
                        value: nil,
                        systemImage: "rectangle.3.group"
                    )
                } else {
                    ForEach(sections, id: \.id) { section in
                        sectionRow(section)
                    }
                }
            }
            .settingsPanel(theme: theme)

            editor
        }
        .confirmationDialog(
            "Delete section?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDelete {
                Button("Delete \(pendingDelete.name)", role: .destructive) {
                    onDelete?(pendingDelete.id)
                    self.pendingDelete = nil
                    clearEditor()
                }
            }
        } message: {
            Text("Chats return to the unsectioned list. No chat history is deleted.")
        }
    }

    private func sectionRow(_ section: CodexSchemaThreadSection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: CodexThreadSectionAppearanceStyle.systemImage(section.appearance?.icon))
                .foregroundStyle(CodexThreadSectionAppearanceStyle.color(
                    section.appearance?.color,
                    fallback: theme.colors.accent
                ))
                .frame(width: 24)
            CodexSettingsRowLabel(
                title: section.name,
                detail: appearanceDescription(section.appearance),
                isEnabled: true
            )
            Spacer()
            if section.id != Self.pinnedSectionID {
                Button("Edit") { beginEditing(section) }
                    .buttonStyle(.plain)
                Button {
                    pendingDelete = section
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.textTertiary)
                .accessibilityLabel("Delete \(section.name)")
            } else {
                Text("Built in")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }
        }
        .settingsRowFrame()
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editingSectionID == nil ? "New section" : "Edit section")
                .font(theme.fonts.panelTitle)
            TextField("Section name", text: $draftName)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                appearancePicker(
                    title: "Icon",
                    selection: $draftIcon,
                    options: CodexThreadSectionAppearanceStyle.iconOptions
                )
                appearancePicker(
                    title: "Color",
                    selection: $draftColor,
                    options: CodexThreadSectionAppearanceStyle.colorOptions
                )
                Spacer()
                if editingSectionID != nil {
                    Button("Cancel") { clearEditor() }
                }
                Button(editingSectionID == nil ? "Create" : "Save") {
                    saveEditor()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .settingsPanel(theme: theme)
    }

    private func appearancePicker(
        title: String,
        selection: Binding<String>,
        options: [String]
    ) -> some View {
        let values = options + (selection.wrappedValue.isEmpty || options.contains(selection.wrappedValue)
            ? [] : [selection.wrappedValue])
        return Picker(title, selection: selection) {
            Text("None").tag("")
            ForEach(values, id: \.self) { Text($0.capitalized).tag($0) }
        }
        .frame(width: 150)
    }

    private func beginEditing(_ section: CodexSchemaThreadSection) {
        editingSectionID = section.id
        draftName = section.name
        draftIcon = section.appearance?.icon ?? ""
        draftColor = section.appearance?.color ?? ""
    }

    private func saveEditor() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let appearance = appearanceValue
        if let editingSectionID {
            let field: CodexAppServerOptionalField<CodexSchemaThreadSectionAppearance> =
                appearance.map { .value($0) } ?? .null
            onUpdate?(editingSectionID, name, field)
        } else {
            onCreate?(name, appearance)
        }
        clearEditor()
    }

    private var appearanceValue: CodexSchemaThreadSectionAppearance? {
        let icon = draftIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = draftColor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !icon.isEmpty || !color.isEmpty else { return nil }
        return .init(
            color: color.isEmpty ? nil : color,
            icon: icon.isEmpty ? nil : icon
        )
    }

    private func clearEditor() {
        editingSectionID = nil
        draftName = ""
        draftIcon = ""
        draftColor = ""
    }

    private func appearanceDescription(_ appearance: CodexSchemaThreadSectionAppearance?) -> String {
        let values = [appearance?.icon, appearance?.color].compactMap { $0 }
        return values.isEmpty ? "Default appearance" : values.joined(separator: " · ")
    }
}

public struct CodexSettingsAboutPage: View {
    @Environment(\.codexAgentTheme) private var theme

    let metadata: CodexAboutMetadata
    let diagnostics: CodexSchemaServerDiagnosticsResponse?
    let isLoadingDiagnostics: Bool
    let diagnosticsError: String?
    let onRefreshDiagnostics: (() -> Void)?

    public init(
        metadata: CodexAboutMetadata,
        diagnostics: CodexSchemaServerDiagnosticsResponse? = nil,
        isLoadingDiagnostics: Bool = false,
        diagnosticsError: String? = nil,
        onRefreshDiagnostics: (() -> Void)? = nil
    ) {
        self.metadata = metadata
        self.diagnostics = diagnostics
        self.isLoadingDiagnostics = isLoadingDiagnostics
        self.diagnosticsError = diagnosticsError
        self.onRefreshDiagnostics = onRefreshDiagnostics
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CodexSettingsPageTitle("About")
            VStack(spacing: 0) {
                CodexSettingsReadOnlyRow(
                    title: metadata.appName,
                    detail: metadata.copyright,
                    value: metadata.versionLine,
                    systemImage: "app"
                )
                CodexSettingsReadOnlyRow(
                    title: "Server",
                    detail: "Connected app-server",
                    value: metadata.serverName ?? "Unavailable",
                    systemImage: "server.rack"
                )
            }
            .settingsPanel(theme: theme)

            HStack {
                CodexSettingsPageTitle("Runtime diagnostics")
                Spacer()
                Button {
                    onRefreshDiagnostics?()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingDiagnostics || onRefreshDiagnostics == nil)
            }
            VStack(spacing: 0) {
                if let diagnostics {
                    CodexSettingsReadOnlyRow(
                        title: "App-server process",
                        detail: "Current process snapshot; values refresh only on request",
                        value: "PID \(diagnostics.process.id)",
                        systemImage: "cpu"
                    )
                    CodexSettingsReadOnlyRow(
                        title: "Resident memory",
                        detail: "Pages currently resident in physical memory",
                        value: Self.memoryString(diagnostics.process.residentMemoryBytes),
                        systemImage: "memorychip"
                    )
                    CodexSettingsReadOnlyRow(
                        title: "Physical footprint",
                        detail: "macOS process footprint reported by the runtime",
                        value: Self.memoryString(diagnostics.process.physicalFootprintBytes),
                        systemImage: "gauge.with.dots.needle.67percent"
                    )
                    ForEach(diagnostics.gauges.sorted(by: { $0.name < $1.name }), id: \.name) { gauge in
                        CodexSettingsReadOnlyRow(
                            title: gauge.name,
                            detail: gauge.name == "app.requests.in_flight"
                                ? "Includes this diagnostics request"
                                : "Runtime diagnostic gauge",
                            value: String(gauge.value),
                            systemImage: "chart.bar"
                        )
                    }
                } else if let diagnosticsError {
                    CodexSettingsReadOnlyRow(
                        title: "Diagnostics unavailable",
                        detail: diagnosticsError,
                        value: nil,
                        systemImage: "exclamationmark.triangle"
                    )
                } else {
                    CodexSettingsReadOnlyRow(
                        title: isLoadingDiagnostics ? "Reading diagnostics" : "Diagnostics not loaded",
                        detail: "Diagnostics are fetched only while About is open",
                        value: isLoadingDiagnostics ? "Loading" : nil,
                        systemImage: "waveform.path.ecg"
                    )
                }
            }
            .settingsPanel(theme: theme)
        }
    }

    static func memoryString(_ bytes: Int?) -> String {
        guard let bytes else { return "Unavailable" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(max(0, bytes)),
            countStyle: .memory
        )
    }
}

public struct CodexAppearanceSettingsView: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding private var settings: CodexAppearanceSettings

    public init(settings: Binding<CodexAppearanceSettings>) {
        self._settings = settings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CodexSettingsPageTitle("Appearance")
            CodexThemePresetPicker(preset: $settings.preset, accentHue: $settings.accentHue)
            VStack(spacing: 0) {
                CodexAppearanceModeRow(mode: $settings.appearanceMode)
                CodexSettingsSliderRow(
                    title: "UI font size",
                    detail: "Adjust the base size used across CodexCore, including the sidebar",
                    value: $settings.uiFontSize,
                    range: CodexAppearanceSettings.uiFontSizeRange,
                    suffix: "px"
                )
                CodexFontFamilyPickerRow(
                    title: "App font",
                    detail: "Font for chat, messages, and interface text",
                    curated: CodexSystemFonts.curatedText,
                    allFamilies: CodexSystemFonts.allTextFamilies,
                    family: $settings.textFontFamily
                )
                CodexFontFamilyPickerRow(
                    title: "Monospace font",
                    detail: "Font for code blocks, diffs, and inline code",
                    curated: CodexSystemFonts.curatedMono,
                    allFamilies: CodexSystemFonts.monospacedFamilies,
                    family: $settings.monoFontFamily
                )
                CodexFontPreviewRow(
                    textFamily: settings.textFontFamily,
                    monoFamily: settings.monoFontFamily
                )
                CodexSettingsEnumRow(
                    title: "Reduce motion",
                    detail: "Reduce animations in CodexCore",
                    selection: $settings.reduceMotion,
                    offTitle: "Off",
                    onTitle: "On"
                )
            }
            .settingsPanel(theme: theme)
        }
    }
}

public struct CodexFontFamilyPickerRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let detail: String
    let curated: [String]
    let allFamilies: [String]
    @Binding private var family: String?

    public init(title: String, detail: String, curated: [String], allFamilies: [String], family: Binding<String?>) {
        self.title = title
        self.detail = detail
        self.curated = curated
        self.allFamilies = allFamilies
        self._family = family
    }

    public var body: some View {
        HStack(spacing: 18) {
            CodexSettingsRowLabel(title: title, detail: detail, isEnabled: true)
            Spacer()
            Menu {
                choice(nil, label: CodexSystemFonts.systemLabel)
                if !curated.isEmpty {
                    Divider()
                    ForEach(curated, id: \.self) { choice($0, label: $0) }
                }
                Divider()
                Menu("All fonts") {
                    ForEach(allFamilies, id: \.self) { choice($0, label: $0) }
                }
            } label: {
                Text(family ?? CodexSystemFonts.systemLabel)
                    .lineLimit(1)
                    .frame(minWidth: 150, maxWidth: 200, alignment: .leading)
            }
            .fixedSize()
        }
        .settingsRowFrame()
    }

    @ViewBuilder
    private func choice(_ value: String?, label: String) -> some View {
        Button {
            family = value
        } label: {
            if family == value {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }
}

private struct CodexFontPreviewRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let textFamily: String?
    let monoFamily: String?

    var body: some View {
        HStack(spacing: 18) {
            CodexSettingsRowLabel(title: "Preview", detail: "Sample of the selected fonts", isEnabled: true)
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(CodexFontFamily.text(textFamily).font(size: 15))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("let total = items.reduce(0, +)  // 0123456789")
                    .font(CodexFontFamily.mono(monoFamily).font(size: 13))
                    .foregroundStyle(theme.colors.textSecondary)
            }
            .lineLimit(1)
            .frame(maxWidth: 320, alignment: .leading)
        }
        .settingsRowFrame()
    }
}

public struct CodexThemePresetPicker: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @Binding private var preset: CodexAgentThemePreset
    @Binding private var accentHue: Double?

    public init(preset: Binding<CodexAgentThemePreset>, accentHue: Binding<Double?> = .constant(nil)) {
        self._preset = preset
        self._accentHue = accentHue
    }

    /// Accent hues offered beside the family's own, in OKLCH degrees, spaced
    /// so neighbors stay distinguishable at swatch size.
    static let accentHues: [Double] = [25, 50, 85, 140, 168, 205, 240, 274, 305, 345]

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.lg) {
            VStack(alignment: .leading, spacing: theme.spacing.xxs) {
                Text("Theme")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Choose the colors and surfaces used throughout the app.")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }

            // Previews render in the current appearance, so what you see on the
            // card is what the window becomes.
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: theme.spacing.md),
                    count: 4
                ),
                spacing: theme.spacing.lg
            ) {
                ForEach(CodexAgentThemePreset.pickerCases) { option in
                    // `nativeLight` is the legacy alias of Graphite and selects its card.
                    let isSelected = (preset == .nativeLight ? .officialDark : preset) == option
                    Button {
                        withAnimation(.snappy(duration: theme.animations.snappyDuration)) { preset = option }
                    } label: {
                        VStack(alignment: .leading, spacing: theme.spacing.sm) {
                            CodexPresetSwatch(
                                preset: option,
                                isSelected: isSelected,
                                accentHue: option.supportsAccentOverride ? accentHue : nil
                            )
                            Text(option.displayName)
                                .font(theme.fonts.caption.weight(.medium))
                                .foregroundStyle(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                                .lineLimit(1)
                                .padding(.leading, 2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(option.summary)
                    .accessibilityLabel("\(option.displayName) theme. \(option.summary)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            accentRow
        }
        .settingsPanel(theme: theme)
    }

    private var accentRow: some View {
        let enabled = preset.supportsAccentOverride
        return HStack(spacing: theme.spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Accent")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textPrimary)
                Text(enabled ? "Re-hue controls and light. Contrast is kept automatically." : "\(preset.displayName) uses a fixed accent.")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }
            Spacer(minLength: theme.spacing.md)
            HStack(spacing: theme.spacing.xs + 2) {
                accentSwatch(hue: nil)
                ForEach(Self.accentHues, id: \.self) { hue in
                    accentSwatch(hue: hue)
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
        }
    }

    private func accentSwatch(hue: Double?) -> some View {
        let isSelected = accentHue == hue
        let fill = preset.palette(accentHue: hue).accent.resolved(colorScheme)
        let label = hue.map { "Accent hue \(Int($0)) degrees" } ?? "Theme accent"
        return Button {
            withAnimation(.snappy(duration: theme.animations.snappyDuration)) { accentHue = hue }
        } label: {
            ZStack {
                Circle().fill(fill)
                if hue == nil {
                    // The family's own accent is marked, so "reset" is findable.
                    Image(systemName: "sparkle")
                        .font(theme.fonts.micro)
                        .foregroundStyle(preset.palette.onAccent.resolved(colorScheme))
                }
            }
            .frame(width: 20, height: 20)
            .padding(3)
            .overlay {
                Circle()
                    .strokeBorder(isSelected ? theme.colors.textPrimary : .clear, lineWidth: 1.5)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A miniature of the window in this family: its atmosphere, a floating glass
/// sidebar, a line of transcript, and the accent on a primary control.
/// Rendered in the current appearance, so the card previews the real result.
public struct CodexPresetSwatch: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    let preset: CodexAgentThemePreset
    let isSelected: Bool
    let accentHue: Double?

    public init(preset: CodexAgentThemePreset, isSelected: Bool, accentHue: Double? = nil) {
        self.preset = preset
        self.isSelected = isSelected
        self.accentHue = accentHue
    }

    public var body: some View {
        let palette = preset.palette(accentHue: accentHue)
        let atmosphere = preset.atmosphere(accentHue: accentHue)
        let isDark = colorScheme == .dark
        let scheme = colorScheme
        let shape = RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)

        return ZStack(alignment: .topLeading) {
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0, 0], [0.55, 0], [1, 0],
                    [0, 0.48], [0.46, 0.52], [1, 0.42],
                    [0, 1], [0.6, 1], [1, 1]
                ],
                colors: atmosphere.colors(for: isDark).map(CodexColorPair.decode)
            )

            HStack(alignment: .top, spacing: 6) {
                // Sidebar pane: a frosted lift of the canvas, like the real one.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(palette.textSecondary.resolved(scheme).opacity(index == 0 ? 0.55 : 0.3))
                            .frame(width: index == 0 ? 22 : 16, height: 2.5)
                    }
                }
                .padding(6)
                .frame(width: 38, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(
                    palette.surfaceElevated.resolved(scheme).opacity(isDark ? 0.42 : 0.55),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )

                VStack(alignment: .leading, spacing: 4) {
                    Capsule()
                        .fill(palette.userBubble.resolved(scheme))
                        .frame(width: 30, height: 7)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Capsule()
                        .fill(palette.textPrimary.resolved(scheme).opacity(0.75))
                        .frame(width: 38, height: 2.5)
                    Capsule()
                        .fill(palette.textSecondary.resolved(scheme).opacity(0.6))
                        .frame(width: 28, height: 2.5)
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        Circle()
                            .fill(palette.accent.resolved(scheme))
                            .frame(width: 9, height: 9)
                    }
                    .padding(3)
                    .background(
                        palette.surfaceElevated.resolved(scheme).opacity(isDark ? 0.5 : 0.7),
                        in: Capsule()
                    )
                }
                .padding(.vertical, 2)
            }
            .padding(6)
        }
        .frame(height: 72)
        .clipShape(shape)
        .overlay { shape.strokeBorder(palette.textPrimary.resolved(scheme).opacity(0.08), lineWidth: 1) }
        .padding(3)
        .overlay {
            // Selection is concentric with the card, outside it, so the
            // preview itself is never covered.
            RoundedRectangle(cornerRadius: theme.radii.medium + 3, style: .continuous)
                .strokeBorder(isSelected ? theme.colors.accent : .clear, lineWidth: 2)
        }
    }
}

public struct CodexSettingsApprovalRow: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding var selection: CodexApprovalSelection
    let options: [CodexApprovalSelection]
    @State private var isFullAccessConfirmationPresented = false

    public var body: some View {
        CodexSettingsMenuRow(
            title: "Default permissions",
            detail: selection.detail,
            value: selection.displayName
        ) {
            ForEach(options) { option in
                Button(option.displayName) {
                    switch CodexPermissionSelectionDecision.resolve(
                        current: selection,
                        requested: option
                    ) {
                    case .apply(let selection):
                        self.selection = selection
                    case .confirmFullAccess:
                        isFullAccessConfirmationPresented = true
                    }
                }
            }
        }
        .codexFullAccessConfirmation(
            isPresented: $isFullAccessConfirmationPresented,
            onConfirm: { selection = .fullAccess }
        )
    }
}

public struct CodexManagedPolicyNotice: View {
    @Environment(\.codexAgentTheme) private var theme

    public let requirements: CodexManagedPolicyRequirements

    public init(requirements: CodexManagedPolicyRequirements) {
        self.requirements = requirements
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "building.2.crop.circle")
                .font(theme.fonts.label)
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(requirements.noticeTitle)
                    .font(theme.fonts.label.weight(.semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text(requirements.noticeDetail)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.colors.surfaceElevated.opacity(0.36), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(requirements.noticeTitle). \(requirements.noticeDetail)")
    }
}

public struct CodexSettingsModelRow: View {
    @Binding var selection: CodexModelSelection
    let options: [CodexModelSelection]

    public var body: some View {
        CodexSettingsMenuRow(
            title: "Model",
            detail: selection.detail ?? "Default model for new turns",
            value: selection.displayName
        ) {
            ForEach(options.isEmpty ? [.appServerDefault] : options) { option in
                Button(option.displayName) { selection = option }
            }
        }
    }
}

public struct CodexSettingsReasoningRow: View {
    @Binding var selection: CodexReasoningSelection
    let options: [CodexReasoningSelection]

    public var body: some View {
        CodexSettingsMenuRow(
            title: "Reasoning",
            detail: "Default reasoning effort for new turns",
            value: selection.displayName
        ) {
            ForEach(options.isEmpty ? CodexReasoningSelection.defaultOptions : options) { option in
                Button(option.displayName) { selection = option }
            }
        }
    }
}

public struct CodexSettingsMenuRow<MenuContent: View>: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let detail: String
    let value: String
    @ViewBuilder let menuContent: () -> MenuContent

    public var body: some View {
        HStack(spacing: 18) {
            CodexSettingsRowLabel(title: title, detail: detail, isEnabled: true)
            Spacer(minLength: 12)
            Menu {
                menuContent()
            } label: {
                HStack(spacing: 8) {
                    Text(value)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(theme.fonts.caption)
                }
                .font(theme.fonts.label)
                .foregroundStyle(theme.colors.textPrimary)
                .padding(.horizontal, 11)
                .frame(minWidth: 142, minHeight: 30)
                .background(theme.colors.surfaceSunken.opacity(0.64), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .settingsRowFrame()
    }
}

public struct CodexSettingsToggleRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let detail: String?
    @Binding private var isOn: Bool

    public init(title: String, detail: String?, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            CodexSettingsRowLabel(title: title, detail: detail, isEnabled: true)
        }
        .toggleStyle(.switch)
        .settingsRowFrame()
    }
}

public struct CodexSettingsSliderRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let detail: String?
    @Binding private var value: Double
    let range: ClosedRange<Double>
    let suffix: String?

    public init(title: String, detail: String?, value: Binding<Double>, range: ClosedRange<Double>, suffix: String?) {
        self.title = title
        self.detail = detail
        self._value = value
        self.range = range
        self.suffix = suffix
    }

    public var body: some View {
        HStack(spacing: 18) {
            CodexSettingsRowLabel(title: title, detail: detail, isEnabled: true)
            Spacer(minLength: 12)
            Slider(value: $value, in: range, step: 1)
                .frame(width: 150)
            Text("\(Int(value.rounded()))\(suffix.map { " \($0)" } ?? "")")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: 52, alignment: .trailing)
        }
        .settingsRowFrame()
    }
}

public struct CodexSettingsEnumRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let detail: String
    @Binding private var selection: Bool
    let offTitle: String
    let onTitle: String

    public init(title: String, detail: String, selection: Binding<Bool>, offTitle: String, onTitle: String) {
        self.title = title
        self.detail = detail
        self._selection = selection
        self.offTitle = offTitle
        self.onTitle = onTitle
    }

    public var body: some View {
        HStack(spacing: 18) {
            CodexSettingsRowLabel(title: title, detail: detail, isEnabled: true)
            Spacer()
            Picker(title, selection: $selection) {
                Text(offTitle).tag(false)
                Text(onTitle).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 124)
        }
        .settingsRowFrame()
    }
}

/// Light / dark / follow-the-system. Separate from the theme picker because a
/// theme is a hue family that renders in both appearances, not an appearance.
public struct CodexAppearanceModeRow: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding private var mode: CodexAppearanceMode

    public init(mode: Binding<CodexAppearanceMode>) {
        self._mode = mode
    }

    public var body: some View {
        HStack(spacing: 18) {
            CodexSettingsRowLabel(
                title: "Appearance",
                detail: "Every theme renders in both light and dark",
                isEnabled: true
            )
            Spacer()
            Picker("Appearance", selection: $mode) {
                ForEach(CodexAppearanceMode.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 186)
        }
        .settingsRowFrame()
    }
}

public struct CodexSettingsTextFieldRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let detail: String
    @Binding var text: String

    public var body: some View {
        HStack(spacing: 18) {
            CodexSettingsRowLabel(title: title, detail: detail, isEnabled: true)
            Spacer(minLength: 12)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(theme.fonts.label)
                .padding(.horizontal, 10)
                .frame(width: 170, height: 30)
                .background(theme.colors.surfaceSunken.opacity(0.64), in: Capsule())
        }
        .settingsRowFrame()
    }
}

public struct CodexSettingsMultilineTextRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let detail: String
    @Binding var text: String

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CodexSettingsRowLabel(title: title, detail: detail, isEnabled: true)
            TextEditor(text: $text)
                .font(theme.fonts.caption)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72)
                .padding(8)
                .background(theme.colors.surfaceSunken.opacity(0.64), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        }
        .padding(.vertical, 10)
    }
}

public struct CodexSettingsDisabledRow: View {
    let title: String
    let detail: String
    let reason: String

    public var body: some View {
        CodexSettingsReadOnlyRow(
            title: title,
            detail: detail,
            value: reason,
            systemImage: "lock"
        )
        .opacity(0.56)
        .accessibilityAddTraits(.isStaticText)
    }
}

public struct CodexSettingsReadOnlyRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let detail: String?
    let value: String?
    let systemImage: String?

    public init(title: String, detail: String?, value: String?, systemImage: String? = nil) {
        self.title = title
        self.detail = detail
        self.value = value
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(width: 20)
            }
            CodexSettingsRowLabel(title: title, detail: detail, isEnabled: true)
            Spacer(minLength: 12)
            if let value {
                Text(value)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .settingsRowFrame()
    }
}

public struct CodexSettingsRowLabel: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let detail: String?
    let isEnabled: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(theme.fonts.label)
                .foregroundStyle(isEnabled ? theme.colors.textPrimary : theme.colors.textTertiary)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(2)
            }
        }
    }
}

public struct CodexSettingsDisabledPill: View {
    @Environment(\.codexAgentTheme) private var theme
    let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(theme.fonts.caption)
            .foregroundStyle(theme.colors.textTertiary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(theme.colors.surfaceSunken.opacity(0.34), in: Capsule())
            .help("Not available in CodexCore yet")
    }
}

private extension View {
    func settingsSidebarRow(theme: CodexAgentTheme, isSelected: Bool) -> some View {
        self
            .font(theme.fonts.label)
            .foregroundStyle(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .background(isSelected ? theme.colors.surfaceElevated.opacity(0.60) : .clear, in: Capsule())
    }

    func settingsBackButton(theme: CodexAgentTheme) -> some View {
        self
            .font(theme.fonts.label)
            .foregroundStyle(theme.colors.textSecondary)
            .frame(height: 30)
            .padding(.horizontal, 10)
    }

    func settingsPanel(theme: CodexAgentTheme) -> some View {
        self
            .padding(16)
            .background(
                theme.colors.surfaceElevated.opacity(theme.effects.glassOpacity),
                in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
    }

    func settingsRowFrame() -> some View {
        self
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }
}
