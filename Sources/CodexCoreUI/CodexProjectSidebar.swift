import SwiftUI

public struct CodexProjectSidebar: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var showsOlderProjects = false

    let serverName: String?
    let accountSummary: CodexAccountMenuSummary
    let isThreadReady: Bool
    let snapshot: CodexSidebarSnapshot
    let onNewChat: () -> Void
    let onOpenSearch: () -> Void
    let onSelectRoute: (CodexAppRoute) -> Void
    let onToggleCollapsed: () -> Void
    let onToggleProject: (String) -> Void
    let onStartProjectChat: (String) -> Void
    let onSelectProject: (String) -> Void
    let onOpenFolder: () -> Void
    let onSelectChat: (CodexThreadSummary) -> Void
    let onTogglePinChat: (CodexThreadSummary) -> Void
    let onArchiveChat: (CodexThreadSummary) -> Void

    public init(
        serverName: String?,
        accountSummary: CodexAccountMenuSummary = CodexAccountMenuSummary(displayName: "Codex", detail: "Available"),
        isThreadReady: Bool,
        snapshot: CodexSidebarSnapshot,
        onNewChat: @escaping () -> Void,
        onOpenSearch: @escaping () -> Void,
        onSelectRoute: @escaping (CodexAppRoute) -> Void,
        onToggleCollapsed: @escaping () -> Void,
        onToggleProject: @escaping (String) -> Void,
        onStartProjectChat: @escaping (String) -> Void,
        onSelectProject: @escaping (String) -> Void,
        onOpenFolder: @escaping () -> Void,
        onSelectChat: @escaping (CodexThreadSummary) -> Void,
        onTogglePinChat: @escaping (CodexThreadSummary) -> Void,
        onArchiveChat: @escaping (CodexThreadSummary) -> Void
    ) {
        self.serverName = serverName
        self.accountSummary = accountSummary
        self.isThreadReady = isThreadReady
        self.snapshot = snapshot
        self.onNewChat = onNewChat
        self.onOpenSearch = onOpenSearch
        self.onSelectRoute = onSelectRoute
        self.onToggleCollapsed = onToggleCollapsed
        self.onToggleProject = onToggleProject
        self.onStartProjectChat = onStartProjectChat
        self.onSelectProject = onSelectProject
        self.onOpenFolder = onOpenFolder
        self.onSelectChat = onSelectChat
        self.onTogglePinChat = onTogglePinChat
        self.onArchiveChat = onArchiveChat
    }

    public var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: snapshot.isCollapsed ? 8 : 22) {
                    routeRows
                    pinnedSection
                    projectListSection
                    olderProjectsSection
                    settingsSection
                }
                .padding(.horizontal, snapshot.isCollapsed ? 8 : 16)
                .padding(.top, 10)
                .padding(.bottom, 18)
            }

            accountFooter
        }
        .frame(
            minWidth: snapshot.isCollapsed ? SidebarMetrics.collapsedWidth : SidebarMetrics.expandedWidth,
            idealWidth: snapshot.isCollapsed ? SidebarMetrics.collapsedWidth : SidebarMetrics.expandedWidth,
            maxWidth: snapshot.isCollapsed ? SidebarMetrics.collapsedWidth : SidebarMetrics.expandedWidth
        )
        .frame(maxHeight: .infinity)
        .codexGlass(Rectangle(), tint: theme.colors.surface.opacity(0.18))
        .background(theme.colors.surface.opacity(0.26))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.colors.border.opacity(0.45))
                .frame(width: 1)
        }
    }

    private var accountFooter: some View {
        Button {
            onSelectRoute(.codexMobile)
        } label: {
            HStack(spacing: 12) {
                Text(accountSummary.initials)
                    .font(.system(size: snapshot.isCollapsed ? 12 : 14, weight: .medium))
                    .foregroundStyle(theme.colors.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(theme.colors.accent.opacity(0.26))
                    )
                    .overlay {
                        Circle()
                            .stroke(theme.colors.border.opacity(0.6), lineWidth: 1)
                    }

                if !snapshot.isCollapsed {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accountSummary.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.colors.textPrimary)
                            .lineLimit(1)
                        Text(accountSummary.detail)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "iphone")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(theme.colors.textTertiary)
                        .frame(width: 26, height: 30)
                }
            }
            .frame(height: snapshot.isCollapsed ? 42 : 54)
            .frame(maxWidth: .infinity, alignment: snapshot.isCollapsed ? .center : .leading)
            .padding(.horizontal, snapshot.isCollapsed ? 8 : 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(accountSummary.displayName)
        .background {
            Rectangle()
                .fill(theme.colors.surface.opacity(0.12))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.colors.border.opacity(0.32))
                        .frame(height: 1)
                }
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            if !snapshot.isCollapsed {
                Spacer(minLength: 0)
            }

            Button(action: onToggleCollapsed) {
                Image(systemName: snapshot.isCollapsed ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.colors.textSecondary)
            .accessibilityLabel(CodexSidebarAccessibility.collapseToggleLabel(isCollapsed: snapshot.isCollapsed))
            .help(CodexSidebarAccessibility.collapseToggleLabel(isCollapsed: snapshot.isCollapsed))
        }
        .padding(.horizontal, snapshot.isCollapsed ? 8 : 10)
        .frame(height: snapshot.isCollapsed ? 42 : 28)
    }

    private var routeRows: some View {
        VStack(spacing: 2) {
            SidebarCommandRow(
                systemImage: "square.and.pencil",
                title: "New chat",
                isCollapsed: snapshot.isCollapsed,
                action: onNewChat
            )
            SidebarCommandRow(
                systemImage: CodexAppRoute.search.systemImage,
                title: CodexAppRoute.search.title,
                isSelected: snapshot.selectedRoute == .search,
                isCollapsed: snapshot.isCollapsed,
                action: onOpenSearch
            )
            SidebarCommandRow(
                systemImage: CodexAppRoute.automations.systemImage,
                title: "Scheduled",
                isSelected: snapshot.selectedRoute == .automations,
                isCollapsed: snapshot.isCollapsed,
                action: { onSelectRoute(.automations) }
            )
            SidebarCommandRow(
                systemImage: CodexAppRoute.plugins.systemImage,
                title: CodexAppRoute.plugins.title,
                isSelected: snapshot.selectedRoute == .plugins,
                isCollapsed: snapshot.isCollapsed,
                action: { onSelectRoute(.plugins) }
            )
        }
    }

    @ViewBuilder
    private var pinnedSection: some View {
        if !snapshot.pinnedRows.isEmpty && !snapshot.isCollapsed {
            VStack(alignment: .leading, spacing: 4) {
                SidebarSectionHeader(title: "Pinned")
                ForEach(snapshot.pinnedRows) { row in
                    SidebarChatRow(
                        row: row,
                        indentation: 0,
                        onSelect: { onSelectChat(row.summary) },
                        onTogglePin: { onTogglePinChat(row.summary) },
                        onArchive: { onArchiveChat(row.summary) }
                    )
                }
            }
        }
    }

    private var projectListSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !snapshot.isCollapsed {
                SidebarSectionHeader(title: "Projects")
            }

            ForEach(snapshot.projects) { group in
                ProjectSidebarGroupView(
                    group: group,
                    isCollapsed: snapshot.isCollapsed,
                    isThreadReady: group.isSelected && isThreadReady,
                    onToggleProject: onToggleProject,
                    onStartProjectChat: onStartProjectChat,
                    onSelectProject: onSelectProject,
                    onSelectChat: onSelectChat,
                    onTogglePinChat: onTogglePinChat,
                    onArchiveChat: onArchiveChat
                )
            }

            if snapshot.showsNoChats && !snapshot.isCollapsed {
                Text(snapshot.noChatsTitle)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var olderProjectsSection: some View {
        if !snapshot.olderProjects.isEmpty {
            if snapshot.isCollapsed {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        withAnimation(.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)) {
                            showsOlderProjects.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: showsOlderProjects ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 14)
                            Text("Show older")
                                .font(.system(size: 15, weight: .medium))
                            Text("\(snapshot.olderProjects.count)")
                                .font(theme.fonts.caption)
                                .foregroundStyle(theme.colors.textTertiary.opacity(theme.effects.textFaintOpacity))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(theme.colors.textTertiary)
                        .frame(height: 32)
                        .padding(.horizontal, 2)
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if showsOlderProjects {
                        ForEach(snapshot.olderProjects) { group in
                            ProjectSidebarGroupView(
                                group: group,
                                isCollapsed: snapshot.isCollapsed,
                                isThreadReady: group.isSelected && isThreadReady,
                                onToggleProject: onToggleProject,
                                onStartProjectChat: onStartProjectChat,
                                onSelectProject: onSelectProject,
                                onSelectChat: onSelectChat,
                                onTogglePinChat: onTogglePinChat,
                                onArchiveChat: onArchiveChat
                            )
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    private var settingsSection: some View {
        VStack(spacing: 2) {
            SidebarCommandRow(
                systemImage: "folder.badge.plus",
                title: "Open folder",
                isCollapsed: snapshot.isCollapsed,
                action: onOpenFolder
            )
            SidebarCommandRow(
                systemImage: CodexAppRoute.codexMobile.systemImage,
                title: CodexAppRoute.codexMobile.title,
                isSelected: snapshot.selectedRoute == .codexMobile,
                isCollapsed: snapshot.isCollapsed,
                action: { onSelectRoute(.codexMobile) }
            )
            SidebarCommandRow(
                systemImage: CodexAppRoute.settingsAbout.systemImage,
                title: CodexAppRoute.settingsAbout.title,
                isSelected: snapshot.selectedRoute == .settingsAbout,
                isCollapsed: snapshot.isCollapsed,
                action: { onSelectRoute(.settingsAbout) }
            )
        }
    }

}

private struct SidebarCommandRow: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var isHovered = false

    let systemImage: String
    let title: String
    var shortcut: String?
    var isSelected = false
    var isCollapsed = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                    .frame(width: 20)
                if !isCollapsed {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let shortcut {
                        Text(shortcut)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                    }
                }
            }
            .frame(height: 35)
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
            .padding(.horizontal, isCollapsed ? 4 : 6)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            rowFill,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .accessibilityLabel(CodexSidebarAccessibility.commandRowLabel(title: title, shortcut: shortcut))
        .help(title)
    }

    private var rowFill: Color {
        if isSelected {
            return theme.colors.surfaceElevated.opacity(0.50)
        }
        if isHovered {
            return theme.colors.surfaceElevated.opacity(0.22)
        }
        return .clear
    }
}

private struct SidebarSectionHeader: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.colors.textTertiary)
        .frame(height: 30)
        .padding(.horizontal, 2)
    }
}

