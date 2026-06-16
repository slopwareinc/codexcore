import SwiftUI
import CodexCore
import CodexCoreUI

struct CodexExampleProjectSidebar: View {
    @Environment(\.codexAgentTheme) private var theme

    let serverName: String?
    let workspacePath: String
    let isThreadReady: Bool
    let currentThreadID: String?
    let projects: [CodexProjectSummary]
    let recentChats: [CodexThreadSummary]
    let onNewChat: () -> Void
    let onSearch: () -> Void
    let onPlugins: () -> Void
    let onSelectProject: (String) -> Void
    let onOpenFolder: () -> Void
    let onSelectChat: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 2) {
                        SidebarCommandRow(systemImage: "square.and.pencil", title: "New chat", shortcut: "⌘N", action: onNewChat)
                        SidebarCommandRow(systemImage: "magnifyingglass", title: "Search", shortcut: "⌘K", action: onSearch)
                        SidebarCommandRow(systemImage: "puzzlepiece.extension", title: "Plugins", action: onPlugins)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        SidebarSectionHeader(title: "Projects")
                        SidebarCommandRow(systemImage: "folder.badge.plus", title: "Open folder…", action: onOpenFolder)
                        ForEach(sidebarProjects) { project in
                            let isSelected = project.workspacePath == CodexProjectSummary.normalizedPath(workspacePath)
                            ProjectSidebarRow(
                                title: project.displayName,
                                detail: project.detail,
                                isSelected: isSelected,
                                isThreadReady: isSelected && isThreadReady
                            ) {
                                onSelectProject(project.workspacePath)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        SidebarSectionHeader(title: "Chats")
                        if recentChats.isEmpty {
                            SidebarChatRow(title: "Current chat", detail: chatDetail, isSelected: true) {}
                        } else {
                            ForEach(recentChats) { chat in
                                SidebarChatRow(
                                    title: chat.title,
                                    detail: chat.detail,
                                    isSelected: chat.id == currentThreadID
                                ) {
                                    onSelectChat(chat.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }

        }
        .frame(width: 303)
        .frame(maxHeight: .infinity)
        .background(theme.colors.surface.opacity(0.96))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.colors.border)
                .frame(width: 1)
        }
    }

    private var sidebarProjects: [CodexProjectSummary] {
        projects.isEmpty
            ? CodexProjectSummary.projects(from: [], currentWorkspacePath: workspacePath)
            : projects
    }

    private var chatDetail: String {
        if let serverName {
            return isThreadReady ? "Ready on \(serverName)" : "New chat"
        }
        return isThreadReady ? "Ready" : "New chat"
    }
}

private struct SidebarCommandRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let systemImage: String
    let title: String
    var shortcut: String?
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }
            .frame(height: 31)
            .padding(.horizontal, 8)
            .contentShape(RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        }
        .buttonStyle(.plain)
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

private struct ProjectSidebarRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let detail: String
    let isSelected: Bool
    let isThreadReady: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    Text(detail)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? (isThreadReady ? "checkmark" : "plus") : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.colors.textTertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .contentShape(RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? theme.colors.surfaceElevated.opacity(0.58) : .clear,
            in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
        )
    }
}

private struct SidebarChatRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                        .lineLimit(1)
                    Text(detail.isEmpty ? "No activity yet" : detail)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .contentShape(RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? theme.colors.surfaceElevated.opacity(0.58) : .clear,
            in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
        )
    }
}
