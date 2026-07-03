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
    @State private var searchQuery = ""
    @State private var selectedPluginID: String?
    @State private var selectedSkillID: String?

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
            selectedPluginID: selectedPluginID,
            selectedSkillID: selectedSkillID,
            launcherTarget: launcherTarget
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.colors.border)
            HStack(spacing: 0) {
                catalogColumn
                    .frame(minWidth: 360, idealWidth: 430, maxWidth: 500)
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
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Plugins")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Manage marketplace plugins, apps, MCPs, and skills.")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }

            Picker("Plugin route", selection: $primaryTab) {
                ForEach(CodexPluginRoutePrimaryTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 330)

            Spacer()

            if isLoadingPlugins || isLoadingSkills {
                ProgressView()
                    .controlSize(.small)
            }

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("Refresh plugins")
            .accessibilityLabel("Refresh plugins")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var catalogColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchField

            if primaryTab == .manage {
                manageTabs
            }

            statusMessages

            if primaryTab == .marketplace, searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                categoryCards
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if primaryTab == .skills || (primaryTab == .manage && manageTab == .skills) {
                        skillRows
                    } else {
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

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.colors.textTertiary)
            TextField("Search plugins", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(theme.fonts.chat)
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(theme.colors.surfaceElevated.opacity(0.72), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }

    private var manageTabs: some View {
        HStack(spacing: 6) {
            ForEach(routeState.manageCounts) { count in
                Button {
                    manageTab = count.tab
                    if count.tab == .skills {
                        primaryTab = .manage
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text(count.tab.title)
                            .font(theme.fonts.caption.weight(.semibold))
                        Text("\(count.count)")
                            .font(theme.fonts.micro)
                    }
                    .foregroundStyle(manageTab == count.tab ? theme.colors.textPrimary : theme.colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(manageTab == count.tab ? theme.colors.surfaceElevated.opacity(0.9) : theme.colors.surfaceSunken.opacity(0.35), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(count.tab.title), \(count.count)")
            }
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let error = pluginErrorMessage {
            statusText(error, color: theme.colors.danger)
        }
        if let error = skillErrorMessage {
            statusText(error, color: theme.colors.danger)
        }
        ForEach(pluginLoadErrors, id: \.self) { error in
            statusText(error, color: theme.colors.warning)
        }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(theme.fonts.caption)
            .foregroundStyle(color)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var categoryCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Categories")
                .font(theme.fonts.caption.weight(.semibold))
                .foregroundStyle(theme.colors.textTertiary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(routeState.categoryCards.prefix(4)) { card in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(card.title)
                                .font(theme.fonts.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text("\(card.count)")
                                .font(theme.fonts.micro)
                                .foregroundStyle(theme.colors.textTertiary)
                        }
                        Text(card.detail)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(10)
                    .background(theme.colors.surfaceElevated.opacity(0.54), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    private var pluginRows: some View {
        let plugins = routeState.visiblePlugins
        if plugins.isEmpty {
            emptyRow(primaryTab == .manage ? "No managed plugins" : "No plugins")
        } else {
            ForEach(plugins) { plugin in
                PluginCatalogRow(
                    plugin: plugin,
                    isSelected: routeState.selectedDetail?.title == plugin.displayName,
                    onSelect: {
                        selectedPluginID = plugin.id
                        selectedSkillID = nil
                    },
                    onToggleEnabled: {
                        onAction(.setPluginEnabled(CodexPluginActionTarget(plugin: plugin), enabled: !plugin.enabled))
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var skillRows: some View {
        let skills = routeState.visibleSkills
        if skills.isEmpty {
            emptyRow("No skills")
        } else {
            ForEach(skills) { skill in
                SkillCatalogRow(
                    skill: skill,
                    isSelected: routeState.selectedDetail?.title == skill.displayName,
                    onSelect: {
                        selectedSkillID = skill.id
                        selectedPluginID = nil
                    }
                )
            }
        }
    }

    private func emptyRow(_ title: String) -> some View {
        Text(title)
            .font(theme.fonts.caption)
            .foregroundStyle(theme.colors.textTertiary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.colors.surfaceElevated.opacity(0.28), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
    }

    @ViewBuilder
    private var detailPane: some View {
        if let detail = routeState.selectedDetail {
            PluginDetailPane(detail: detail, onAction: onAction)
                .padding(22)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Select a plugin")
                    .font(.system(size: 18, weight: .semibold))
                Text("Marketplace and Skills details appear here.")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            .padding(22)
        }
    }

    private func seedOrApplyLauncher() {
        if let target = launcherTarget {
            applyLauncherTarget(target)
            return
        }
        seedSelection()
    }

    private func applyLauncherTarget(_ target: CodexComposerPluginLauncher) {
        primaryTab = target.itemID == .browser ? .manage : .marketplace
        manageTab = .plugins
        searchQuery = target.searchQuery
        selectedSkillID = nil
        selectedPluginID = plugins.first { plugin in
            let preferred = target.preferredPluginNames.map { $0.lowercased() }
            let candidates = [plugin.name.lowercased(), plugin.displayName.lowercased(), plugin.id.lowercased()]
            return preferred.contains { preferredName in
                candidates.contains { candidate in
                    candidate == preferredName || candidate.contains(preferredName)
                }
            }
        }?.id
    }

    private func seedSelection() {
        if selectedPluginID == nil {
            selectedPluginID = plugins.first { $0.displayName.localizedCaseInsensitiveContains("Browser") }?.id ?? plugins.first?.id
        }
        if selectedSkillID == nil {
            selectedSkillID = skills.first?.id
        }
    }
}

private struct PluginCatalogRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let plugin: CodexPluginSummary
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleEnabled: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: plugin.installed ? "checkmark.circle.fill" : "puzzlepiece.extension")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(plugin.installed ? theme.colors.success : theme.colors.textTertiary)
                        .frame(width: 18)
                    Text(plugin.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { plugin.enabled },
                        set: { _ in onToggleEnabled() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!plugin.installed)
                    .accessibilityLabel("Plugin enabled")
                }

                Text(plugin.detail)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    pill(plugin.statusLabel)
                    pill(plugin.marketplaceDisplayName)
                    if let version = plugin.localVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
                        pill(version)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(11)
            .background(isSelected ? theme.colors.accentSoft.opacity(0.5) : theme.colors.surfaceElevated.opacity(0.64), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(isSelected ? theme.colors.accent : theme.colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func pill(_ title: String) -> some View {
        Text(title)
            .font(theme.fonts.micro)
            .foregroundStyle(theme.colors.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(theme.colors.surfaceSunken.opacity(0.5), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
    }
}

private struct SkillCatalogRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let skill: CodexSkillSummary
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: "hammer")
                        .foregroundStyle(theme.colors.textTertiary)
                    Text(skill.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(skill.statusLabel)
                        .font(theme.fonts.micro)
                        .foregroundStyle(skill.enabled ? theme.colors.success : theme.colors.textTertiary)
                }
                Text(skill.detail)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(2)
                Text(skill.scopeLabel)
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.textTertiary)
            }
            .padding(11)
            .background(isSelected ? theme.colors.accentSoft.opacity(0.5) : theme.colors.surfaceElevated.opacity(0.64), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(isSelected ? theme.colors.accent : theme.colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PluginDetailPane: View {
    @Environment(\.codexAgentTheme) private var theme

    let detail: CodexPluginRouteDetail
    let onAction: (CodexPluginRouteAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(detail.title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                    Text(detail.detail)
                        .font(theme.fonts.chat)
                        .foregroundStyle(theme.colors.textSecondary)
                    Text(detail.statusLabel)
                        .font(theme.fonts.caption.weight(.semibold))
                        .foregroundStyle(detail.isEnabled ? theme.colors.success : theme.colors.textTertiary)
                }

                Text(detail.description)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineSpacing(3)

                actionRow

                if let prompt = detail.prompt {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prompt")
                            .font(theme.fonts.caption.weight(.semibold))
                            .foregroundStyle(theme.colors.textTertiary)
                        Text(prompt)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textPrimary)
                            .padding(10)
                            .background(theme.colors.surfaceElevated.opacity(0.58), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                    }
                }

                metadataSection("Capabilities", detail.capabilities)
                metadataSection("Details", detail.metadata)
                metadataSection("Links", detail.legalLinks)
            }
            .frame(maxWidth: 700, alignment: .leading)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if let tryAction = detail.tryInChatAction {
                Button {
                    onAction(tryAction)
                } label: {
                    Label("Try in chat", systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)
            }

            if let primary = detail.primaryAction {
                Button(action: { onAction(primary) }) {
                    Text(primaryTitle)
                }
                .buttonStyle(.bordered)
            }

            if detail.canToggleEnabled, case .plugin(let target) = detail.kind {
                Button(detail.isEnabled ? "Disable" : "Enable") {
                    onAction(.setPluginEnabled(target, enabled: !detail.isEnabled))
                }
                .buttonStyle(.bordered)
            }

            if let title = detail.boundaryActionTitle {
                Button(title) {}
                    .buttonStyle(.bordered)
                    .disabled(true)
                    .help("\(title) is bounded until plugin installation and permissions are wired.")
            }

            Spacer()
        }
    }

    private var primaryTitle: String {
        if detail.canInstall { return "Install" }
        if detail.canUninstall { return "Uninstall" }
        return detail.isEnabled ? "Disable" : "Enable"
    }

    @ViewBuilder
    private func metadataSection(_ title: String, _ rows: [String]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textTertiary)
                ForEach(rows, id: \.self) { row in
                    Text(row)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
            }
        }
    }
}
