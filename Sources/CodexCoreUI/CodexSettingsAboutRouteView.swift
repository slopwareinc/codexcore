import SwiftUI
import CodexCore

public enum CodexSettingsRoute: String, CaseIterable, Identifiable, Sendable {
    case general
    case appearance
    case profile
    case configuration
    case git
    case integrations
    case about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .profile: return "Profile"
        case .configuration: return "Configuration"
        case .git: return "Git"
        case .integrations: return "Integrations"
        case .about: return "About"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "sun.max"
        case .profile: return "person.crop.circle"
        case .configuration: return "slider.horizontal.3"
        case .git: return "point.3.connected.trianglepath.dotted"
        case .integrations: return "puzzlepiece.extension"
        case .about: return "info.circle"
        }
    }

    var groupTitle: String {
        switch self {
        case .general, .appearance, .profile, .configuration:
            return "Personal"
        case .git:
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
        case .git:
            return ["branch", "pull request", "merge", "commit", "draft"]
        case .integrations:
            return ["mcp", "browser", "computer use", "plugins"]
        case .about:
            return ["version", "build", "metadata", "about"]
        }
    }
}

public enum CodexSettingsMergeMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case merge
    case squash

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .merge: return "Merge"
        case .squash: return "Squash"
        }
    }
}

public struct CodexGitSettings: Codable, Equatable, Sendable {
    public var branchPrefix: String
    public var mergeMethod: CodexSettingsMergeMethod
    public var createsDraftPullRequests: Bool
    public var alwaysForcePush: Bool
    public var commitInstructions: String
    public var pullRequestInstructions: String

    public init(
        branchPrefix: String = "codex/",
        mergeMethod: CodexSettingsMergeMethod = .merge,
        createsDraftPullRequests: Bool = false,
        alwaysForcePush: Bool = false,
        commitInstructions: String = "",
        pullRequestInstructions: String = ""
    ) {
        self.branchPrefix = branchPrefix
        self.mergeMethod = mergeMethod
        self.createsDraftPullRequests = createsDraftPullRequests
        self.alwaysForcePush = alwaysForcePush
        self.commitInstructions = commitInstructions
        self.pullRequestInstructions = pullRequestInstructions
    }

    public static var defaults: CodexGitSettings {
        CodexGitSettings()
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
    public let onBackToApp: (() -> Void)?

    @Binding private var appearanceSettings: CodexAppearanceSettings
    @Binding private var sidebarFontSize: Double
    @Binding private var approvalSelection: CodexApprovalSelection
    private let approvalOptions: [CodexApprovalSelection]
    @Binding private var modelSelection: CodexModelSelection
    private let modelOptions: [CodexModelSelection]
    @Binding private var reasoningSelection: CodexReasoningSelection
    @Binding private var isBottomPanelVisible: Bool
    @Binding private var gitSettings: CodexGitSettings

    private let sidebarFontSizeRange: ClosedRange<Double>

    public init(
        metadata: CodexAboutMetadata,
        accountSummary: CodexAccountMenuSummary = CodexAccountMenuSummary(displayName: "Codex", detail: "Available"),
        appearanceSettings: Binding<CodexAppearanceSettings>,
        sidebarFontSize: Binding<Double> = .constant(CodexAgentTheme.Fonts.SidebarTypography.defaultBaseTextSize),
        sidebarFontSizeRange: ClosedRange<Double> = CodexAgentTheme.Fonts.SidebarTypography.baseTextSizeRange,
        approvalSelection: Binding<CodexApprovalSelection> = .constant(.fullAccess),
        approvalOptions: [CodexApprovalSelection] = CodexApprovalSelection.defaultOptions,
        modelSelection: Binding<CodexModelSelection> = .constant(.appServerDefault),
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        reasoningSelection: Binding<CodexReasoningSelection> = .constant(.medium),
        isBottomPanelVisible: Binding<Bool> = .constant(false),
        gitSettings: Binding<CodexGitSettings> = .constant(.defaults),
        mcpServers: [CodexMCPServerStatus] = [],
        isLoadingMCPServers: Bool = false,
        onBackToApp: (() -> Void)? = nil
    ) {
        self.metadata = metadata
        self.accountSummary = accountSummary
        self._appearanceSettings = appearanceSettings
        self._sidebarFontSize = sidebarFontSize
        self.sidebarFontSizeRange = sidebarFontSizeRange
        self._approvalSelection = approvalSelection
        self.approvalOptions = approvalOptions
        self._modelSelection = modelSelection
        self.modelOptions = modelOptions
        self._reasoningSelection = reasoningSelection
        self._isBottomPanelVisible = isBottomPanelVisible
        self._gitSettings = gitSettings
        self.mcpServers = mcpServers
        self.isLoadingMCPServers = isLoadingMCPServers
        self.onBackToApp = onBackToApp
    }

    public var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider().overlay(theme.colors.border.opacity(0.7))
            contentPane
        }
        .background(theme.colors.surface)
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
                    .font(.system(size: 18, weight: .semibold))
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
        .codexGlass(Rectangle(), tint: theme.colors.surface.opacity(0.16))
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
                approvalOptions: approvalOptions,
                modelSelection: $modelSelection,
                modelOptions: modelOptions,
                reasoningSelection: $reasoningSelection,
                isBottomPanelVisible: $isBottomPanelVisible
            )
        case .appearance:
            CodexAppearanceSettingsView(
                settings: $appearanceSettings,
                sidebarFontSize: $sidebarFontSize,
                sidebarFontSizeRange: sidebarFontSizeRange
            )
        case .profile:
            CodexSettingsProfilePage(accountSummary: accountSummary, serverName: metadata.serverName)
        case .configuration:
            CodexSettingsConfigurationPage(metadata: metadata, approvalSelection: approvalSelection)
        case .git:
            CodexSettingsGitPage(settings: $gitSettings)
        case .integrations:
            CodexSettingsIntegrationsPage(mcpServers: mcpServers, isLoadingMCPServers: isLoadingMCPServers)
        case .about:
            CodexSettingsAboutPage(metadata: metadata)
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
        guard !normalizedSearchText.isEmpty else { return CodexSettingsRoute.allCases }
        return searchMatches
    }

    private var searchMatches: [CodexSettingsRoute] {
        guard !normalizedSearchText.isEmpty else { return CodexSettingsRoute.allCases }
        return CodexSettingsRoute.allCases.filter { route in
            ([route.title, route.groupTitle] + route.searchTerms)
                .contains { $0.localizedCaseInsensitiveContains(normalizedSearchText) }
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(theme.colors.textPrimary)
    }
}