private struct ProjectSidebarGroupView: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var isHovered = false

    let group: CodexSidebarProjectGroup
    let isCollapsed: Bool
    let isThreadReady: Bool
    let onToggleProject: (String) -> Void
    let onStartProjectChat: (String) -> Void
    let onSelectProject: (String) -> Void
    let onSelectChat: (CodexThreadSummary) -> Void
    let onTogglePinChat: (CodexThreadSummary) -> Void
    let onArchiveChat: (CodexThreadSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if group.isExpanded {
                    onToggleProject(group.project.workspacePath)
                } else {
                    onToggleProject(group.project.workspacePath)
                    onSelectProject(group.project.workspacePath)
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(group.isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                        .frame(width: 20)
                    if !isCollapsed {
                        Text(group.project.displayName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(theme.colors.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: isCollapsed ? 31 : 35)
                .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
                .padding(.horizontal, isCollapsed ? 4 : 6)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CodexSidebarAccessibility.projectDisclosureLabel(projectTitle: group.project.displayName, isExpanded: group.isExpanded))
            .help(group.project.displayName)
            .contextMenu {
                if group.canStartNewChat {
                    Button {
                        onStartProjectChat(group.project.workspacePath)
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                }

                Button {
                    onSelectProject(group.project.workspacePath)
                } label: {
                    Label("Select project", systemImage: "folder")
                }
            }
            .padding(.horizontal, isCollapsed ? 0 : 2)
            .background(
                projectRowFill,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .onHover { isHovered = $0 }

            if group.isExpanded && !isCollapsed {
                if group.rows.isEmpty {
                    Text("No chats")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .padding(.leading, 30)
                        .padding(.vertical, 5)
                } else {
                    ForEach(group.rows) { row in
                        SidebarChatRow(
                            row: row,
                            indentation: 32,
                            onSelect: { onSelectChat(row.summary) },
                            onTogglePin: { onTogglePinChat(row.summary) },
                            onArchive: { onArchiveChat(row.summary) }
                        )
                    }
                    if group.hiddenRowCount > 0 {
                        Text("Show \(group.hiddenRowCount) more")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(1)
                            .padding(.leading, 38)
                            .frame(height: 30)
                            .help("\(group.hiddenRowCount) older chats hidden")
                    }
                }
            }
        }
    }

    private var hasSelectedThread: Bool {
        group.rows.contains { $0.isSelected }
    }

    private var projectRowFill: Color {
        if group.isSelected && !hasSelectedThread {
            return theme.colors.surfaceElevated.opacity(0.36)
        }
        if isHovered {
            return theme.colors.surfaceElevated.opacity(0.18)
        }
        return .clear
    }
}

private struct SidebarChatRow: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var isHovered = false

    let row: CodexSidebarThreadRow
    var indentation: CGFloat = 0
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onArchive: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(row.summary.title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(row.isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            trailingStatusOrActions
        }
        .padding(.leading, 6 + indentation)
        .padding(.trailing, 8)
        .frame(height: 34)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: onSelect)
        .background(
            rowFill,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .help(row.summary.title)
    }

    private var trailingStatusOrActions: some View {
        ZStack(alignment: .trailing) {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text(recencyLabel)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
            }
            .opacity(chatActionsAreVisible ? 0 : 1)

            HStack(spacing: 4) {
                if row.canPin {
                    sidebarActionButton(
                        systemImage: row.isPinned ? "pin.fill" : "pin",
                        isAccented: row.isPinned,
                        accessibilityLabel: CodexSidebarAccessibility.chatPinLabel(isPinned: row.isPinned, title: row.summary.title),
                        help: row.isPinned ? "Unpin chat" : "Pin chat",
                        action: onTogglePin
                    )
                }
                if row.canArchive {
                    sidebarActionButton(
                        systemImage: "archivebox",
                        accessibilityLabel: CodexSidebarAccessibility.chatArchiveLabel(title: row.summary.title),
                        help: "Archive chat",
                        action: onArchive
                    )
                }
            }
            .opacity(chatActionsAreVisible ? 1 : 0)
            .allowsHitTesting(chatActionsAreVisible)
        }
        .frame(width: 52, alignment: .trailing)
    }

    private func sidebarActionButton(
        systemImage: String,
        isAccented: Bool = false,
        accessibilityLabel: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9.5, weight: .semibold))
                .frame(width: 21, height: 21)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(theme.colors.border.opacity(0.7), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isAccented ? theme.colors.accent : theme.colors.textTertiary)
        .accessibilityLabel(accessibilityLabel)
        .help(help)
    }

    private var rowFill: Color {
        if row.isSelected {
            return theme.colors.surfaceElevated.opacity(0.50)
        }
        if isHovered {
            return theme.colors.surfaceElevated.opacity(0.22)
        }
        return .clear
    }

    private var chatActionsAreVisible: Bool {
        isHovered || row.isSelected
    }

    private var recencyLabel: String {
        guard let timestamp = row.summary.recencyAt ?? row.summary.updatedAt ?? row.summary.createdAt else {
            return ""
        }

        let elapsed = max(0, Date().timeIntervalSince1970 - timestamp)
        switch elapsed {
        case ..<60:
            return "now"
        case ..<3_600:
            return "\(Int(elapsed / 60))m"
        case ..<86_400:
            return "\(Int(elapsed / 3_600))h"
        case ..<604_800:
            return "\(Int(elapsed / 86_400))d"
        default:
            return "\(Int(elapsed / 604_800))w"
        }
    }
}

private enum SidebarMetrics {
    static let expandedWidth: CGFloat = 288
    static let collapsedWidth: CGFloat = 58
}
