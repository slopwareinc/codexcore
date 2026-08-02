import AppKit
import SwiftUI

public struct CodexPluginRouteView: View {
    @Environment(\.codexAgentTheme) private var theme

    public let plugins: [CodexPluginSummary]
    public let skills: [CodexSkillSummary]
    public let mcpServers: [CodexMCPServerStatus]
    public let isLoadingPlugins: Bool
    public let isLoadingSkills: Bool
    public let pluginErrorMessage: String?
    public let skillErrorMessage: String?
    public let pluginLoadErrors: [String]
    public let controlPlanePhases: [CodexIntegrationControlPlaneSurface: CodexIntegrationControlPlanePhase]
    public let launcherTarget: CodexComposerPluginLauncher?
    public let onRefresh: () -> Void
    public let onAction: (CodexPluginRouteAction) -> Void
    public let onControlPlaneRequest: (CodexIntegrationControlPlaneRequest) -> Void

    @State private var primaryTab: CodexPluginRoutePrimaryTab = .marketplace
    @State private var manageTab: CodexPluginManageTab = .plugins
    @State private var browseScope: CodexPluginBrowseScope = .openAI
    @State private var searchQuery = ""
    @State private var selectedPluginID: String?
    @State private var selectedSkillID: String?
    @State private var isShowingDetail = false
    @State private var isShowingMarketplaceSheet = false
    @State private var marketplaceSource = ""

    public init(
        plugins: [CodexPluginSummary],
        skills: [CodexSkillSummary],
        mcpServers: [CodexMCPServerStatus],
        isLoadingPlugins: Bool = false,
        isLoadingSkills: Bool = false,
        pluginErrorMessage: String? = nil,
        skillErrorMessage: String? = nil,
        pluginLoadErrors: [String] = [],
        controlPlanePhases: [CodexIntegrationControlPlaneSurface: CodexIntegrationControlPlanePhase] = [:],
        launcherTarget: CodexComposerPluginLauncher? = nil,
        onRefresh: @escaping () -> Void,
        onAction: @escaping (CodexPluginRouteAction) -> Void,
        onControlPlaneRequest: @escaping (CodexIntegrationControlPlaneRequest) -> Void = { _ in }
    ) {
        self.plugins = plugins
        self.skills = skills
        self.mcpServers = mcpServers
        self.isLoadingPlugins = isLoadingPlugins
        self.isLoadingSkills = isLoadingSkills
        self.pluginErrorMessage = pluginErrorMessage
        self.skillErrorMessage = skillErrorMessage
        self.pluginLoadErrors = pluginLoadErrors
        self.controlPlanePhases = controlPlanePhases
        self.launcherTarget = launcherTarget
        self.onRefresh = onRefresh
        self.onAction = onAction
        self.onControlPlaneRequest = onControlPlaneRequest
    }

    private var routeState: CodexPluginRouteState {
        CodexPluginRouteState(
            plugins: plugins,
            skills: skills,
            mcpServers: mcpServers,
            primaryTab: primaryTab,
            manageTab: manageTab,
            browseScope: browseScope,
            searchQuery: searchQuery,
            selectedPluginID: selectedPluginID,
            selectedSkillID: selectedSkillID,
            launcherTarget: launcherTarget
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            routeToolbar
            Divider().overlay(theme.colors.border.opacity(0.7))
            Group {
                if isShowingDetail, let detail = routeState.selectedDetail {
                    detailPage(detail)
                } else if primaryTab == .manage {
                    managePage
                } else {
                    browsePage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.colors.surfaceSunken)
        .sheet(isPresented: $isShowingMarketplaceSheet) { marketplaceSheet }
        .onAppear(perform: seedOrApplyLauncher)
        .onChange(of: plugins.map(\.id)) { _, _ in seedOrApplyLauncher() }
        .onChange(of: skills.map(\.id)) { _, _ in seedOrApplyLauncher() }
        .onChange(of: launcherTarget) { _, _ in seedOrApplyLauncher() }
    }

    private var routeToolbar: some View {
        HStack(spacing: 4) {
            toolbarTab("Plugins", selected: primaryTab != .skills) {
                primaryTab = .marketplace
                isShowingDetail = false
            }
            toolbarTab("Skills", selected: primaryTab == .skills) {
                primaryTab = .skills
                isShowingDetail = false
            }

            Spacer()

            if isLoadingPlugins || isLoadingSkills || controlPlanePhases.values.contains(where: \.isLoading) {
                CodexSpinner(size: .small)
                    .padding(.trailing, 6)
            }

            Menu {
                Button("Create plugin") {
                    onAction(.tryInChat(prompt: "Help me create a Codex plugin."))
                }
                Button("Create skill") {
                    onAction(.tryInChat(prompt: "Help me create a Codex skill."))
                }
                Divider()
                Button("Add marketplace") { isShowingMarketplaceSheet = true }
                Button("Upgrade marketplaces") {
                    onControlPlaneRequest(.marketplaceUpgrade(.init()))
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                    Image(systemName: "chevron.down")
                        .font(theme.fonts.micro)
                }
                .frame(width: 48, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(primaryTab == .skills ? "Create skill" : "Create plugin")
            .accessibilityLabel("Create or add integration")

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.colors.textSecondary)
            .help("Refresh plugins and skills")
            .accessibilityLabel("Refresh plugins and skills")
        }
        .font(theme.fonts.label)
        .padding(.horizontal, 20)
        .frame(height: 54)
    }

    private func toolbarTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(selected ? theme.colors.textPrimary : theme.colors.textSecondary)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(
                    selected ? theme.colors.surfaceElevated.opacity(0.9) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private var browsePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeading
                searchField(placeholder: "Search plugins and skills")
                statusMessages

                if primaryTab == .skills {
                    skillsCatalog
                } else {
                    installedStrip
                    scopePicker
                    pluginCatalog
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .padding(.bottom, 60)
        }
    }

    private var pageHeading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(primaryTab == .skills ? "Skills" : "Plugins")
                .font(theme.fonts.routeTitle)
                .foregroundStyle(theme.colors.textPrimary)
            Text(primaryTab == .skills
                 ? "Extend Codex's capabilities with task-specific skills"
                 : "Work with Codex across your favorite tools")
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textSecondary)
        }
    }

