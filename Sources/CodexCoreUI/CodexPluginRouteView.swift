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
    public let marketplaces: [CodexMarketplaceSummary]
    public let apps: [CodexAppSummary]
    public let skills: [CodexSkillSummary]
    public let mcpServers: [CodexMCPServerStatus]
    public let isLoadingPlugins: Bool
    public let isLoadingMCPServers: Bool
    public let isLoadingApps: Bool
    public let isLoadingSkills: Bool
    public let pluginErrorMessage: String?
    public let mcpErrorMessage: String?
    public let appErrorMessage: String?
    public let skillErrorMessage: String?
    public let marketplaceActionErrors: [String: String]
    public let pluginLoadErrors: [String]
    public let skillLoadErrors: [String]
    public let pluginReadDetails: [String: CodexPluginReadDetail]
    public let loadingPluginReadIDs: Set<String>
    public let pluginReadErrors: [String: String]
    public let launcherTarget: CodexComposerPluginLauncher?
    public let pendingPluginIDs: Set<String>
    public let pendingSkillIDs: Set<String>
    public let pendingAppIDs: Set<String>
    public let pendingMarketplaceIDs: Set<String>
    public let onLoad: () -> Void
    public let onRefresh: () -> Void
    public let onAction: (CodexPluginRouteAction) -> Void
    public let onReadPlugin: (CodexPluginSummary) -> Void
    public let onOpenMCPDetails: () -> Void

    @State private var page: CodexPluginRoutePage
    @State private var browsePage: CodexPluginRoutePage
    @State private var manageTab: CodexPluginManageTab
    @State private var filter: CodexPluginCatalogFilter = .all
    @State private var searchQuery = ""
    @State private var selectedPluginID: String?
    @State private var pluginDetailReturnPage: CodexPluginRoutePage = .plugins
    @State private var skillDetailID: String?
    @State private var expandedMarketplaceSections: Set<String> = []
    @State private var expandedSkillSections: Set<String> = []
    @State private var marketplaceSource = ""
    @FocusState private var isSearchFocused: Bool

    public init(
        plugins: [CodexPluginSummary],
        marketplaces: [CodexMarketplaceSummary] = [],
        apps: [CodexAppSummary] = [],
        skills: [CodexSkillSummary],
        mcpServers: [CodexMCPServerStatus],
        isLoadingPlugins: Bool = false,
        isLoadingMCPServers: Bool = false,
        isLoadingApps: Bool = false,
        isLoadingSkills: Bool = false,
        pluginErrorMessage: String? = nil,
        mcpErrorMessage: String? = nil,
        appErrorMessage: String? = nil,
        skillErrorMessage: String? = nil,
        marketplaceActionErrors: [String: String] = [:],
        pluginLoadErrors: [String] = [],
        skillLoadErrors: [String] = [],
        pluginReadDetails: [String: CodexPluginReadDetail] = [:],
        loadingPluginReadIDs: Set<String> = [],
        pluginReadErrors: [String: String] = [:],
        launcherTarget: CodexComposerPluginLauncher? = nil,
        pendingPluginIDs: Set<String> = [],
        pendingSkillIDs: Set<String> = [],
        pendingAppIDs: Set<String> = [],
        pendingMarketplaceIDs: Set<String> = [],
        initialTab: CodexPluginRoutePrimaryTab = .marketplace,
        initialManageTab: CodexPluginManageTab = .plugins,
        onLoad: @escaping () -> Void = {},
        onRefresh: @escaping () -> Void,
        onAction: @escaping (CodexPluginRouteAction) -> Void,
        onReadPlugin: @escaping (CodexPluginSummary) -> Void = { _ in },
        onOpenMCPDetails: @escaping () -> Void = {}
    ) {
        self.plugins = plugins
        self.marketplaces = marketplaces
        self.apps = apps
        self.skills = skills
        self.mcpServers = mcpServers
        self.isLoadingPlugins = isLoadingPlugins
        self.isLoadingMCPServers = isLoadingMCPServers
        self.isLoadingApps = isLoadingApps
        self.isLoadingSkills = isLoadingSkills
        self.pluginErrorMessage = pluginErrorMessage
        self.mcpErrorMessage = mcpErrorMessage
        self.appErrorMessage = appErrorMessage
        self.skillErrorMessage = skillErrorMessage
        self.marketplaceActionErrors = marketplaceActionErrors
        self.pluginLoadErrors = pluginLoadErrors
        self.skillLoadErrors = skillLoadErrors
        self.pluginReadDetails = pluginReadDetails
        self.loadingPluginReadIDs = loadingPluginReadIDs
        self.pluginReadErrors = pluginReadErrors
        self.launcherTarget = launcherTarget
        self.pendingPluginIDs = pendingPluginIDs
        self.pendingSkillIDs = pendingSkillIDs
        self.pendingAppIDs = pendingAppIDs
        self.pendingMarketplaceIDs = pendingMarketplaceIDs
        let initialPage: CodexPluginRoutePage = switch initialTab {
        case .marketplace: .plugins
        case .skills: .skills
        case .manage: .manage
        }
        _page = State(initialValue: initialPage)
        _browsePage = State(initialValue: initialPage == .skills ? .skills : .plugins)
        _manageTab = State(initialValue: initialManageTab)
        self.onLoad = onLoad
        self.onRefresh = onRefresh
        self.onAction = onAction
        self.onReadPlugin = onReadPlugin
        self.onOpenMCPDetails = onOpenMCPDetails
    }

    private var isLoading: Bool {
        switch page {
        case .plugins, .pluginDetail: isLoadingPlugins
        case .skills: isLoadingSkills
        case .manage:
            switch manageTab {
            case .plugins, .marketplace: isLoadingPlugins
            case .apps: isLoadingApps
            case .mcps: isLoadingMCPServers
            case .skills: isLoadingSkills
            }
        }
    }

    private var isManageMode: Bool {
        if page == .manage { return true }
        return isPluginDetail && pluginDetailReturnPage == .manage
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
        .onChange(of: plugins) { _, refreshed in
            guard case .pluginDetail(let id) = page,
                  let plugin = refreshed.first(where: { $0.id == id }),
                  pluginReadDetails[id] == nil,
                  !loadingPluginReadIDs.contains(id) else { return }
            onReadPlugin(plugin)
        }
        .onChange(of: pendingMarketplaceIDs) { previous, current in
            let source = marketplaceSource.trimmingCharacters(in: .whitespacesAndNewlines)
            if !source.isEmpty, previous.contains(source), !current.contains(source), marketplaceActionErrors[source] == nil {
                marketplaceSource = ""
            }
        }
        .onChange(of: selectedPluginID) { _, id in
            guard let id, let plugin = plugins.first(where: { $0.id == id }) else { return }
            pluginDetailReturnPage = page == .manage ? .manage : .plugins
            page = .pluginDetail(id)
            onReadPlugin(plugin)
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
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                if isPluginDetail {
                    Button {
                        page = pluginDetailReturnPage
                        selectedPluginID = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
                topModeTabs
                if !isPluginDetail {
                    searchField(placeholder: searchPlaceholder)
                        .frame(maxWidth: 550)
                    if isLoading { CodexSpinner(size: .small) }
                } else {
                    Spacer()
                }
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise").frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingPlugins || isLoadingApps || isLoadingSkills || isLoadingMCPServers)
                .help("Refresh plugins and skills")
                .accessibilityLabel("Refresh plugins and skills")
                .keyboardShortcut("r", modifiers: .command)
                createMenu
            }
            .padding(.horizontal, 24)
            .frame(height: 66)

            if !isPluginDetail {
                ScrollView(.horizontal, showsIndicators: false) {
                    Group {
                        if page == .manage {
                            manageTabs
                        } else {
                            browseTabs
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .frame(height: 48)
            }
            Divider().overlay(theme.colors.border)
        }
        .background(theme.colors.surface)
    }

    private var topModeTabs: some View {
        HStack(spacing: 0) {
            topTab("Browse", selected: !isManageMode) {
                page = browsePage
                searchQuery = ""
                selectedPluginID = nil
            }
            topTab("Manage", selected: isManageMode) {
                page = .manage
                searchQuery = ""
                selectedPluginID = nil
            }
        }
        .padding(2)
        .background(theme.colors.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.colors.border))
        .accessibilityLabel("Browse or manage integrations")
    }

    private func topTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(theme.fonts.chat.weight(.medium))
                .foregroundStyle(selected ? theme.colors.textPrimary : theme.colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? theme.colors.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var createMenu: some View {
        let isSkillContext = page == .skills || (page == .manage && manageTab == .skills)
        return Menu {
            Button(isSkillContext ? "Create skill" : "Create plugin") {
                onAction(.tryInChat(prompt: isSkillContext
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
                Text("Add")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .foregroundStyle(Color.white)
            .background(theme.colors.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Add a plugin, skill, or marketplace")
        .accessibilityLabel("Add")
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
                    readDetail: pluginReadDetails[plugin.id],
                    isLoadingReadDetail: loadingPluginReadIDs.contains(plugin.id),
                    readError: pluginReadErrors[plugin.id],
                    isPending: isPending(plugin),
                    onAction: onAction
                )
            } else {
                emptyState(title: "Plugin unavailable", detail: "Refresh the marketplace and try again.")
            }
        }
    }

    private var marketplacePage: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    statusMessages
                    if isLoadingPlugins && plugins.isEmpty {
                        loadingRows
                    } else if let pluginErrorMessage, plugins.isEmpty {
                        emptyState(title: "Couldn’t load plugins", detail: pluginErrorMessage)
                    } else if searchQuery.trimmedForPluginSearch.isEmpty {
                        addedSection
                        marketplaceScopeTabs
                        marketplaceSections(availableWidth: max(0, min(geometry.size.width - 48, CodexPluginLayoutMetrics.browseContentWidth)))
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
                .frame(maxWidth: CodexPluginLayoutMetrics.browseContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var skillsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statusMessages
                if isLoadingSkills && skills.isEmpty {
                    loadingRows
                } else if let skillErrorMessage, skills.isEmpty {
                    emptyState(title: "Couldn’t load skills", detail: skillErrorMessage)
                } else if visibleSkills.isEmpty {
                    emptyState(title: "No skills found", detail: "Try another search.")
                } else {
                    ForEach(groupedSkills, id: \.title) { group in
                        skillSection(group.title, skills: group.skills)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: CodexPluginLayoutMetrics.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var managePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusMessages
            manageInventory
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 30)
        .frame(maxWidth: 1_080, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }

    private func searchField(placeholder: String) -> some View {
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
            ForEach([CodexPluginCatalogFilter.all, .openAI, .workspace, .personal], id: \.self) { option in
                topTab(option.title, selected: filter == option) { filter = option }
            }
        }
        .accessibilityLabel("Marketplace source")
    }

    @ViewBuilder private func marketplaceSections(availableWidth: CGFloat) -> some View {
        let visible = visiblePlugins
        if visible.isEmpty {
            emptyState(title: "No plugins found", detail: "Choose another marketplace section.")
        } else {
            let featured = featuredPlugins
            if !featured.isEmpty {
                marketplaceSection("Featured", plugins: featured, collapsedLimit: 4, availableWidth: availableWidth)
            }
            ForEach(groupedMarketplacePlugins(excluding: Set(featured.map(\.id))), id: \.title) { group in
                marketplaceSection(group.title, plugins: group.plugins, collapsedLimit: 6, availableWidth: availableWidth)
            }
        }
    }

    private func marketplaceSection(_ title: String, plugins: [CodexPluginSummary], collapsedLimit: Int, availableWidth: CGFloat) -> some View {
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
            LazyVGrid(columns: CodexPluginBrowseLayoutPolicy.columns(availableWidth: availableWidth), spacing: 8) {
                ForEach(displayedPlugins) { plugin in
                    OfficialPluginRow(
                        plugin: plugin,
                        showsToggle: false,
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
            if visiblePlugins.isEmpty {
                emptyState(title: "No plugins found", detail: "Try a different search.")
            } else {
                LazyVStack(spacing: CodexPluginLayoutMetrics.rowSpacing) {
                    ForEach(visiblePlugins) { plugin in
                        OfficialPluginRow(
                            plugin: plugin,
                            showsToggle: false,
                            isPending: isPending(plugin),
                            onOpen: { selectedPluginID = plugin.id },
                            onAction: onAction
                        )
                    }
                }
            }
        }
    }

    private var manageTabs: some View {
        HStack(spacing: 28) {
            ForEach(manageCounts) { count in
                secondaryTab(
                    "\(count.tab.title)  \(count.count)",
                    selected: manageTab == count.tab
                ) {
                    manageTab = count.tab
                    searchQuery = ""
                    selectedPluginID = nil
                }
                .accessibilityLabel("\(count.tab.title) \(count.count)")
            }
        }
    }

    private var browseTabs: some View {
        HStack(spacing: 28) {
            secondaryTab("Plugins", selected: page == .plugins) {
                browsePage = .plugins
                page = .plugins
                searchQuery = ""
                selectedPluginID = nil
            }
            secondaryTab("Skills", selected: page == .skills) {
                browsePage = .skills
                page = .skills
                searchQuery = ""
                selectedPluginID = nil
            }
        }
        .accessibilityLabel("Browse plugins or skills")
    }

    private func secondaryTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Text(title)
                    .font(theme.fonts.caption.weight(.medium))
                    .foregroundStyle(selected ? theme.colors.accentText : theme.colors.textSecondary)
                    .fixedSize(horizontal: true, vertical: false)
                Rectangle()
                    .fill(selected ? theme.colors.accent : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var manageInventory: some View {
        switch manageTab {
        case .plugins:
            let visible = visiblePlugins
            if isLoadingPlugins && visible.isEmpty {
                loadingRows
            } else if visible.isEmpty {
                emptyState(title: "No plugins", detail: "Installed plugins appear here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { plugin in
                            OfficialPluginRow(
                                plugin: plugin,
                                showsToggle: true,
                                isPending: isPending(plugin),
                                onOpen: { selectedPluginID = plugin.id },
                                onAction: onAction
                            )
                            if plugin.id != visible.last?.id {
                                Divider().overlay(theme.colors.border)
                            }
                        }
                    }
                    .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.colors.border))
                }
            }
        case .apps:
            ScrollView { LazyVStack(spacing: CodexPluginLayoutMetrics.rowSpacing) { managedAppRows } }
        case .mcps:
            VStack(alignment: .trailing, spacing: 10) {
                Button("Manage MCP servers", action: onOpenMCPDetails)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                ScrollView { LazyVStack(spacing: CodexPluginLayoutMetrics.rowSpacing) { mcpRows } }
            }
        case .skills:
            ScrollView { LazyVStack(spacing: CodexPluginLayoutMetrics.rowSpacing) { managedSkillRows } }
        case .marketplace:
            marketplaceManagement
        }
    }

    private var marketplaceManagement: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField("Marketplace source URL or path", text: $marketplaceSource)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addMarketplace)
                Button(action: addMarketplace) {
                    if pendingMarketplaceIDs.contains(marketplaceSource.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        CodexSpinner(size: .small)
                    } else {
                        Text("Add")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(marketplaceSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || pendingMarketplaceIDs.contains(marketplaceSource.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            Text("Only sources you enter are registered. CodexCore does not discover marketplaces from local caches or files.")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
            ScrollView {
                LazyVStack(spacing: CodexPluginLayoutMetrics.rowSpacing) {
                    if visibleMarketplaces.isEmpty {
                        emptyState(title: "No registered marketplaces", detail: "Marketplaces reported by Codex appear here.")
                    } else {
                        ForEach(visibleMarketplaces) { marketplace in
                            marketplaceRow(marketplace)
                        }
                    }
                }
            }
        }
    }

    private func marketplaceRow(_ marketplace: CodexMarketplaceSummary) -> some View {
        let isPending = pendingMarketplaceIDs.contains(marketplace.name)
        return HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .frame(width: 36, height: 36)
                .background(theme.colors.surfaceElevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(marketplace.displayName).font(theme.fonts.label)
                Text(marketplace.path?.nilIfBlank ?? "Path not reported by Codex")
                    .font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(1)
            }
            Spacer()
            Text("\(marketplace.pluginCount) \(marketplace.pluginCount == 1 ? "plugin" : "plugins")")
                .font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
            if isPending {
                CodexSpinner(size: .small)
            } else {
                Button("Upgrade") { onAction(.upgradeMarketplace(.init(marketplace: marketplace))) }
                    .buttonStyle(.bordered)
                Button("Remove", role: .destructive) { onAction(.removeMarketplace(.init(marketplace: marketplace))) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: CodexPluginLayoutMetrics.rowHeight)
    }

    private func addMarketplace() {
        let source = marketplaceSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        onAction(.addMarketplace(source: source))
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
        let visible = visibleSkills
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
        let visible = visibleApps
        if isLoadingApps && visible.isEmpty {
            loadingRows
        } else if let appErrorMessage, visible.isEmpty {
            emptyState(title: "Couldn’t load apps", detail: appErrorMessage)
        } else if visible.isEmpty {
            emptyState(title: "No apps", detail: "Installed and available apps appear here.")
        } else {
            ForEach(visible) { app in
                let isPending = pendingAppIDs.contains(app.id)
                HStack(spacing: 12) {
                    CodexPluginIconView(
                        reference: CodexPluginIconReference(logo: app.logoURL, logoDark: app.logoURLDark),
                        size: 36,
                        fallbackSystemName: "app.dashed"
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(theme.fonts.label).lineLimit(1)
                        Text(appDetail(app)).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Text(isPending ? "Updating" : CodexPluginStatusPresentation.appLabel(for: app))
                        .font(theme.fonts.caption.weight(.medium))
                        .foregroundStyle(theme.colors.textSecondary)
                    if app.isInstalled, let enabled = app.runtimeEnabled {
                        Toggle("", isOn: Binding(
                            get: { enabled },
                            set: { onAction(.setAppEnabled(.init(app: app), enabled: $0)) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(isPending)
                        .accessibilityLabel("Set \(app.name) local execution enabled")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: CodexPluginLayoutMetrics.rowHeight)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(app.name), \(isPending ? "Updating" : CodexPluginStatusPresentation.appLabel(for: app))")
            }
        }
    }

    @ViewBuilder private var mcpRows: some View {
        let visible = visibleMCPServers
        if isLoadingMCPServers && visible.isEmpty {
            loadingRows
        } else if let mcpErrorMessage, visible.isEmpty {
            emptyState(title: "Couldn’t load MCPs", detail: mcpErrorMessage)
        } else if visible.isEmpty {
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
                        if let error = server.error?.nilIfBlank {
                            Text(error).font(theme.fonts.caption).foregroundStyle(theme.colors.danger).lineLimit(1)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(CodexMCPManageStatusPresentation.configurationLabel(for: server))
                        Text(CodexMCPManageStatusPresentation.runtimeLabel(for: server))
                            .foregroundStyle(server.error == nil ? theme.colors.textSecondary : theme.colors.danger)
                        Text(CodexMCPManageStatusPresentation.authenticationLabel(for: server))
                    }
                    .font(theme.fonts.caption.weight(.medium))
                    .foregroundStyle(theme.colors.textSecondary)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 78)
                .accessibilityElement(children: .combine)
                .accessibilityLabel([
                    server.displayName,
                    CodexMCPManageStatusPresentation.configurationLabel(for: server),
                    CodexMCPManageStatusPresentation.runtimeLabel(for: server),
                    CodexMCPManageStatusPresentation.authenticationLabel(for: server)
                ].joined(separator: ", "))
            }
        }
    }

    @ViewBuilder private var statusMessages: some View {
        if page == .skills || (page == .manage && manageTab == .skills) {
            if let skillErrorMessage { statusBanner(skillErrorMessage, color: theme.colors.danger) }
            ForEach(skillLoadErrors, id: \.self) { statusBanner($0, color: theme.colors.warning) }
        } else if page == .manage && manageTab == .apps {
            if let appErrorMessage { statusBanner(appErrorMessage, color: theme.colors.danger) }
        } else if page == .manage && manageTab == .mcps {
            if let mcpErrorMessage { statusBanner(mcpErrorMessage, color: theme.colors.danger) }
        } else {
            if let pluginErrorMessage { statusBanner(pluginErrorMessage, color: theme.colors.danger) }
            if page == .manage, manageTab == .marketplace {
                ForEach(marketplaceActionErrors.keys.sorted(), id: \.self) { key in
                    if let message = marketplaceActionErrors[key] {
                        statusBanner("\(key): \(message)", color: theme.colors.danger)
                    }
                }
            }
            ForEach(pluginLoadErrors, id: \.self) { statusBanner($0, color: theme.colors.warning) }
        }
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

    private var groupedSkills: [(title: String, skills: [CodexSkillSummary])] {
        let order = ["Personal", "Repo", "Admin", "System", "Skill"]
        let groups = Dictionary(grouping: visibleSkills, by: \.scopeLabel)
        return groups.map { (title: $0.key, skills: $0.value) }.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.title) ?? order.count
            let right = order.firstIndex(of: rhs.title) ?? order.count
            return left == right
                ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                : left < right
        }
    }

    private var visibleApps: [CodexAppSummary] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return apps }
        return apps.filter { app in
            [app.name, app.description ?? "", app.runtimeName ?? "", app.pluginDisplayNames?.joined(separator: " ") ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var manageCounts: [CodexPluginManageCount] {
        [
            .init(tab: .plugins, count: plugins.filter(\.installed).count),
            .init(tab: .apps, count: apps.count),
            .init(tab: .mcps, count: mcpServers.count),
            .init(tab: .skills, count: skills.count),
            .init(tab: .marketplace, count: marketplaces.count),
        ]
    }

    private var visiblePlugins: [CodexPluginSummary] {
        let inventory = page == .manage ? plugins.filter(\.installed) : plugins.filter(matchesMarketplaceFilter)
        let needle = normalizedSearch
        guard !needle.isEmpty else { return inventory }
        return inventory.filter { plugin in
            [
                plugin.name,
                plugin.displayName,
                plugin.detail,
                plugin.marketplaceDisplayName,
                plugin.category ?? "",
                plugin.developerName ?? "",
                plugin.capabilities.joined(separator: " "),
                plugin.keywords.joined(separator: " ")
            ].contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var featuredPlugins: [CodexPluginSummary] {
        let featured = plugins.filter(\.isFeatured)
        let candidates = featured.isEmpty ? Array(plugins.prefix(2)) : featured
        let visibleIDs = Set(visiblePlugins.map(\.id))
        return candidates.filter { visibleIDs.contains($0.id) }
    }

    private var visibleSkills: [CodexSkillSummary] {
        let needle = normalizedSearch
        guard !needle.isEmpty else { return skills }
        return skills.filter { skill in
            [skill.name, skill.displayName, skill.detail, skill.description, skill.path, skill.scopeLabel]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var visibleMCPServers: [CodexMCPServerStatus] {
        let needle = normalizedSearch
        guard !needle.isEmpty else { return mcpServers }
        return mcpServers.filter { server in
            [server.name, server.displayName, server.detail ?? "", server.inventorySummary]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var visibleMarketplaces: [CodexMarketplaceSummary] {
        let needle = normalizedSearch
        guard !needle.isEmpty else { return marketplaces }
        return marketplaces.filter { marketplace in
            [marketplace.name, marketplace.displayName, marketplace.path ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var normalizedSearch: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesMarketplaceFilter(_ plugin: CodexPluginSummary) -> Bool {
        switch filter {
        case .all:
            true
        case .openAI:
            plugin.developerName?.localizedCaseInsensitiveContains("OpenAI") == true
                || plugin.marketplaceName.localizedCaseInsensitiveContains("openai")
        case .workspace:
            plugin.sourceType == "local" && plugin.sourceDetail?.contains("/.codex/") != true
        case .personal:
            plugin.sourceType == "local" || plugin.marketplaceName.localizedCaseInsensitiveContains("personal")
        }
    }

    private func appDetail(_ app: CodexAppSummary) -> String {
        app.description?.nilIfBlank
            ?? app.pluginDisplayNames?.joined(separator: ", ").nilIfBlank
            ?? app.runtimeName?.nilIfBlank
            ?? (app.isInstalled ? "Installed app" : "Available app")
    }

    private var isPluginDetail: Bool {
        if case .pluginDetail = page { return true }
        return false
    }

    private var searchPlaceholder: String {
        if page == .skills { return "Search skills" }
        if page == .plugins { return "Search plugins" }
        return switch manageTab {
        case .plugins: "Search plugins"
        case .apps: "Search apps"
        case .mcps: "Search MCP servers"
        case .skills: "Search skills"
        case .marketplace: "Search marketplaces"
        }
    }

    private func groupedMarketplacePlugins(excluding excluded: Set<String>) -> [(title: String, plugins: [CodexPluginSummary])] {
        var order: [String] = []
        var groups: [String: [CodexPluginSummary]] = [:]
        for plugin in visiblePlugins where !excluded.contains(plugin.id) {
            let title = plugin.category?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "Other"
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(plugin)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private func pluginIcon(for skill: CodexSkillSummary) -> CodexPluginIconReference {
        CodexPluginIconReference(logo: skill.iconSmall ?? skill.iconLarge)
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
                page = browsePage
            case .skills, .plugins:
                break
            }
        }
    }
}

private struct OfficialPluginRow: View {
    @Environment(\.codexAgentTheme) private var theme
    let plugin: CodexPluginSummary
    let showsToggle: Bool
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
                        if showsToggle {
                            Text("\(plugin.marketplaceDisplayName) · \(plugin.sourceLabel)")
                                .font(theme.fonts.caption)
                                .foregroundStyle(theme.colors.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .trailing, spacing: 3) {
                Text(CodexPluginStatusPresentation.label(for: plugin, isPending: isPending))
                    .font(theme.fonts.caption.weight(.medium))
                    .foregroundStyle(plugin.isAdminDisabled ? theme.colors.danger : theme.colors.textSecondary)
                    .lineLimit(1)
                if showsToggle, let reason = plugin.disabledReason?.nilIfBlank {
                    Text(reason)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                }
            }
            .accessibilityLabel("Status: \(CodexPluginStatusPresentation.label(for: plugin, isPending: isPending))")
            if showsToggle, plugin.supportsEnabledToggle {
                Toggle("", isOn: Binding(
                    get: { plugin.enabled },
                    set: { onAction(.setPluginEnabled(.init(plugin: plugin), enabled: $0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isPending)
                .accessibilityLabel("Set \(plugin.displayName) enabled")
            } else if !showsToggle, plugin.canInstall {
                Button { onAction(.installPlugin(.init(plugin: plugin))) } label: {
                    if isPending { ProgressView().controlSize(.small) } else { Text("Add") }
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isPending)
            } else if !plugin.isInstalledByAdmin || plugin.canUninstall || plugin.defaultPrompt != nil {
                pluginMenu
                    .disabled(isPending)
            }
        }
        .padding(.horizontal, showsToggle ? 18 : 10)
        .frame(minHeight: showsToggle ? 92 : CodexPluginLayoutMetrics.rowHeight)
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
            if plugin.canUninstall {
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
            Text(isPending ? "Updating" : skill.statusLabel)
                .font(theme.fonts.caption.weight(.medium))
                .foregroundStyle(theme.colors.textSecondary)
            if showsToggle {
                Toggle("", isOn: Binding(
                    get: { skill.enabled },
                    set: { onAction(.setSkillEnabled(.init(skill: skill), enabled: $0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isPending)
                .accessibilityLabel("Set \(skill.displayName) enabled")
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
                Text("Skill removal is managed outside CodexCore")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
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
        .frame(
            minWidth: 560,
            idealWidth: 760,
            maxWidth: 900,
            minHeight: 420,
            idealHeight: 620,
            maxHeight: 780
        )
        .background(theme.colors.surface)
    }
}

private struct OfficialPluginDetailPage: View {
    @Environment(\.codexAgentTheme) private var theme
    let plugin: CodexPluginSummary
    let readDetail: CodexPluginReadDetail?
    let isLoadingReadDetail: Bool
    let readError: String?
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
                        HStack(spacing: 6) {
                            ForEach(plugin.stateLabels, id: \.self) { label in
                                Text(label)
                                    .font(theme.fonts.caption.weight(.medium))
                                    .foregroundStyle(label == "Disabled by admin" ? theme.colors.danger : theme.colors.textSecondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(theme.colors.surfaceElevated, in: Capsule())
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Status: \(plugin.stateLabels.joined(separator: ", "))")
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

                Text(readDetail?.description ?? plugin.longDescription?.nilIfBlank ?? plugin.detail)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineSpacing(4)

                if isLoadingReadDetail {
                    HStack(spacing: 8) {
                        CodexSpinner(size: .small)
                        Text("Loading plugin relationships")
                    }
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                } else if let readError {
                    Label(readError, systemImage: "exclamationmark.triangle.fill")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.danger)
                }

                if let readDetail {
                    relationshipSection("Apps", values: readDetail.appNames)
                    relationshipSection("App templates", values: readDetail.appTemplateNames)
                    relationshipSection("MCP servers", values: readDetail.mcpServerNames)
                    relationshipSection("Skills", values: readDetail.skillNames)
                    relationshipSection("Hooks", values: readDetail.hookNames)
                    relationshipSection("Scheduled tasks", values: readDetail.scheduledTaskNames)
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
                    if let shareURL = readDetail?.shareURL { linkRow("Share", url: shareURL) }
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
            if plugin.canInstall {
                Button("Add") { onAction(.installPlugin(.init(plugin: plugin))) }
            }
            if plugin.supportsEnabledToggle {
                Button(plugin.enabled ? "Disable" : "Enable") {
                    onAction(.setPluginEnabled(.init(plugin: plugin), enabled: !plugin.enabled))
                }
            }
            if plugin.canUninstall {
                Button("Remove", role: .destructive) { onAction(.uninstallPlugin(.init(plugin: plugin))) }
            }
        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .disabled(isPending)
        .accessibilityLabel("More actions for \(plugin.displayName)")
    }

    @ViewBuilder private func relationshipSection(_ title: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text("\(title)  \(values.count)")
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text(value)
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.textPrimary)
                }
            }
        }
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