public struct CodexSettingsGeneralPage: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding var approvalSelection: CodexApprovalSelection
    let approvalOptions: [CodexApprovalSelection]
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
                CodexSettingsReasoningRow(selection: $reasoningSelection)
                CodexSettingsToggleRow(
                    title: "Bottom panel",
                    detail: "Show the bottom panel control in the app workspace",
                    isOn: $isBottomPanelVisible
                )
                CodexSettingsDisabledRow(
                    title: "Default to projectless chat",
                    detail: "Start new chats without a project",
                    reason: "Not available in CodexCore yet"
                )
            }
            .settingsPanel(theme: theme)
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
                CodexSettingsDisabledRow(
                    title: "Profile analytics",
                    detail: "Usage stats, token charts, and public profile controls",
                    reason: "Not available in CodexCore yet"
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
                CodexSettingsReadOnlyRow(
                    title: "Workspace dependencies",
                    detail: "Bundled dependency runtime version",
                    value: metadata.versionLine,
                    systemImage: "archivebox"
                )
                CodexSettingsDisabledRow(
                    title: "Open config.toml",
                    detail: "Edit user configuration directly",
                    reason: "Not wired in CodexCore yet"
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

public struct CodexSettingsGitPage: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding var settings: CodexGitSettings

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CodexSettingsPageTitle("Git")
            VStack(spacing: 0) {
                CodexSettingsTextFieldRow(
                    title: "Branch prefix",
                    detail: "Prefix used when creating new branches in CodexCore",
                    text: $settings.branchPrefix
                )
                CodexSettingsMergeMethodRow(selection: $settings.mergeMethod)
                CodexSettingsToggleRow(
                    title: "Create draft pull requests",
                    detail: "Use draft pull requests by default when creating PRs from CodexCore",
                    isOn: $settings.createsDraftPullRequests
                )
                CodexSettingsToggleRow(
                    title: "Always force push",
                    detail: "Use --force-with-lease when pushing from CodexCore",
                    isOn: $settings.alwaysForcePush
                )
                CodexSettingsMultilineTextRow(
                    title: "Commit instructions",
                    detail: "Added to commit message generation prompts",
                    text: $settings.commitInstructions
                )
                CodexSettingsMultilineTextRow(
                    title: "Pull request instructions",
                    detail: "Added to PR title and description generation prompts",
                    text: $settings.pullRequestInstructions
                )
            }
            .settingsPanel(theme: theme)
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

public struct CodexSettingsAboutPage: View {
    @Environment(\.codexAgentTheme) private var theme

    let metadata: CodexAboutMetadata

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
        }
    }
}