    private func searchField(placeholder: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.colors.textTertiary)
            TextField(placeholder, text: $searchQuery)
                .textFieldStyle(.plain)
                .font(theme.fonts.chat)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.textTertiary)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 42)
        .background(theme.colors.surfaceElevated.opacity(0.8), in: Capsule())
        .overlay(Capsule().stroke(theme.colors.border.opacity(0.65), lineWidth: 1))
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let pluginErrorMessage { statusBanner(pluginErrorMessage, color: theme.colors.danger) }
        if let skillErrorMessage { statusBanner(skillErrorMessage, color: theme.colors.danger) }
        ForEach(pluginLoadErrors, id: \.self) { statusBanner($0, color: theme.colors.warning) }
        ForEach(controlPlaneMessages, id: \.self) { statusBanner($0, color: theme.colors.warning) }
    }

    private var controlPlaneMessages: [String] {
        CodexIntegrationControlPlaneSurface.allCases.compactMap { surface in
            switch controlPlanePhases[surface] {
            case .failed(let message): return "\(surface.rawValue.capitalized): \(message)"
            case .permissionRequired(_, let message): return message
            case .idle, .loading, .loaded, nil: return nil
            }
        }
    }

    private func statusBanner(_ message: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(theme.fonts.caption)
        .foregroundStyle(color)
        .padding(11)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var installedStrip: some View {
        let installed = plugins.filter(\.installed)
        if !installed.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Installed").font(theme.fonts.sheetTitle)
                    Spacer()
                    Button("Manage") {
                        primaryTab = .manage
                        manageTab = .plugins
                        isShowingDetail = false
                    }
                    .buttonStyle(.plain)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                }
                Divider().overlay(theme.colors.border.opacity(0.5))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 11) {
                        ForEach(installed) { plugin in
                            Button {
                                select(plugin)
                            } label: {
                                IntegrationIcon(plugin: plugin, size: 42)
                            }
                            .buttonStyle(.plain)
                            .help(plugin.displayName)
                            .accessibilityLabel(plugin.displayName)
                        }
                    }
                }
            }
        }
    }

    private var scopePicker: some View {
        HStack(spacing: 5) {
            ForEach(CodexPluginBrowseScope.allCases, id: \.self) { scope in
                Button {
                    browseScope = scope
                } label: {
                    Text(scope.title)
                        .font(theme.fonts.caption)
                        .foregroundStyle(browseScope == scope ? theme.colors.textPrimary : theme.colors.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(
                            browseScope == scope ? theme.colors.surfaceElevated : .clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var pluginCatalog: some View {
        let sections = routeState.marketplaceSections.filter { $0.title != "Installed" }
        if sections.isEmpty {
            emptyState("No plugins found", symbol: "puzzlepiece.extension")
        } else {
            VStack(alignment: .leading, spacing: 30) {
                ForEach(sections) { section in
                    CatalogSection(title: section.title) {
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible(), spacing: 28)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(section.plugins) { plugin in
                                MarketplacePluginRow(
                                    plugin: plugin,
                                    onOpen: { select(plugin) },
                                    onAction: onAction
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var skillsCatalog: some View {
        let sections = routeState.skillSections
        if sections.isEmpty {
            emptyState("No skills found", symbol: "hammer")
        } else {
            VStack(alignment: .leading, spacing: 34) {
                ForEach(sections) { section in
                    CatalogSection(title: section.title) {
                        VStack(spacing: 3) {
                            ForEach(section.skills) { skill in
                                SkillBrowseRow(skill: skill) { select(skill) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var managePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 9) {
                    Button("Plugins") {
                        primaryTab = .marketplace
                        isShowingDetail = false
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.textTertiary)
                    Text("Manage").foregroundStyle(theme.colors.textPrimary)
                }
                .font(theme.fonts.label)

                HStack(alignment: .center, spacing: 18) {
                    manageTabs
                    Spacer()
                    searchField(placeholder: manageSearchPlaceholder)
                        .frame(width: 260)
                }

                statusMessages

                Group {
                    if manageTab == .skills {
                        VStack(spacing: 2) {
                            ForEach(routeState.visibleSkills) { skill in
                                ManagedSkillRow(skill: skill, onOpen: { select(skill) }, onAction: onAction)
                            }
                        }
                    } else if manageTab == .mcps {
                        VStack(spacing: 2) {
                            if mcpServers.isEmpty { emptyState("No MCP servers connected", symbol: "server.rack") }
                            ForEach(mcpServers) { server in
                                ManagedMCPRow(server: server, onControlPlaneRequest: onControlPlaneRequest)
                            }
                        }
                    } else {
                        VStack(spacing: 2) {
                            if routeState.visiblePlugins.isEmpty { emptyState("No managed plugins", symbol: "puzzlepiece.extension") }
                            ForEach(routeState.visiblePlugins) { plugin in
                                ManagedPluginRow(plugin: plugin, onOpen: { select(plugin) }, onAction: onAction)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .padding(.bottom, 60)
        }
    }

    private var manageTabs: some View {
        HStack(spacing: 4) {
            ForEach(routeState.manageCounts) { count in
                Button {
                    manageTab = count.tab
                    searchQuery = ""
                } label: {
                    HStack(spacing: 5) {
                        Text(count.tab.title)
                        Text("\(count.count)").foregroundStyle(theme.colors.textTertiary)
                    }
                    .font(theme.fonts.caption)
                    .foregroundStyle(manageTab == count.tab ? theme.colors.textPrimary : theme.colors.textSecondary)
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(
                        manageTab == count.tab ? theme.colors.surfaceElevated : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var manageSearchPlaceholder: String {
        switch manageTab {
        case .plugins: "Search plugins"
        case .apps: "Search apps"
        case .mcps: "Search MCP servers"
        case .skills: "Search skills"
        }
    }

    private func detailPage(_ detail: CodexPluginRouteDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Button {
                    isShowingDetail = false
                } label: {
                    Label(primaryTab == .manage ? "Manage" : (primaryTab == .skills ? "Skills" : "Plugins"), systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)

                statusMessages

                HStack(alignment: .top, spacing: 18) {
                    detailIcon(detail)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(detail.title).font(theme.fonts.routeTitle)
                        Text(detail.detail)
                            .font(theme.fonts.chat)
                            .foregroundStyle(theme.colors.textSecondary)
                        Text(detail.statusLabel)
                            .font(theme.fonts.caption)
                            .foregroundStyle(detail.isEnabled ? theme.colors.success : theme.colors.textTertiary)
                    }
                    Spacer()
                    detailActions(detail)
                }

                if let prompt = detail.prompt, let action = detail.tryInChatAction {
                    Button { onAction(action) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                            Text(prompt).lineLimit(2)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textPrimary)
                        .padding(14)
                        .background(theme.colors.surfaceElevated.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.colors.border.opacity(0.7)))
                    }
                    .buttonStyle(.plain)
                }

                Text(detail.description)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineSpacing(4)

                detailSection("Capabilities", rows: detail.capabilities)
                detailSection("Information", rows: detail.metadata)
                detailSection("Links", rows: detail.legalLinks)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 26)
            .padding(.bottom, 60)
        }
    }

    @ViewBuilder
    private func detailIcon(_ detail: CodexPluginRouteDetail) -> some View {
        switch detail.kind {
        case .plugin(let target):
            if let plugin = plugins.first(where: { $0.id == target.id }) {
                IntegrationIcon(plugin: plugin, size: 64)
            }
        case .skill:
            IntegrationIcon(title: detail.title, symbol: "hammer", size: 64)
        case .boundary:
            IntegrationIcon(title: detail.title, symbol: "puzzlepiece.extension", size: 64)
        }
    }

    @ViewBuilder
    private func detailActions(_ detail: CodexPluginRouteDetail) -> some View {
        HStack(spacing: 8) {
            if detail.canInstall, let action = detail.primaryAction {
                Button("Add") { onAction(action) }.buttonStyle(.borderedProminent)
            } else if detail.canToggleEnabled {
                Button(detail.isEnabled ? "Disable" : "Enable") {
                    switch detail.kind {
                    case .plugin(let target): onAction(.setPluginEnabled(target, enabled: !detail.isEnabled))
                    case .skill(let target): onAction(.setSkillEnabled(target, enabled: !detail.isEnabled))
                    case .boundary: break
                    }
                }
                .buttonStyle(.bordered)
            }
            if let action = detail.tryInChatAction {
                Button("Try in chat") { onAction(action) }.buttonStyle(.borderedProminent)
            }
            if detail.canUninstall, let action = detail.primaryAction {
                Menu {
                    Button("Uninstall", role: .destructive) { onAction(action) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
    }

    @ViewBuilder
    private func detailSection(_ title: String, rows: [String]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(theme.fonts.sheetTitle)
                Divider().overlay(theme.colors.border.opacity(0.5))
                ForEach(rows, id: \.self) { row in
                    Text(row)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func emptyState(_ title: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 24))
            Text(title).font(theme.fonts.label)
        }
        .foregroundStyle(theme.colors.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var marketplaceSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add plugin marketplace").font(theme.fonts.sheetTitle)
            Text("Add from a GitHub repository, Git URL, or local folder.")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
            TextField("openai/plugins or git@github.com:org/repo.git", text: $marketplaceSource)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { isShowingMarketplaceSheet = false }
                Button("Add") {
                    let source = marketplaceSource.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !source.isEmpty else { return }
                    onControlPlaneRequest(.marketplaceAdd(.init(source: source)))
                    marketplaceSource = ""
                    isShowingMarketplaceSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(marketplaceSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .codexAgentTheme(theme)
    }

    private func select(_ plugin: CodexPluginSummary) {
        selectedPluginID = plugin.id
        selectedSkillID = nil
        isShowingDetail = true
    }

    private func select(_ skill: CodexSkillSummary) {
        selectedSkillID = skill.id
        selectedPluginID = nil
        isShowingDetail = true
    }

    private func seedOrApplyLauncher() {
        if let target = launcherTarget {
            primaryTab = target.itemID == .browser ? .manage : .marketplace
            manageTab = .plugins
            searchQuery = target.searchQuery
            selectedSkillID = nil
            selectedPluginID = plugins.first { plugin in
                let preferred = target.preferredPluginNames.map { $0.lowercased() }
                return [plugin.name, plugin.displayName, plugin.id]
                    .map { $0.lowercased() }
                    .contains { candidate in preferred.contains { candidate == $0 || candidate.contains($0) } }
            }?.id
            isShowingDetail = selectedPluginID != nil
            return
        }
        if selectedPluginID == nil { selectedPluginID = plugins.first?.id }
        if selectedSkillID == nil { selectedSkillID = skills.first?.id }
    }
}

private extension CodexIntegrationControlPlanePhase {
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

private struct CatalogSection<Content: View>: View {
    @Environment(\.codexAgentTheme) private var theme
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(theme.fonts.sheetTitle)
            Divider().overlay(theme.colors.border.opacity(0.45))
            content
        }
    }
}

private struct MarketplacePluginRow: View {
    @Environment(\.codexAgentTheme) private var theme
    let plugin: CodexPluginSummary
    let onOpen: () -> Void
    let onAction: (CodexPluginRouteAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                IntegrationIcon(plugin: plugin, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.displayName).font(theme.fonts.label).foregroundStyle(theme.colors.textPrimary).lineLimit(1)
                    Text(plugin.detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(2)
                }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            rowAction
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var rowAction: some View {
        let detail = CodexPluginRouteDetail(plugin: plugin)
        if detail.canInstall, let action = detail.primaryAction {
            Button("Add") { onAction(action) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else if plugin.installed {
            Image(systemName: plugin.enabled ? "checkmark" : "minus")
                .foregroundStyle(theme.colors.textTertiary)
                .frame(width: 26)
        }
    }
}

private struct SkillBrowseRow: View {
    @Environment(\.codexAgentTheme) private var theme
    let skill: CodexSkillSummary
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                IntegrationIcon(title: skill.displayName, symbol: "hammer", size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(skill.displayName).font(theme.fonts.label).foregroundStyle(theme.colors.textPrimary)
                    Text(skill.detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: skill.enabled ? "checkmark" : "minus")
                    .foregroundStyle(theme.colors.textTertiary)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ManagedPluginRow: View {
    @Environment(\.codexAgentTheme) private var theme
    let plugin: CodexPluginSummary
    let onOpen: () -> Void
    let onAction: (CodexPluginRouteAction) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    IntegrationIcon(plugin: plugin, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plugin.displayName).font(theme.fonts.label).foregroundStyle(theme.colors.textPrimary)
                        Text(plugin.detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if plugin.installPolicy == "INSTALLED_BY_DEFAULT" {
                Image(systemName: "checkmark").foregroundStyle(theme.colors.textTertiary).frame(width: 36)
            } else {
                Toggle("Plugin enabled", isOn: Binding(
                    get: { plugin.enabled },
                    set: { onAction(.setPluginEnabled(CodexPluginActionTarget(plugin: plugin), enabled: $0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ManagedSkillRow: View {
    @Environment(\.codexAgentTheme) private var theme
    let skill: CodexSkillSummary
    let onOpen: () -> Void
    let onAction: (CodexPluginRouteAction) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    IntegrationIcon(title: skill.displayName, symbol: "hammer", size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(skill.displayName).font(theme.fonts.label).foregroundStyle(theme.colors.textPrimary)
                        Text(skill.detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Toggle("Skill enabled", isOn: Binding(
                get: { skill.enabled },
                set: { onAction(.setSkillEnabled(CodexSkillActionTarget(skill: skill), enabled: $0)) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 8)
    }
}

private struct ManagedMCPRow: View {
    @Environment(\.codexAgentTheme) private var theme
    let server: CodexMCPServerStatus
    let onControlPlaneRequest: (CodexIntegrationControlPlaneRequest) -> Void

    var body: some View {
        HStack(spacing: 14) {
            IntegrationIcon(title: server.displayName, symbol: "server.rack", size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(server.displayName).font(theme.fonts.label)
                Text(server.inventorySummary).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
            }
            Spacer()
            if server.authStatus == "notLoggedIn" {
                Button("Log in") {
                    onControlPlaneRequest(.mcpOAuthLogin(.init(name: server.name)))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text(server.authStatusLabel).font(theme.fonts.caption).foregroundStyle(theme.colors.textTertiary)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct IntegrationIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let symbol: String
    let size: CGFloat
    let lightPath: String?
    let darkPath: String?
    let lightURL: String?
    let darkURL: String?

    init(plugin: CodexPluginSummary, size: CGFloat) {
        self.title = plugin.displayName
        self.symbol = Self.symbol(for: plugin.name)
        self.size = size
        self.lightPath = plugin.logoPath
        self.darkPath = plugin.logoDarkPath
        self.lightURL = plugin.logoURL
        self.darkURL = plugin.logoDarkURL
    }

    init(title: String, symbol: String, size: CGFloat) {
        self.title = title
        self.symbol = symbol
        self.size = size
        self.lightPath = nil
        self.darkPath = nil
        self.lightURL = nil
        self.darkURL = nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(theme.colors.surfaceElevated)
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .stroke(theme.colors.border.opacity(0.75), lineWidth: 1)
            iconContent
                .padding(size * 0.18)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var iconContent: some View {
        if let path = preferredPath, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image).resizable().scaledToFit()
        } else if let urlString = preferredURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFit() }
                else { fallbackIcon }
            }
        } else {
            fallbackIcon
        }
    }

    private var preferredPath: String? {
        colorScheme == .dark ? (darkPath ?? lightPath) : (lightPath ?? darkPath)
    }

    private var preferredURL: String? {
        colorScheme == .dark ? (darkURL ?? lightURL) : (lightURL ?? darkURL)
    }

    private var fallbackIcon: some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .foregroundStyle(theme.colors.textPrimary)
    }

    private static func symbol(for name: String) -> String {
        let value = name.lowercased()
        if value.contains("browser") || value.contains("chrome") { return "safari" }
        if value.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if value.contains("mail") || value.contains("gmail") { return "envelope.fill" }
        if value.contains("document") { return "doc.text.fill" }
        if value.contains("pdf") { return "doc.richtext.fill" }
        if value.contains("spreadsheet") { return "tablecells.fill" }
        if value.contains("presentation") { return "rectangle.on.rectangle.angled" }
        if value.contains("slack") { return "bubble.left.and.bubble.right.fill" }
        if value.contains("linear") { return "line.3.horizontal.decrease.circle.fill" }
        return "puzzlepiece.extension.fill"
    }
}
