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
    public let launcherTarget: CodexComposerPluginLauncher?
    public let onRefresh: () -> Void
    public let onAction: (CodexPluginRouteAction) -> Void

    @State private var primaryTab: CodexPluginRoutePrimaryTab = .marketplace
    @State private var manageTab: CodexPluginManageTab = .plugins
    @State private var filter: CodexPluginCatalogFilter = .all
    @State private var searchQuery = ""
    @State private var selectedPluginID: String?
    @State private var selectedSkillID: String?
    @FocusState private var isSearchFocused: Bool

    public init(
        plugins: [CodexPluginSummary],
        skills: [CodexSkillSummary],
        mcpServers: [CodexMCPServerStatus],
        isLoadingPlugins: Bool = false,
        isLoadingSkills: Bool = false,
        pluginErrorMessage: String? = nil,
        skillErrorMessage: String? = nil,
        pluginLoadErrors: [String] = [],
        launcherTarget: CodexComposerPluginLauncher? = nil,
        onRefresh: @escaping () -> Void,
        onAction: @escaping (CodexPluginRouteAction) -> Void
    ) {
        self.plugins = plugins
        self.skills = skills
        self.mcpServers = mcpServers
        self.isLoadingPlugins = isLoadingPlugins
        self.isLoadingSkills = isLoadingSkills
        self.pluginErrorMessage = pluginErrorMessage
        self.skillErrorMessage = skillErrorMessage
        self.pluginLoadErrors = pluginLoadErrors
        self.launcherTarget = launcherTarget
        self.onRefresh = onRefresh
        self.onAction = onAction
    }

    private var routeState: CodexPluginRouteState {
        CodexPluginRouteState(
            plugins: plugins,
            skills: skills,
            mcpServers: mcpServers,
            primaryTab: primaryTab,
            manageTab: manageTab,
            searchQuery: searchQuery,
            filter: filter,
            selectedPluginID: selectedPluginID,
            selectedSkillID: selectedSkillID,
            launcherTarget: launcherTarget
        )
    }

    private var isLoading: Bool {
        primaryTab == .skills || (primaryTab == .manage && manageTab == .skills)
            ? isLoadingSkills
            : isLoadingPlugins
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.colors.border)
            HStack(spacing: 0) {
                catalogColumn
                    .frame(minWidth: 390, idealWidth: 460, maxWidth: 540)
                Divider().overlay(theme.colors.border)
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(theme.colors.surfaceSunken)
        .onAppear(perform: seedOrApplyLauncher)
        .onChange(of: plugins.map(\.id)) { _, _ in seedOrApplyLauncher() }
        .onChange(of: skills.map(\.id)) { _, _ in seedOrApplyLauncher() }
        .onChange(of: launcherTarget) { _, _ in seedOrApplyLauncher() }
        .onChange(of: primaryTab) { _, _ in seedSelectionForCurrentTab() }
        .onChange(of: manageTab) { _, _ in seedSelectionForCurrentTab() }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand {
            if !searchQuery.isEmpty { searchQuery = "" }
        }
        .overlay(alignment: .topTrailing) {
            Button("Focus plugin search") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(primaryTab == .skills ? "Skills" : primaryTab == .manage ? "Plugins / Manage" : "Plugins")
                    .font(theme.fonts.routeTitle)
                    .foregroundStyle(theme.colors.textPrimary)
                Text(primaryTab == .skills
                     ? "Extend Codex’s capabilities with task-specific skills"
                     : "Work with Codex across your favorite tools")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }

            Picker("Plugins and skills", selection: $primaryTab) {
                ForEach(CodexPluginRoutePrimaryTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            Spacer()

            Button(primaryTab == .skills ? "Create skill" : "Create plugin") {
                onAction(.tryInChat(prompt: primaryTab == .skills
                    ? "Help me create a new Codex skill."
                    : "Help me create a new Codex plugin."))
            }
            .buttonStyle(.bordered)

            Menu {
                Button("Create plugin") { onAction(.tryInChat(prompt: "Help me create a new Codex plugin.")) }
                Button("Create skill") { onAction(.tryInChat(prompt: "Help me create a new Codex skill.")) }
                Divider()
                Button("Add a marketplace") { onAction(.tryInChat(prompt: "Help me add a Codex plugin marketplace.")) }
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Create options")
            .accessibilityLabel("Create options")

            if isLoading { CodexSpinner(size: .small) }

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(theme.fonts.label)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .help("Refresh plugins and skills")
            .accessibilityLabel("Refresh plugins and skills")
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var catalogColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchAndFilter
            if primaryTab == .manage { manageTabs }
            statusMessages

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if isLoading && currentInventoryIsEmpty {
                        loadingRows
                    } else if primaryTab == .skills || (primaryTab == .manage && manageTab == .skills) {
                        skillRows
                    } else if primaryTab == .manage && manageTab == .mcps {
                        mcpRows
                    } else {
                        if primaryTab == .marketplace && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            addedRow
                            featuredCards
                            categoryCards
                        }
                        pluginRows
                    }
                }
                .padding(.bottom, 22)
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.colors.surface.opacity(0.45))
    }

    private var searchAndFilter: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(theme.fonts.caption.weight(.medium))
                    .foregroundStyle(theme.colors.textTertiary)
                TextField(primaryTab == .manage ? "Search plugins" : "Search plugins and skills", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(theme.fonts.chat)
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search plugins and skills")
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.colors.textTertiary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(theme.colors.surfaceElevated.opacity(0.72), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous).stroke(theme.colors.border))

            Menu {
                ForEach(CodexPluginCatalogFilter.allCases, id: \.self) { option in
                    Button {
                        filter = option
                    } label: {
                        if filter == option { Label(option.title, systemImage: "checkmark") }
                        else { Text(option.title) }
                    }
                }
            } label: {
                Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    .frame(width: 36, height: 36)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Filter sections")
            .accessibilityLabel("Filter sections, \(filter.title)")
        }
    }

    private var manageTabs: some View {
        HStack(spacing: 6) {
            ForEach(routeState.manageCounts) { count in
                Button {
                    manageTab = count.tab
                } label: {
                    HStack(spacing: 5) {
                        Text(count.tab.title).font(theme.fonts.caption.weight(.semibold))
                        Text("\(count.count)").font(theme.fonts.micro).foregroundStyle(theme.colors.textTertiary)
                    }
                    .foregroundStyle(manageTab == count.tab ? theme.colors.textPrimary : theme.colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(manageTab == count.tab ? theme.colors.surfaceElevated.opacity(0.9) : theme.colors.surfaceSunken.opacity(0.35), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(count.tab.title), \(count.count)")
                .accessibilityAddTraits(manageTab == count.tab ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var statusMessages: some View {
        if let error = pluginErrorMessage { statusBanner(error, color: theme.colors.danger, icon: "exclamationmark.triangle.fill") }
        if let error = skillErrorMessage { statusBanner(error, color: theme.colors.danger, icon: "exclamationmark.triangle.fill") }
        ForEach(pluginLoadErrors, id: \.self) { error in
            statusBanner(error, color: theme.colors.warning, icon: "exclamationmark.circle.fill")
        }
    }

    private func statusBanner(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(theme.fonts.caption)
            .foregroundStyle(color)
            .lineLimit(3)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .accessibilityLabel(text)
    }

    @ViewBuilder private var addedRow: some View {
        let installed = plugins.filter(\.installed)
        if !installed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Added").font(theme.fonts.caption.weight(.semibold)).foregroundStyle(theme.colors.textTertiary)
                    Spacer()
                    Button("Manage") { primaryTab = .manage }
                        .buttonStyle(.plain)
                        .font(theme.fonts.caption.weight(.semibold))
                        .foregroundStyle(theme.colors.accentText)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(installed.prefix(10)) { plugin in
                            Button {
                                selectedPluginID = plugin.id
                                primaryTab = .manage
                            } label: {
                                Label(plugin.displayName, systemImage: "checkmark.circle.fill")
                                    .font(theme.fonts.caption)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(theme.colors.surfaceElevated.opacity(0.7), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var featuredCards: some View {
        if !routeState.featuredPlugins.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Featured").font(theme.fonts.caption.weight(.semibold)).foregroundStyle(theme.colors.textTertiary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(routeState.featuredPlugins.prefix(4)) { plugin in
                        PluginFeaturedCard(plugin: plugin, onSelect: { selectedPluginID = plugin.id }, onAction: onAction)
                    }
                }
            }
        }
    }

    @ViewBuilder private var categoryCards: some View {
        if !routeState.categoryCards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Explore").font(theme.fonts.caption.weight(.semibold)).foregroundStyle(theme.colors.textTertiary)
                HStack(spacing: 7) {
                    ForEach(routeState.categoryCards.prefix(3)) { card in
                        Button {
                            searchQuery = card.title
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(card.title).font(theme.fonts.caption.weight(.semibold)).lineLimit(1)
                                Text("\(card.count) plugins").font(theme.fonts.micro).foregroundStyle(theme.colors.textTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(theme.colors.surfaceElevated.opacity(0.52), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder private var pluginRows: some View {
        let visible = routeState.visiblePlugins
        if visible.isEmpty {
            emptyState(title: "No plugins found", detail: emptyDetail)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(primaryTab == .manage ? manageTab.title : "Marketplace")
                    .font(theme.fonts.caption.weight(.semibold)).foregroundStyle(theme.colors.textTertiary)
                ForEach(visible) { plugin in
                    PluginCatalogRow(
                        plugin: plugin,
                        isSelected: selectedPluginID == plugin.id,
                        showsToggle: primaryTab == .manage && manageTab == .plugins,
                        onSelect: { selectedPluginID = plugin.id; selectedSkillID = nil },
                        onAction: onAction
                    )
                }
            }
        }
    }

    @ViewBuilder private var skillRows: some View {
        let visible = routeState.visibleSkills
        if visible.isEmpty {
            emptyState(title: "No skills found", detail: emptyDetail)
        } else {
            ForEach(visible) { skill in
                SkillCatalogRow(
                    skill: skill,
                    isSelected: selectedSkillID == skill.id,
                    onSelect: { selectedSkillID = skill.id; selectedPluginID = nil },
                    onAction: onAction
                )
            }
        }
    }

    @ViewBuilder private var mcpRows: some View {
        let visible = routeState.visibleMCPServers
        if visible.isEmpty {
            emptyState(title: "No MCP servers", detail: emptyDetail)
        } else {
            ForEach(visible) { server in
                Button { searchQuery = server.displayName } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack").foregroundStyle(server.error == nil ? theme.colors.success : theme.colors.danger)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(server.displayName).font(theme.fonts.label)
                            Text(server.inventorySummary).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
                        }
                        Spacer()
                        Text(server.startupStatus ?? server.authStatusLabel).font(theme.fonts.micro).foregroundStyle(theme.colors.textTertiary)
                    }
                    .padding(11)
                    .background(theme.colors.surfaceElevated.opacity(0.64), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(server.displayName), \(server.inventorySummary), \(server.startupStatus ?? server.authStatusLabel)")
            }
        }
    }

    private var loadingRows: some View {
        VStack(spacing: 9) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .fill(theme.colors.surfaceElevated.opacity(0.55))
                    .frame(height: 72)
                    .overlay(alignment: .leading) { CodexSpinner(size: .small).padding(.leading, 18) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading plugins and skills")
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox").font(.system(size: 24)).foregroundStyle(theme.colors.textTertiary)
            Text(title).font(theme.fonts.label)
            Text(detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).multilineTextAlignment(.center)
            if !searchQuery.isEmpty { Button("Clear search") { searchQuery = "" }.buttonStyle(.bordered) }
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(theme.colors.surfaceElevated.opacity(0.28), in: RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous))
    }

    private var emptyDetail: String {
        searchQuery.isEmpty ? "Refresh the catalog or change the selected filter." : "Try a different search or clear the current filters."
    }

    @ViewBuilder private var detailPane: some View {
        if let detail = routeState.selectedDetail {
            PluginDetailPane(detail: detail, onAction: onAction).padding(24)
        } else if isLoading {
            VStack(spacing: 12) { CodexSpinner(size: .medium); Text("Loading details…").font(theme.fonts.caption) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading details")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Select an item").font(theme.fonts.sheetTitle)
                Text("Plugin, skill, app, and MCP details appear here.").font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
            }
            .padding(24)
        }
    }

    private var currentInventoryIsEmpty: Bool {
        if primaryTab == .skills || (primaryTab == .manage && manageTab == .skills) { return skills.isEmpty }
        if primaryTab == .manage && manageTab == .mcps { return mcpServers.isEmpty }
        return plugins.isEmpty
    }

    private func seedOrApplyLauncher() {
        if let target = launcherTarget { applyLauncherTarget(target) } else { seedSelectionForCurrentTab() }
    }

    private func applyLauncherTarget(_ target: CodexComposerPluginLauncher) {
        primaryTab = target.itemID == .browser ? .manage : .marketplace
        manageTab = .plugins
        searchQuery = target.searchQuery
        selectedSkillID = nil
        selectedPluginID = plugins.first { plugin in
            let candidates = [plugin.name, plugin.displayName, plugin.id].map { $0.lowercased() }
            return target.preferredPluginNames.map { $0.lowercased() }.contains { preferred in
                candidates.contains { $0 == preferred || $0.contains(preferred) }
            }
        }?.id
    }

    private func seedSelectionForCurrentTab() {
        if primaryTab == .skills || (primaryTab == .manage && manageTab == .skills) {
            if !skills.contains(where: { $0.id == selectedSkillID }) { selectedSkillID = routeState.visibleSkills.first?.id }
        } else if !plugins.contains(where: { $0.id == selectedPluginID }) {
            selectedPluginID = routeState.visiblePlugins.first?.id
                ?? plugins.first { $0.displayName.localizedCaseInsensitiveContains("Browser") }?.id
                ?? plugins.first?.id
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down else { return }
        if primaryTab == .skills || (primaryTab == .manage && manageTab == .skills) {
            let values = routeState.visibleSkills.map(\.id)
            selectedSkillID = adjacentID(in: values, selected: selectedSkillID, direction: direction)
        } else {
            let values = routeState.visiblePlugins.map(\.id)
            selectedPluginID = adjacentID(in: values, selected: selectedPluginID, direction: direction)
        }
    }

    private func adjacentID(in values: [String], selected: String?, direction: MoveCommandDirection) -> String? {
        guard !values.isEmpty else { return nil }
        let index = selected.flatMap(values.firstIndex(of:)) ?? 0
        return values[direction == .up ? max(0, index - 1) : min(values.count - 1, index + 1)]
    }
}

private struct PluginFeaturedCard: View {
    @Environment(\.codexAgentTheme) private var theme
    let plugin: CodexPluginSummary
    let onSelect: () -> Void
    let onAction: (CodexPluginRouteAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(plugin.displayName, systemImage: "sparkles").font(theme.fonts.label).lineLimit(1)
                    Text(plugin.detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            HStack {
                if !plugin.installed && plugin.installPolicy == "AVAILABLE" {
                    Button("Add") { onAction(.installPlugin(.init(plugin: plugin))) }.buttonStyle(.borderedProminent).controlSize(.small)
                } else { Text(plugin.statusLabel).font(theme.fonts.micro).foregroundStyle(theme.colors.success) }
                Spacer()
                pluginActionsMenu(plugin)
            }
        }
        .padding(11)
        .background(theme.colors.surfaceElevated.opacity(0.68), in: RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous).stroke(theme.colors.border))
        .accessibilityElement(children: .contain)
    }

    private func pluginActionsMenu(_ plugin: CodexPluginSummary) -> some View {
        Menu {
            if plugin.installed { Button(plugin.enabled ? "Disable" : "Enable") { onAction(.setPluginEnabled(.init(plugin: plugin), enabled: !plugin.enabled)) } }
            if plugin.installed && plugin.installPolicy != "INSTALLED_BY_DEFAULT" { Button("Remove", role: .destructive) { onAction(.uninstallPlugin(.init(plugin: plugin))) } }
            if let prompt = plugin.defaultPrompt { Button("Try in chat") { onAction(.tryInChat(prompt: prompt)) } }
        } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("More actions for \(plugin.displayName)")
        .accessibilityLabel("More actions for \(plugin.displayName)")
    }
}

private struct PluginCatalogRow: View {
    @Environment(\.codexAgentTheme) private var theme
    let plugin: CodexPluginSummary
    let isSelected: Bool
    let showsToggle: Bool
    let onSelect: () -> Void
    let onAction: (CodexPluginRouteAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: plugin.installed ? "checkmark.circle.fill" : "puzzlepiece.extension")
                        .foregroundStyle(plugin.installed ? theme.colors.success : theme.colors.textTertiary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plugin.displayName).font(theme.fonts.label).foregroundStyle(theme.colors.textPrimary).lineLimit(1)
                        Text(plugin.detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(2)
                        Text(plugin.marketplaceDisplayName).font(theme.fonts.micro).foregroundStyle(theme.colors.textTertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsToggle {
                Toggle("", isOn: Binding(
                    get: { plugin.enabled },
                    set: { onAction(.setPluginEnabled(.init(plugin: plugin), enabled: $0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Toggle plugin enabled state")
                .accessibilityValue(plugin.enabled ? "Enabled" : "Disabled")
            } else if !plugin.installed && plugin.installPolicy == "AVAILABLE" {
                Button("Add") { onAction(.installPlugin(.init(plugin: plugin))) }.buttonStyle(.bordered).controlSize(.small)
            } else {
                Menu {
                    if plugin.installed { Button(plugin.enabled ? "Disable" : "Enable") { onAction(.setPluginEnabled(.init(plugin: plugin), enabled: !plugin.enabled)) } }
                    if plugin.installed && plugin.installPolicy != "INSTALLED_BY_DEFAULT" { Button("Remove", role: .destructive) { onAction(.uninstallPlugin(.init(plugin: plugin))) } }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("More actions for \(plugin.displayName)")
            }
        }
        .padding(11)
        .background(isSelected ? theme.colors.accentSoft.opacity(0.5) : theme.colors.surfaceElevated.opacity(0.64), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous).stroke(isSelected ? theme.colors.accent : theme.colors.border))
        .accessibilityElement(children: .contain)
    }
}

private struct SkillCatalogRow: View {
    @Environment(\.codexAgentTheme) private var theme
    let skill: CodexSkillSummary
    let isSelected: Bool
    let onSelect: () -> Void
    let onAction: (CodexPluginRouteAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: "hammer").foregroundStyle(theme.colors.textTertiary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(skill.displayName).font(theme.fonts.label).lineLimit(1)
                        Text(skill.detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(2)
                        Text(skill.scopeLabel).font(theme.fonts.micro).foregroundStyle(theme.colors.textTertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("", isOn: Binding(
                get: { skill.enabled },
                set: { onAction(.setSkillEnabled(.init(skill: skill), enabled: $0)) }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .accessibilityLabel("Toggle skill enabled state")
            .accessibilityValue(skill.enabled ? "Enabled" : "Disabled")
            Menu {
                if skill.scope == "user" {
                    Button("Uninstall", role: .destructive) {
                        onAction(.uninstallSkill(.init(skill: skill)))
                    }
                }
                if let prompt = skill.defaultPrompt {
                    Button("Try in chat") { onAction(.tryInChat(prompt: prompt)) }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("More actions for \(skill.displayName)")
        }
        .padding(11)
        .background(isSelected ? theme.colors.accentSoft.opacity(0.5) : theme.colors.surfaceElevated.opacity(0.64), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous).stroke(isSelected ? theme.colors.accent : theme.colors.border))
    }
}

private struct PluginDetailPane: View {
    @Environment(\.codexAgentTheme) private var theme
    let detail: CodexPluginRouteDetail
    let onAction: (CodexPluginRouteAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: detailIcon).font(.system(size: 24, weight: .medium)).foregroundStyle(theme.colors.accentText)
                        .frame(width: 48, height: 48).background(theme.colors.accentSoft.opacity(0.65), in: RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(detail.title).font(theme.fonts.routeTitle).foregroundStyle(theme.colors.textPrimary)
                        Text(detail.detail).font(theme.fonts.chat).foregroundStyle(theme.colors.textSecondary)
                        Text(detail.statusLabel).font(theme.fonts.caption.weight(.semibold)).foregroundStyle(detail.isEnabled ? theme.colors.success : theme.colors.textTertiary)
                    }
                    Spacer()
                }

                actionRow
                Text(detail.description).font(theme.fonts.chat).foregroundStyle(theme.colors.textPrimary).lineSpacing(3)

                if let prompt = detail.prompt {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Prompt").font(theme.fonts.caption.weight(.semibold)).foregroundStyle(theme.colors.textTertiary)
                        Text(prompt).font(theme.fonts.caption).foregroundStyle(theme.colors.textPrimary).padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.colors.surfaceElevated.opacity(0.58), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                    }
                }

                metadataSection("Capabilities", detail.capabilities, links: false)
                metadataSection("Information", detail.metadata, links: false)
                metadataSection("Links", detail.legalLinks, links: true)
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var detailIcon: String {
        switch detail.kind { case .plugin: "puzzlepiece.extension"; case .skill: "hammer"; case .mcp: "server.rack"; case .boundary: "shippingbox" }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if detail.canInstall, let action = detail.primaryAction { Button("Add") { onAction(action) }.buttonStyle(.borderedProminent) }
            if detail.canToggleEnabled {
                Toggle("Enabled", isOn: Binding(
                    get: { detail.isEnabled },
                    set: { enabled in
                        switch detail.kind {
                        case .plugin(let target): onAction(.setPluginEnabled(target, enabled: enabled))
                        case .skill(let target): onAction(.setSkillEnabled(target, enabled: enabled))
                        case .mcp, .boundary: break
                        }
                    }
                ))
                .toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(detail.kind.isSkill ? "Toggle skill enabled state" : "Toggle plugin enabled state")
            }
            Menu {
                if detail.canUninstall, case .plugin(let target) = detail.kind { Button("Remove", role: .destructive) { onAction(.uninstallPlugin(target)) } }
                if detail.canUninstall, case .skill(let target) = detail.kind { Button("Uninstall", role: .destructive) { onAction(.uninstallSkill(target)) } }
                if let tryAction = detail.tryInChatAction { Button("Try in chat") { onAction(tryAction) } }
            } label: { Label("More actions", systemImage: "ellipsis") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            if let tryAction = detail.tryInChatAction { Button { onAction(tryAction) } label: { Label("Try in chat", systemImage: "paperplane") }.buttonStyle(.borderedProminent) }
            Spacer()
        }
    }

    @ViewBuilder private func metadataSection(_ title: String, _ rows: [String], links: Bool) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(theme.fonts.caption.weight(.semibold)).foregroundStyle(theme.colors.textTertiary)
                ForEach(rows, id: \.self) { row in
                    if links, let parsed = parsedLink(row), let url = URL(string: parsed.url) {
                        Link(parsed.title, destination: url).font(theme.fonts.caption).foregroundStyle(theme.colors.accentText)
                    } else {
                        Text(row).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func parsedLink(_ row: String) -> (title: String, url: String)? {
        guard let separator = row.firstIndex(of: ":") else { return nil }
        let title = String(row[..<separator])
        let value = String(row[row.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        return (title, value)
    }
}

private extension CodexPluginRouteDetail.Kind {
    var isSkill: Bool { if case .skill = self { true } else { false } }
}