public struct CodexAppearanceSettingsView: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding private var settings: CodexAppearanceSettings
    @Binding private var sidebarFontSize: Double
    private let sidebarFontSizeRange: ClosedRange<Double>

    public init(
        settings: Binding<CodexAppearanceSettings>,
        sidebarFontSize: Binding<Double>,
        sidebarFontSizeRange: ClosedRange<Double> = CodexAgentTheme.Fonts.SidebarTypography.baseTextSizeRange
    ) {
        self._settings = settings
        self._sidebarFontSize = sidebarFontSize
        self.sidebarFontSizeRange = sidebarFontSizeRange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CodexSettingsPageTitle("Appearance")
            CodexThemePresetPicker(preset: $settings.preset)
            VStack(spacing: 0) {
                CodexSettingsSliderRow(
                    title: "UI font size",
                    detail: "Adjust the base size used for CodexCore UI",
                    value: $settings.uiFontSize,
                    range: CodexAppearanceSettings.uiFontSizeRange,
                    suffix: "px"
                )
                CodexSidebarFontSizeControl(
                    fontSize: $sidebarFontSize,
                    range: sidebarFontSizeRange
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

    @Binding private var preset: CodexAgentThemePreset

    public init(preset: Binding<CodexAgentThemePreset>) {
        self._preset = preset
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Theme")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textPrimary)

                HStack(spacing: 8) {
                    ForEach(CodexAgentThemePreset.allCases) { option in
                        Button {
                            preset = option
                        } label: {
                            VStack(spacing: 8) {
                                CodexPresetSwatch(preset: option, isSelected: preset == option)
                                Text(option.displayName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(preset == option ? theme.colors.textPrimary : theme.colors.textTertiary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(option.displayName) preset")
                        .accessibilityAddTraits(preset == option ? .isSelected : [])
                    }
                }
            }
        }
        .settingsPanel(theme: theme)
    }
}

public struct CodexPresetSwatch: View {
    let preset: CodexAgentThemePreset
    let isSelected: Bool

    public init(preset: CodexAgentThemePreset, isSelected: Bool) {
        self.preset = preset
        self.isSelected = isSelected
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(swatchBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : .white.opacity(0.1), lineWidth: isSelected ? 2.2 : 0.8)
                }

            VStack(spacing: 5) {
                Circle()
                    .fill(preset.theme.colors.accent)
                    .frame(width: 12, height: 12)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(preset.theme.colors.textPrimary.opacity(0.55))
                    .frame(width: 24, height: 3)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(preset.theme.colors.textSecondary)
                    .frame(width: 16, height: 3)
            }
        }
        .frame(height: 64)
    }

    private var swatchBackground: Color {
        preset.theme.colors.canvas
    }
}

public struct CodexSettingsApprovalRow: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding var selection: CodexApprovalSelection
    let options: [CodexApprovalSelection]

    public var body: some View {
        CodexSettingsMenuRow(
            title: "Default permissions",
            detail: selection.detail,
            value: selection.displayName
        ) {
            ForEach(options) { option in
                Button(option.displayName) { selection = option }
            }
        }
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

    public var body: some View {
        CodexSettingsMenuRow(
            title: "Reasoning",
            detail: "Default reasoning effort for new turns",
            value: selection.displayName
        ) {
            ForEach(CodexReasoningSelection.defaultOptions) { option in
                Button(option.displayName) { selection = option }
            }
        }
    }
}

public struct CodexSettingsMergeMethodRow: View {
    @Binding var selection: CodexSettingsMergeMethod

    public var body: some View {
        CodexSettingsMenuRow(
            title: "Pull request merge method",
            detail: "Choose how CodexCore merges pull requests",
            value: selection.displayName
        ) {
            ForEach(CodexSettingsMergeMethod.allCases) { option in
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

public struct CodexSidebarFontSizeControl: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding private var fontSize: Double
    private let range: ClosedRange<Double>

    public init(
        fontSize: Binding<Double>,
        range: ClosedRange<Double> = CodexAgentTheme.Fonts.SidebarTypography.baseTextSizeRange
    ) {
        self._fontSize = fontSize
        self.range = range
    }

    public var body: some View {
        HStack(spacing: 18) {
            CodexSettingsRowLabel(title: "Sidebar font", detail: "Controls sidebar row text size", isEnabled: true)
            Spacer(minLength: 12)
            Slider(value: $fontSize, in: range, step: 1)
                .frame(width: 150)
            Text("\(Int(fontSize.rounded())) px")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: 52, alignment: .trailing)
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
