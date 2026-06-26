import SwiftUI
import CodexCoreUI

struct CodexExampleProjectSidebar: View {
    @Environment(\.codexAgentTheme) private var theme

    let serverName: String?
    let isThreadReady: Bool
    let snapshot: CodexSidebarSnapshot
    let onNewChat: () -> Void
    let onOpenSearch: () -> Void
    let onSelectRoute: (CodexAppRoute) -> Void
    let onToggleCollapsed: () -> Void
    let onToggleProject: (String) -> Void
    let onStartProjectChat: (String) -> Void
    let onProjectActions: (String) -> Void
    let onSelectProject: (String) -> Void
    let onOpenFolder: () -> Void
    let onSelectChat: (CodexThreadSummary) -> Void
    let onTogglePinChat: (CodexThreadSummary) -> Void
    let onArchiveChat: (CodexThreadSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: snapshot.isCollapsed ? 8 : 14) {
                    routeRows
                    projectsSection
                    settingsSection
                }
                .padding(.horizontal, snapshot.isCollapsed ? 8 : 10)
                .padding(.top, 6)
                .padding(.bottom, 14)
            }
        }
        .frame(
            minWidth: snapshot.isCollapsed ? SidebarMetrics.collapsedWidth : SidebarMetrics.expandedWidth,
            idealWidth: snapshot.isCollapsed ? SidebarMetrics.collapsedWidth : SidebarMetrics.expandedWidth,
            maxWidth: snapshot.isCollapsed ? SidebarMetrics.collapsedWidth : SidebarMetrics.expandedWidth
        )
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.colors.border.opacity(0.72))
                .frame(width: 1)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            if !snapshot.isCollapsed {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Codex")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                    Text(connectionDetail)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                }
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
        .padding(.horizontal, snapshot.isCollapsed ? 8 : 12)
        .frame(height: 46)
    }

    private var routeRows: some View {
        VStack(spacing: 2) {
            SidebarCommandRow(
                systemImage: "square.and.pencil",
                title: "New chat",
                shortcut: "⌘N",
                isCollapsed: snapshot.isCollapsed,
                action: onNewChat
            )
            SidebarCommandRow(
                systemImage: CodexAppRoute.search.systemImage,
                title: CodexAppRoute.search.title,
                shortcut: "⌘G",
                isSelected: snapshot.selectedRoute == .search,
                isCollapsed: snapshot.isCollapsed,
                action: onOpenSearch
            )
            SidebarCommandRow(
                systemImage: CodexAppRoute.plugins.systemImage,
                title: CodexAppRoute.plugins.title,
                isSelected: snapshot.selectedRoute == .plugins,
                isCollapsed: snapshot.isCollapsed,
                action: { onSelectRoute(.plugins) }
            )
            SidebarCommandRow(
                systemImage: CodexAppRoute.automations.systemImage,
                title: CodexAppRoute.automations.title,
                isSelected: snapshot.selectedRoute == .automations,
                isCollapsed: snapshot.isCollapsed,
                action: { onSelectRoute(.automations) }
            )
            SidebarCommandRow(
                systemImage: CodexAppRoute.codexMobile.systemImage,
                title: CodexAppRoute.codexMobile.title,
                isSelected: snapshot.selectedRoute == .codexMobile,
                isCollapsed: snapshot.isCollapsed,
                action: { onSelectRoute(.codexMobile) }
            )
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !snapshot.isCollapsed {
                SidebarSectionHeader(title: "Projects")
            }

            if !snapshot.pinnedRows.isEmpty && !snapshot.isCollapsed {
                SidebarSectionHeader(title: "Pinned")
                ForEach(snapshot.pinnedRows) { row in
                    SidebarChatRow(
                        row: row,
                        onSelect: { onSelectChat(row.summary) },
                        onTogglePin: { onTogglePinChat(row.summary) },
                        onArchive: { onArchiveChat(row.summary) }
                    )
                }
            }

            SidebarCommandRow(
                systemImage: "folder.badge.plus",
                title: "Open folder…",
                isCollapsed: snapshot.isCollapsed,
                action: onOpenFolder
            )

            ForEach(snapshot.projects) { group in
                ProjectSidebarGroupView(
                    group: group,
                    isCollapsed: snapshot.isCollapsed,
                    isThreadReady: group.isSelected && isThreadReady,
                    onToggleProject: onToggleProject,
                    onStartProjectChat: onStartProjectChat,
                    onProjectActions: onProjectActions,
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

    private var settingsSection: some View {
        SidebarCommandRow(
            systemImage: CodexAppRoute.settingsAbout.systemImage,
            title: CodexAppRoute.settingsAbout.title,
            isSelected: snapshot.selectedRoute == .settingsAbout,
            isCollapsed: snapshot.isCollapsed,
            action: { onSelectRoute(.settingsAbout) }
        )
    }

    private var connectionDetail: String {
        if let serverName {
            return isThreadReady ? "Ready on \(serverName)" : serverName
        }
        return isThreadReady ? "Ready" : "New chat"
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
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? theme.colors.accent : theme.colors.textTertiary)
                    .frame(width: 18)
                if !isCollapsed {
                    Text(title)
                        .font(.system(size: 13))
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
            .frame(height: 29)
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
            .padding(.horizontal, isCollapsed ? 4 : 8)
            .contentShape(RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            rowFill,
            in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .accessibilityLabel(CodexSidebarAccessibility.commandRowLabel(title: title, shortcut: shortcut))
        .help(title)
    }

    private var rowFill: Color {
        if isSelected {
            return theme.colors.surfaceElevated.opacity(0.52)
        }
        if isHovered {
            return theme.colors.surfaceElevated.opacity(0.28)
        }
        return .clear
    }
}

private struct SidebarSectionHeader: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.down")
                .font(.system(size: 8.5, weight: .bold))
            Text(title)
                .font(theme.fonts.caption.weight(.semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.colors.textTertiary)
        .frame(height: 24)
        .padding(.horizontal, 8)
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
    let onProjectActions: (String) -> Void
    let onSelectProject: (String) -> Void
    let onSelectChat: (CodexThreadSummary) -> Void
    let onTogglePinChat: (CodexThreadSummary) -> Void
    let onArchiveChat: (CodexThreadSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if !isCollapsed {
                    Button {
                        onToggleProject(group.project.workspacePath)
                    } label: {
                        Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .frame(width: 18, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.textTertiary)
                    .opacity(projectControlsAreVisible ? 1 : 0.68)
                    .accessibilityLabel(CodexSidebarAccessibility.projectDisclosureLabel(
                        projectTitle: group.project.displayName,
                        isExpanded: group.isExpanded
                    ))
                    .help(group.isExpanded ? "Collapse project" : "Expand project")
                }

                Button {
                    onSelectProject(group.project.workspacePath)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.colors.textTertiary)
                            .frame(width: 18)
                        if !isCollapsed {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.project.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(theme.colors.textPrimary)
                                    .lineLimit(1)
                                Text(projectDetail)
                                    .font(theme.fonts.caption)
                                    .foregroundStyle(theme.colors.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(height: isCollapsed ? 31 : 38)
                    .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
                    .padding(.horizontal, isCollapsed ? 4 : 6)
                    .contentShape(RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(group.project.displayName)

                if !isCollapsed {
                    projectActionButtons
                        .opacity(projectControlsAreVisible ? 1 : 0)
                        .allowsHitTesting(projectControlsAreVisible)
                }
            }
            .padding(.horizontal, isCollapsed ? 0 : 2)
            .background(
                projectRowFill,
                in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
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
                            onSelect: { onSelectChat(row.summary) },
                            onTogglePin: { onTogglePinChat(row.summary) },
                            onArchive: { onArchiveChat(row.summary) }
                        )
                        .padding(.leading, 22)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var projectActionButtons: some View {
        HStack(spacing: 2) {
            if group.hasProjectActionsEntry {
                Menu {
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
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 30)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.textTertiary)
                .accessibilityLabel(CodexSidebarAccessibility.projectActionsLabel(projectTitle: group.project.displayName))
                .help("Project actions")
            } else {
                Color.clear.frame(width: 22, height: 30)
            }

            if group.canStartNewChat {
                Button {
                    onStartProjectChat(group.project.workspacePath)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.textTertiary)
                .accessibilityLabel(CodexSidebarAccessibility.projectNewChatLabel(projectTitle: group.project.displayName))
                .help("New chat in project")
            } else {
                Color.clear.frame(width: 22, height: 30)
            }
        }
        .frame(width: 48, alignment: .trailing)
    }

    private var projectDetail: String {
        if isThreadReady {
            return "Ready"
        }
        if group.project.chatCount == 1 {
            return "1 chat"
        }
        return "\(group.project.chatCount) chats"
    }

    private var hasSelectedThread: Bool {
        group.rows.contains { $0.isSelected }
    }

    private var projectControlsAreVisible: Bool {
        isHovered || group.isSelected
    }

    private var projectRowFill: Color {
        if group.isSelected && !hasSelectedThread {
            return theme.colors.surfaceElevated.opacity(0.48)
        }
        if isHovered {
            return theme.colors.surfaceElevated.opacity(0.24)
        }
        return .clear
    }
}

private struct SidebarChatRow: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var isHovered = false

    let row: CodexSidebarThreadRow
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onArchive: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "bubble.left")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.colors.textTertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.summary.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(row.isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                    .lineLimit(1)
                Text(row.summary.detail.isEmpty ? "No activity yet" : row.summary.detail)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            trailingStatusOrActions
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .contentShape(RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        .onTapGesture(perform: onSelect)
        .background(
            rowFill,
            in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .help(row.summary.title)
    }

    private var trailingStatusOrActions: some View {
        ZStack(alignment: .trailing) {
            Text(recencyLabel)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .lineLimit(1)
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
            return theme.colors.surfaceElevated.opacity(0.5)
        }
        if isHovered {
            return theme.colors.surfaceElevated.opacity(0.24)
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
