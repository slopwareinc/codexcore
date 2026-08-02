import SwiftUI

enum CodexPluginRoutePage: Equatable {
    case plugins
    case skills
    case manage
    case pluginDetail(String)
}

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
    public let pendingPluginIDs: Set<String>
    public let pendingSkillIDs: Set<String>
    public let onLoad: () -> Void
    public let onRefresh: () -> Void
    public let onAction: (CodexPluginRouteAction) -> Void

    @State private var page: CodexPluginRoutePage
    @State private var manageTab: CodexPluginManageTab
    @State private var filter: CodexPluginCatalogFilter = .openAI
    @State private var searchQuery = ""
    @State private var selectedPluginID: String?
    @State private var pluginDetailReturnPage: CodexPluginRoutePage = .plugins
    @State private var skillDetailID: String?
    @State private var expandedMarketplaceSections: Set<String> = []
    @State private var expandedSkillSections: Set<String> = []
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
        pendingPluginIDs: Set<String> = [],
        pendingSkillIDs: Set<String> = [],
        initialTab: CodexPluginRoutePrimaryTab = .marketplace,
        initialManageTab: CodexPluginManageTab = .plugins,
        onLoad: @escaping () -> Void = {},
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
        self.pendingPluginIDs = pendingPluginIDs
        self.pendingSkillIDs = pendingSkillIDs
        let initialPage: CodexPluginRoutePage = switch initialTab {
        case .marketplace: .plugins
        case .skills: .skills
        case .manage: .manage
        }
        _page = State(initialValue: initialPage)
        _manageTab = State(initialValue: initialManageTab)
        self.onLoad = onLoad
        self.onRefresh = onRefresh
        self.onAction = onAction
    }

    private var primaryTab: CodexPluginRoutePrimaryTab {
        switch page {
        case .skills: .skills
        case .manage: .manage
        case .plugins, .pluginDetail: .marketplace
        }
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
            selectedSkillID: skillDetailID,
            launcherTarget: launcherTarget
        )
    }

    private var isLoading: Bool {
        page == .skills || (page == .manage && manageTab == .skills)
            ? isLoadingSkills
            : isLoadingPlugins
    }

    private func isPending(_ plugin: CodexPluginSummary) -> Bool {
        pendingPluginIDs.contains(plugin.protocolID)
    }

    private func isPending(_ skill: CodexSkillSummary) -> Bool {
        pendingSkillIDs.contains(skill.name.contains(":") ? skill.name : skill.path)
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(theme.colors.surfaceSunken)
        .onAppear {
            applyLauncherTargetIfNeeded()
            onLoad()
        }
        .onChange(of: launcherTarget) { _, _ in applyLauncherTargetIfNeeded() }
        .onChange(of: plugins.map(\.id)) { _, _ in applyLauncherTargetIfNeeded() }
        .onChange(of: selectedPluginID) { _, id in
            guard let id else { return }
            pluginDetailReturnPage = page == .manage ? .manage : .plugins
            page = .pluginDetail(id)
        }
        .onExitCommand(perform: goBackOrClearSearch)
        .overlay(alignment: .topTrailing) {
            Button("Focus plugin search") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: Binding(
            get: { selectedSkill != nil },
            set: { if !$0 { skillDetailID = nil } }
        )) {
            if let skill = selectedSkill {
                OfficialSkillDetailSheet(
                    skill: skill,
                    icon: pluginIcon(for: skill),
                    isPending: isPending(skill),
                    onClose: { skillDetailID = nil },
                    onAction: onAction
                )
                .codexAgentTheme(theme)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            toolbarNavigation
            Spacer()
            createMenu
            if page == .manage || isPluginDetail {
                Menu {
                    Button("Add plugin marketplace") {
                        onAction(.tryInChat(prompt: "Help me add a Codex plugin marketplace."))
                    }
                    Button("Create plugin") {
                        onAction(.tryInChat(prompt: "Help me create a new Codex plugin."))
                    }
                    Button("Create skill") {
                        onAction(.tryInChat(prompt: "Help me create a new Codex skill."))
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("Page actions")
            } else {
                if isLoading { CodexSpinner(size: .small) }
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise").frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help("Refresh plugins and skills")
                .accessibilityLabel("Refresh plugins and skills")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
    }

    @ViewBuilder private var toolbarNavigation: some View {
        switch page {
        case .plugins, .skills:
            HStack(spacing: 4) {
                topTab("Plugins", selected: page == .plugins) {
                    page = .plugins
                    searchQuery = ""
                    selectedPluginID = nil
                }
                topTab("Skills", selected: page == .skills) {
                    page = .skills
                    searchQuery = ""
                    selectedPluginID = nil
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Plugins and skills")
        case .manage:
            breadcrumb(root: "Plugins", current: "Manage") { page = .plugins }
        case .pluginDetail(let id):
            breadcrumb(
                root: pluginDetailReturnPage == .manage ? "Manage" : "Plugins",
                current: plugins.first(where: { $0.id == id })?.displayName ?? "Plugin"
            ) {
                page = pluginDetailReturnPage
                selectedPluginID = nil
            }
        }
    }

    private func topTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(theme.fonts.chat.weight(.medium))
                .foregroundStyle(selected ? theme.colors.textPrimary : theme.colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? theme.colors.surfaceElevated : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func breadcrumb(root: String, current: String, onBack: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Button(root, action: onBack)
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.textSecondary)
            Image(systemName: "chevron.right")
                .font(theme.fonts.micro)
                .foregroundStyle(theme.colors.textTertiary)
            Text(current)
                .foregroundStyle(theme.colors.textPrimary)
        }
        .font(theme.fonts.caption.weight(.medium))
        .accessibilityElement(children: .combine)
    }

    private var createMenu: some View {
        Menu {
            Button(page == .skills ? "Create skill" : "Create plugin") {
                onAction(.tryInChat(prompt: page == .skills
                    ? "Help me create a new Codex skill."
                    : "Help me create a new Codex plugin."))
            }
            Divider()
            Button("Create plugin") { onAction(.tryInChat(prompt: "Help me create a new Codex plugin.")) }
            Button("Create skill") { onAction(.tryInChat(prompt: "Help me create a new Codex skill.")) }
            Button("Add plugin marketplace") { onAction(.tryInChat(prompt: "Help me add a Codex plugin marketplace.")) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                Image(systemName: "chevron.down").font(theme.fonts.micro)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(theme.colors.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.colors.border))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Create options")
        .accessibilityLabel("Create options")
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .plugins: marketplacePage
        case .skills: skillsPage
        case .manage: managePage
        case .pluginDetail(let id):
            if let plugin = plugins.first(where: { $0.id == id }) {
                OfficialPluginDetailPage(
                    plugin: plugin,
                    skills: associatedSkills(with: plugin),
                    isPending: isPending(plugin),
                    onAction: onAction
                )
            } else {
                emptyState(title: "Plugin unavailable", detail: "Refresh the marketplace and try again.")
            }
        }
    }

    private var marketplacePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageTitle("Plugins", subtitle: "Work with Codex across your favorite tools")
                searchField(placeholder: "Search plugins and skills", showsFilter: true)
                statusMessages
                if isLoadingPlugins && plugins.isEmpty {
                    loadingRows
                } else if let pluginErrorMessage, plugins.isEmpty {
                    emptyState(title: "Couldn’t load plugins", detail: pluginErrorMessage)
                } else if searchQuery.trimmedForPluginSearch.isEmpty {
                    addedSection
                    marketplaceScopeTabs
                    marketplaceSections
                } else {
                    searchResults
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: CodexPluginLayoutMetrics.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var skillsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageTitle("Skills", subtitle: "Extend Codex's capabilities with task-specific skills")
                searchField(placeholder: "Search plugins and skills", showsFilter: true)
                statusMessages
                if isLoadingSkills && skills.isEmpty {
                    loadingRows
                } else if let skillErrorMessage, skills.isEmpty {
                    emptyState(title: "Couldn’t load skills", detail: skillErrorMessage)
                } else if routeState.visibleSkills.isEmpty {
                    emptyState(title: "No skills found", detail: "Try another search or filter.")
                } else {
                    skillSection("Personal", skills: personalSkills)
                    skillSection("System", skills: systemSkills)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: CodexPluginLayoutMetrics.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var managePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                manageTabs
                Spacer()
                searchField(placeholder: manageSearchPlaceholder, showsFilter: false)
                    .frame(width: 180)
            }
            statusMessages
            manageInventory
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 30)
        .frame(maxWidth: CodexPluginLayoutMetrics.contentWidth, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }

    private func pageTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.colors.textPrimary)
            Text(subtitle)
                .font(.system(size: 16))
                .foregroundStyle(theme.colors.textSecondary)
        }
        .padding(.top, 12)
    }

    private func searchField(placeholder: String, showsFilter: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.colors.textTertiary)
                TextField(placeholder, text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(theme.fonts.chat)
                    .focused($isSearchFocused)
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.colors.textTertiary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(theme.colors.surfaceElevated, in: Capsule())
            if showsFilter {
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
                    Image(systemName: "line.3.horizontal.decrease")
                        .frame(width: 36, height: 36)
                        .background(theme.colors.surfaceElevated, in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("Filter sections, \(filter.title)")
            }
        }
    }

    @ViewBuilder private var addedSection: some View {
        let installed = plugins.filter(\.installed)
        if !installed.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Added").font(theme.fonts.chat.weight(.semibold))
                    Spacer()
                    Button("Manage") {
                        selectedPluginID = nil
                        page = .manage
                        searchQuery = ""
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.textSecondary)
                }
                Divider().overlay(theme.colors.border)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(installed.prefix(12)) { plugin in
                            Button {
                                selectedPluginID = plugin.id
                            } label: {
                                CodexPluginIconView(reference: plugin.icon, size: 38)
                                    .frame(width: 46, height: 46)
                                    .background(theme.colors.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.colors.border))
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

    private var marketplaceScopeTabs: some View {
        HStack(spacing: 8) {
            ForEach([CodexPluginCatalogFilter.openAI, .workspace, .personal], id: \.self) { option in
                topTab(option.title, selected: filter == option) { filter = option }
            }
        }
        .accessibilityLabel("Marketplace source")
    }

    @ViewBuilder private var marketplaceSections: some View {
        let visible = routeState.visiblePlugins
        if visible.isEmpty {
            emptyState(title: "No plugins found", detail: "Choose another marketplace section.")
        } else {
            let featured = routeState.featuredPlugins
            if !featured.isEmpty {
                marketplaceSection("Featured", plugins: featured, collapsedLimit: 4)
            }
            ForEach(groupedMarketplacePlugins(excluding: Set(featured.map(\.id))), id: \.title) { group in
                marketplaceSection(group.title, plugins: group.plugins, collapsedLimit: 6)
            }
        }
    }

    private func marketplaceSection(_ title: String, plugins: [CodexPluginSummary], collapsedLimit: Int) -> some View {
        let isExpanded = expandedMarketplaceSections.contains(title)
        let visibleCount = CodexCatalogSectionPresentation.visibleCount(
            total: plugins.count,
            collapsedLimit: collapsedLimit,
            isExpanded: isExpanded
        )
        let displayedPlugins = Array(plugins.prefix(visibleCount))
        return VStack(alignment: .leading, spacing: 14) {
            Text(title).font(theme.fonts.chat.weight(.semibold))
            Divider().overlay(theme.colors.border)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible())], spacing: 8) {
                ForEach(displayedPlugins) { plugin in
                    OfficialPluginRow(
                        plugin: plugin,
                        isPending: isPending(plugin),
                        onOpen: { selectedPluginID = plugin.id },
                        onAction: onAction
                    )
                }
            }
            if let label = CodexCatalogSectionPresentation.moreLabel(
                names: plugins.map(\.displayName),
                collapsedLimit: collapsedLimit,
                isExpanded: isExpanded
            ) {
                Button {
                    if isExpanded { expandedMarketplaceSections.remove(title) }
                    else { expandedMarketplaceSections.insert(title) }
                } label: {
                    Text(label)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                }
                .buttonStyle(.plain)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .accessibilityLabel("\(label) in \(title)")
            }
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search results").font(theme.fonts.chat.weight(.semibold))
            if routeState.visiblePlugins.isEmpty {
                emptyState(title: "No plugins found", detail: "Try a different search.")
            } else {
                CodexPluginCatalogTable(
                    plugins: routeState.visiblePlugins,
                    selectedPluginID: $selectedPluginID,
                    showsToggle: false,
                    pendingPluginIDs: pendingPluginIDs,
                    theme: theme,
                    onAction: onAction
                )
                .frame(minHeight: 320)
            }
        }
    }

    private var manageTabs: some View {
        HStack(spacing: 6) {
            ForEach(routeState.manageCounts) { count in
                Button {
                    manageTab = count.tab
                    searchQuery = ""
                    selectedPluginID = nil
                } label: {
                    Text("\(count.tab.title)  \(count.count)")
                        .font(theme.fonts.caption.weight(.medium))
                        .foregroundStyle(manageTab == count.tab ? theme.colors.textPrimary : theme.colors.textSecondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(manageTab == count.tab ? theme.colors.surfaceElevated : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(count.tab.title) \(count.count)")
                .accessibilityAddTraits(manageTab == count.tab ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var manageInventory: some View {
        switch manageTab {
        case .plugins:
            let visible = routeState.visiblePlugins
            if isLoadingPlugins && visible.isEmpty {
                loadingRows
            } else if visible.isEmpty {
                emptyState(title: "No plugins", detail: "Installed plugins appear here.")
            } else {
                CodexPluginCatalogTable(
                    plugins: visible,
                    selectedPluginID: $selectedPluginID,
                    showsToggle: true,
                    pendingPluginIDs: pendingPluginIDs,
                    theme: theme,
                    onAction: onAction
                )
                .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
            }
        case .apps:
            ScrollView { LazyVStack(spacing: CodexPluginLayoutMetrics.rowSpacing) { managedAppRows } }
        case .mcps:
            ScrollView { LazyVStack(spacing: CodexPluginLayoutMetrics.rowSpacing) { mcpRows } }
        case .skills:
            ScrollView { LazyVStack(spacing: CodexPluginLayoutMetrics.rowSpacing) { managedSkillRows } }
        }
    }

    @ViewBuilder private func skillSection(_ title: String, skills: [CodexSkillSummary]) -> some View {
        if !skills.isEmpty {
            let collapsedLimit = 5
            let isExpanded = expandedSkillSections.contains(title)
            let visibleCount = CodexCatalogSectionPresentation.visibleCount(
                total: skills.count,
                collapsedLimit: collapsedLimit,
                isExpanded: isExpanded
            )
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(theme.fonts.chat.weight(.semibold))
                LazyVStack(spacing: CodexPluginLayoutMetrics.rowSpacing) {
                    ForEach(skills.prefix(visibleCount)) { skill in
                        OfficialSkillRow(
                            skill: skill,
                            icon: pluginIcon(for: skill),
                            showsToggle: false,
                            isPending: isPending(skill),
                            onOpen: { skillDetailID = skill.id },
                            onAction: onAction
                        )
                    }
                }
                if let label = CodexCatalogSectionPresentation.moreLabel(
                    names: skills.map(\.displayName),
                    collapsedLimit: collapsedLimit,
                    isExpanded: isExpanded
                ) {
                    Button {
                        if isExpanded { expandedSkillSections.remove(title) }
                        else { expandedSkillSections.insert(title) }
                    } label: {
                        Text(label)
                            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .accessibilityLabel("\(label) in \(title)")
                }
            }
        }
    }

    @ViewBuilder private var managedSkillRows: some View {
        let visible = routeState.visibleSkills
        if visible.isEmpty {
            emptyState(title: "No skills", detail: "Installed skills appear here.")
        } else {
            ForEach(visible) { skill in
                OfficialSkillRow(
                    skill: skill,
                    icon: pluginIcon(for: skill),
                    showsToggle: true,
                    isPending: isPending(skill),
                    onOpen: { skillDetailID = skill.id },
                    onAction: onAction
                )
            }
        }
    }

    @ViewBuilder private var managedAppRows: some View {
        let visible = routeState.visiblePlugins
        if isLoadingPlugins && visible.isEmpty {
            loadingRows
        } else if visible.isEmpty {
            emptyState(title: "No apps", detail: "Apps included by installed plugins appear here.")
        } else {
            ForEach(visible) { plugin in
                Button {
                    selectedPluginID = plugin.id
                } label: {
                    HStack(spacing: 12) {
                        CodexPluginIconView(reference: plugin.icon, size: 36)
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plugin.displayName).font(theme.fonts.label).lineLimit(1)
                            Text(plugin.detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "checkmark")
                            .foregroundStyle(theme.colors.textTertiary)
                            .accessibilityLabel("Installed")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: CodexPluginLayoutMetrics.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(plugin.displayName), installed app")
            }
        }
    }

    @ViewBuilder private var mcpRows: some View {
        let visible = routeState.visibleMCPServers
        if visible.isEmpty {
            emptyState(title: "No MCPs", detail: "Configured MCP servers appear here.")
        } else {
            ForEach(visible) { server in
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .frame(width: 36, height: 36)
                        .background(theme.colors.surfaceElevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.displayName).font(theme.fonts.label)
                        Text(server.inventorySummary).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
                    }
                    Spacer()
                    Image(systemName: server.error == nil ? "checkmark" : "exclamationmark.triangle")
                        .foregroundStyle(server.error == nil ? theme.colors.textTertiary : theme.colors.danger)
                }
                .padding(.horizontal, 10)
                .frame(height: CodexPluginLayoutMetrics.rowHeight)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var statusMessages: some View {
        if let error = pluginErrorMessage { statusBanner(error, color: theme.colors.danger) }
        if let error = skillErrorMessage { statusBanner(error, color: theme.colors.danger) }
        ForEach(pluginLoadErrors, id: \.self) { statusBanner($0, color: theme.colors.warning) }
    }

    private func statusBanner(_ text: String, color: Color) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(theme.fonts.caption)
            .foregroundStyle(color)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var loadingRows: some View {
        VStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 9).fill(theme.colors.surfaceElevated).frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(theme.colors.surfaceElevated).frame(width: 130, height: 10)
                        Capsule().fill(theme.colors.surfaceElevated.opacity(0.7)).frame(width: 240, height: 9)
                    }
                    Spacer()
                }
                .frame(height: CodexPluginLayoutMetrics.rowHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading plugins and skills")
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox").font(.system(size: 28)).foregroundStyle(theme.colors.textTertiary)
            Text(title).font(theme.fonts.label)
            Text(detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .accessibilityElement(children: .combine)
    }

    private var selectedSkill: CodexSkillSummary? {
        guard let skillDetailID else { return nil }
        return skills.first { $0.id == skillDetailID }
    }

    private var personalSkills: [CodexSkillSummary] {
        routeState.visibleSkills.filter { $0.scope?.lowercased() != "system" }
    }

    private var systemSkills: [CodexSkillSummary] {
        routeState.visibleSkills.filter { $0.scope?.lowercased() == "system" }
    }

    private var isPluginDetail: Bool {
        if case .pluginDetail = page { return true }
        return false
    }

    private var manageSearchPlaceholder: String {
        switch manageTab {
        case .plugins: "Search plugins"
        case .apps: "Search apps"
        case .mcps: "Search MCPs"
        case .skills: "Search skills"
        }
    }

    private func groupedMarketplacePlugins(excluding excluded: Set<String>) -> [(title: String, plugins: [CodexPluginSummary])] {
        var order: [String] = []
        var groups: [String: [CodexPluginSummary]] = [:]
        for plugin in routeState.visiblePlugins where !excluded.contains(plugin.id) {
            let title = plugin.category?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "Other"
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(plugin)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private func pluginIcon(for skill: CodexSkillSummary) -> CodexPluginIconReference {
        let skillName = skill.name.lowercased()
        return plugins.first { plugin in
            skillName == plugin.name.lowercased()
                || skillName.hasPrefix(plugin.name.lowercased() + ":")
                || skill.path.lowercased().contains("/\(plugin.name.lowercased())/")
        }?.icon ?? .init()
    }

    private func associatedSkills(with plugin: CodexPluginSummary) -> [CodexSkillSummary] {
        let name = plugin.name.lowercased()
        return skills.filter {
            $0.name.lowercased() == name
                || $0.name.lowercased().hasPrefix(name + ":")
                || $0.path.lowercased().contains("/\(name)/")
        }
    }

    private func applyLauncherTargetIfNeeded() {
        guard let target = launcherTarget else { return }
        let preferred = target.preferredPluginNames.map { $0.lowercased() }
        if let plugin = plugins.first(where: { plugin in
            preferred.contains { wanted in
                plugin.name.lowercased() == wanted
                    || plugin.displayName.lowercased().contains(wanted)
                    || plugin.id.lowercased().contains(wanted)
            }
        }) {
            selectedPluginID = plugin.id
            page = .pluginDetail(plugin.id)
        }
    }

    private func goBackOrClearSearch() {
        if !searchQuery.isEmpty {
            searchQuery = ""
        } else if skillDetailID != nil {
            skillDetailID = nil
        } else {
            switch page {
            case .pluginDetail:
                page = pluginDetailReturnPage
                selectedPluginID = nil
            case .manage:
                page = .plugins
            case .skills, .plugins:
                break
            }
        }
    }
}

private struct OfficialPluginRow: View {
    @Environment(\.codexAgentTheme) private var theme
    let plugin: CodexPluginSummary
    let isPending: Bool
    let onOpen: () -> Void
    let onAction: (CodexPluginRouteAction) -> Void

    var body: some View {
        HStack(spacing: 11) {
            Button(action: onOpen) {
                HStack(spacing: 11) {
                    CodexPluginIconView(reference: plugin.icon, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plugin.displayName).font(theme.fonts.label).lineLimit(1)
                        Text(plugin.detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !plugin.installed && plugin.installPolicy == "AVAILABLE" {
                Button { onAction(.installPlugin(.init(plugin: plugin))) } label: {
                    if isPending { ProgressView().controlSize(.small) } else { Text("Add") }
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isPending)
            } else {
                pluginMenu
                    .disabled(isPending)
            }
        }
        .frame(height: CodexPluginLayoutMetrics.rowHeight)
        .accessibilityElement(children: .contain)
    }

    private var pluginMenu: some View {
        Menu {
            Button("View details", action: onOpen)
            if plugin.supportsEnabledToggle {
                Button(plugin.enabled ? "Disable" : "Enable") {
                    onAction(.setPluginEnabled(.init(plugin: plugin), enabled: !plugin.enabled))
                }
            }
            if plugin.installed && plugin.installPolicy != "INSTALLED_BY_DEFAULT" {
                Button("Remove", role: .destructive) { onAction(.uninstallPlugin(.init(plugin: plugin))) }
            }
            if let prompt = plugin.defaultPrompt {
                Button("Try in chat") { onAction(.tryInChat(prompt: prompt)) }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("More actions for \(plugin.displayName)")
    }
}

struct OfficialSkillRow: View {
    @Environment(\.codexAgentTheme) private var theme
    let skill: CodexSkillSummary
    let icon: CodexPluginIconReference
    let showsToggle: Bool
    let isPending: Bool
    let onOpen: () -> Void
    let onAction: (CodexPluginRouteAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    CodexPluginIconView(reference: icon, size: 36, fallbackSystemName: "hammer")
                        .frame(width: 40, height: 40)
                        .background(theme.colors.surfaceElevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(skill.displayName).font(theme.fonts.label).lineLimit(1)
                        Text(skill.detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsToggle {
                Toggle("", isOn: Binding(
                    get: { skill.enabled },
                    set: { onAction(.setSkillEnabled(.init(skill: skill), enabled: $0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isPending)
                .accessibilityLabel("Toggle skill enabled state")
            } else if skill.enabled {
                Image(systemName: "checkmark")
                    .foregroundStyle(theme.colors.textTertiary)
                    .accessibilityLabel("Enabled")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: CodexPluginLayoutMetrics.rowHeight)
    }
}

struct OfficialSkillDetailSheet: View {
    @Environment(\.codexAgentTheme) private var theme
    let skill: CodexSkillSummary
    let icon: CodexPluginIconReference
    let isPending: Bool
    let onClose: () -> Void
    let onAction: (CodexPluginRouteAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 18) {
                    CodexPluginIconView(reference: icon, size: 46, fallbackSystemName: "hammer")
                        .frame(width: 56, height: 56)
                        .background(theme.colors.surfaceSunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    HStack(alignment: .center, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(skill.displayName).font(.system(size: 24, weight: .semibold))
                            Text("Skill").font(.system(size: 21)).foregroundStyle(theme.colors.textSecondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { skill.enabled },
                            set: { onAction(.setSkillEnabled(.init(skill: skill), enabled: $0)) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(isPending)
                        .accessibilityLabel("Toggle skill enabled state")
                        Menu {
                            Button(skill.enabled ? "Disable skill" : "Enable skill") {
                                onAction(.setSkillEnabled(.init(skill: skill), enabled: !skill.enabled))
                            }
                            if let prompt = skill.defaultPrompt {
                                Button("Try in chat") { onAction(.tryInChat(prompt: prompt)) }
                            }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 28, height: 28)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .disabled(isPending)
                    }

                    Text(skill.detail)
                        .font(theme.fonts.chat)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(4)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 32, height: 32)
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close skill details")
            }
            .padding(28)

            ScrollView {
                Text(skill.description.nilIfBlank ?? skill.detail)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(22)
                    .background(theme.colors.surfaceSunken.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
            }

            HStack {
                if skill.scope?.lowercased() == "user" {
                    Button("Uninstall", role: .destructive) { onAction(.uninstallSkill(.init(skill: skill))) }
                        .buttonStyle(.bordered)
                        .disabled(isPending)
                }
                Spacer()
                if let prompt = skill.defaultPrompt {
                    Button { onAction(.tryInChat(prompt: prompt)) } label: {
                        Label("Try in chat", systemImage: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(theme.colors.surface)
        }
        .frame(width: 900, height: 780)
        .background(theme.colors.surface)
    }
}

private struct OfficialPluginDetailPage: View {
    @Environment(\.codexAgentTheme) private var theme
    let plugin: CodexPluginSummary
    let skills: [CodexSkillSummary]
    let isPending: Bool
    let onAction: (CodexPluginRouteAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 14) {
                    CodexPluginIconView(reference: plugin.icon, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plugin.displayName).font(.system(size: 24, weight: .semibold))
                        Text(plugin.detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    detailMenu
                    if let prompt = plugin.defaultPrompt {
                        Button { onAction(.tryInChat(prompt: prompt)) } label: {
                            Label("Try in chat", systemImage: "bubble.left.and.bubble.right")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if let prompt = plugin.defaultPrompt {
                    HStack {
                        Spacer()
                        Text(prompt).font(theme.fonts.caption).lineLimit(1)
                        Image(systemName: "arrow.right.circle.fill")
                        Spacer()
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, minHeight: 86)
                    .background(
                        LinearGradient(
                            colors: [theme.colors.accentSoft.opacity(0.8), theme.colors.surfaceElevated, theme.colors.accent.opacity(0.22)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                }

                Text(plugin.longDescription?.nilIfBlank ?? plugin.detail)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineSpacing(4)

                if !skills.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Skills  \(skills.count)").font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
                        ForEach(skills) { skill in
                            HStack {
                                Text(skill.displayName).font(theme.fonts.label)
                                Spacer()
                                Text(skill.detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(1)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 11) {
                    Text("Information").font(theme.fonts.caption.weight(.semibold))
                    informationRow("Capabilities", value: plugin.capabilities.joined(separator: ", "))
                    informationRow("Developer", value: plugin.developerName ?? plugin.marketplaceDisplayName)
                    informationRow("Category", value: plugin.category ?? "Other")
                    if let version = plugin.localVersion { informationRow("Version", value: version) }
                    if let website = plugin.websiteURL { linkRow("Website", url: website) }
                    if let privacy = plugin.privacyPolicyURL { linkRow("Privacy Policy", url: privacy) }
                    if let terms = plugin.termsOfServiceURL { linkRow("Terms of Service", url: terms) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 48)
            .frame(maxWidth: CodexPluginLayoutMetrics.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var detailMenu: some View {
        Menu {
            if !plugin.installed && plugin.installPolicy == "AVAILABLE" {
                Button("Add") { onAction(.installPlugin(.init(plugin: plugin))) }
            }
            if plugin.supportsEnabledToggle {
                Button(plugin.enabled ? "Disable" : "Enable") {
                    onAction(.setPluginEnabled(.init(plugin: plugin), enabled: !plugin.enabled))
                }
            }
            if plugin.installed && plugin.installPolicy != "INSTALLED_BY_DEFAULT" {
                Button("Remove", role: .destructive) { onAction(.uninstallPlugin(.init(plugin: plugin))) }
            }
        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .disabled(isPending)
        .accessibilityLabel("More actions for \(plugin.displayName)")
    }

    private func informationRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(theme.colors.textSecondary).frame(width: 145, alignment: .leading)
            Text(value).foregroundStyle(theme.colors.textPrimary)
        }
        .font(theme.fonts.caption)
    }

    private func linkRow(_ label: String, url: String) -> some View {
        HStack {
            Text(label).foregroundStyle(theme.colors.textSecondary).frame(width: 145, alignment: .leading)
            if let destination = URL(string: url) {
                Link(destination: destination) { Image(systemName: "arrow.up.right") }
            }
        }
        .font(theme.fonts.caption)
    }
}

private extension String {
    var trimmedForPluginSearch: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CodexCatalogSectionPresentation {
    static func visibleCount(total: Int, collapsedLimit: Int, isExpanded: Bool) -> Int {
        isExpanded ? total : min(total, collapsedLimit)
    }

    static func moreLabel(names: [String], collapsedLimit: Int, isExpanded: Bool) -> String? {
        guard names.count > collapsedLimit else { return nil }
        if isExpanded { return "Show less" }

        let hidden = Array(names.dropFirst(collapsedLimit))
        let preview = hidden.prefix(2).joined(separator: ", ")
        let remaining = hidden.count - min(hidden.count, 2)
        if remaining > 0 { return "See \(preview), and \(remaining) more" }
        return "See \(preview)"
    }
}
