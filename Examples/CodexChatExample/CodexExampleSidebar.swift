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
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
        }
        .frame(width: snapshot.isCollapsed ? 62 : 303)
        .frame(maxHeight: .infinity)
        .background(theme.colors.surface.opacity(0.96))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.colors.border)
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
        .padding(.vertical, 10)
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
            .frame(height: 31)
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
            .padding(.horizontal, isCollapsed ? 4 : 8)
            .contentShape(RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? theme.colors.surfaceElevated.opacity(0.62) : .clear,
            in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
        )
        .accessibilityLabel(CodexSidebarAccessibility.commandRowLabel(title: title, shortcut: shortcut))
        .help(title)
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
                    .padding(.horizontal, isCollapsed ? 4 : 8)
                    .contentShape(RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
                }
                .buttonStyle(.plain)
                .background(
                    group.isSelected && !hasSelectedThread ? theme.colors.surfaceElevated.opacity(0.58) : .clear,
                    in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                )
                .help(group.project.displayName)

                if !isCollapsed {
                    if group.canStartNewChat {
                        Button {
                            onStartProjectChat(group.project.workspacePath)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 20, height: 30)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.colors.textTertiary)
                        .accessibilityLabel(CodexSidebarAccessibility.projectNewChatLabel(projectTitle: group.project.displayName))
                        .help("New chat in project")
                    }

                    if group.hasProjectActionsEntry {
                        Menu {
                            Button {
                                onStartProjectChat(group.project.workspacePath)
                            } label: {
                                Label("New chat", systemImage: "square.and.pencil")
                            }

                            Button {
                                onSelectProject(group.project.workspacePath)
                            } label: {
                                Label("Select project", systemImage: "folder")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 20, height: 30)
                        }
                        .menuStyle(.borderlessButton)
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.colors.textTertiary)
                        .accessibilityLabel(CodexSidebarAccessibility.projectActionsLabel(projectTitle: group.project.displayName))
                        .help("Project actions")
                    }
                }
            }

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
}

private struct SidebarChatRow: View {
    @Environment(\.codexAgentTheme) private var theme

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
            HStack(spacing: 5) {
                if row.canPin {
                    Button(action: onTogglePin) {
                        Image(systemName: row.isPinned ? "pin.fill" : "pin")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(row.isPinned ? theme.colors.accent : theme.colors.textTertiary.opacity(0.75))
                    .accessibilityLabel(CodexSidebarAccessibility.chatPinLabel(isPinned: row.isPinned, title: row.summary.title))
                    .help(row.isPinned ? "Unpin chat" : "Pin chat")
                }
                if row.canArchive {
                    Button(action: onArchive) {
                        Image(systemName: "archivebox")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.textTertiary.opacity(0.75))
                    .accessibilityLabel(CodexSidebarAccessibility.chatArchiveLabel(title: row.summary.title))
                    .help("Archive chat")
                }
            }
            .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .contentShape(RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        .onTapGesture(perform: onSelect)
        .background(
            row.isSelected ? theme.colors.surfaceElevated.opacity(0.58) : .clear,
            in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
        )
        .help(row.summary.title)
    }
}
