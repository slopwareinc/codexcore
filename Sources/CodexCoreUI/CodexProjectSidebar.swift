import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

enum CodexProjectSidebarEnvironmentLabel {
    static func title(workspacePath: String?) -> String? {
        guard let workspacePath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspacePath.isEmpty else {
            return nil
        }
        // Sidebar rows render on the main thread. Do not launch a synchronous
        // Git subprocess from a row body; use the cheap path heuristic here.
        return CodexWorkspaceGitProbe.heuristicWorktreePath(
            URL(fileURLWithPath: workspacePath)
        ) ? "Worktree" : nil
    }
}

public struct CodexProjectSidebar: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var showsOlderProjects = false
    @State private var isPinnedSectionExpanded = true
    @State private var isChatsSectionExpanded = true
    @State private var isProjectsSectionExpanded = true
    @State private var dragStartWidth: CGFloat?
    @State private var liveResizeWidth: CGFloat?

    let serverName: String?
    let accountSummary: CodexAccountMenuSummary
    let isThreadReady: Bool
    let snapshot: CodexSidebarSnapshot
    let expandedWidth: CGFloat
    let onResizeExpandedWidth: ((CGFloat) -> Void)?
    let onNewChat: () -> Void
    let onOpenSearch: () -> Void
    let onSelectRoute: (CodexAppRoute) -> Void
    let onToggleProject: (String) -> Void
    let onMoveProject: (String, String, CodexProjectDropPlacement) -> Void
    let onToggleProjectPin: (String) -> Void
    let onRevealProject: (String) -> Void
    let onRenameProject: (CodexProjectSummary) -> Void
    let onArchiveProjectChats: (String) -> Void
    let onRemoveProject: (String) -> Void
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
        expandedWidth: CGFloat = CodexProjectSidebar.defaultExpandedWidth,
        onResizeExpandedWidth: ((CGFloat) -> Void)? = nil,
        onNewChat: @escaping () -> Void,
        onOpenSearch: @escaping () -> Void,
        onSelectRoute: @escaping (CodexAppRoute) -> Void,
        onToggleProject: @escaping (String) -> Void,
        onMoveProject: @escaping (String, String, CodexProjectDropPlacement) -> Void = { _, _, _ in },
        onToggleProjectPin: @escaping (String) -> Void = { _ in },
        onRevealProject: @escaping (String) -> Void = { _ in },
        onRenameProject: @escaping (CodexProjectSummary) -> Void = { _ in },
        onArchiveProjectChats: @escaping (String) -> Void = { _ in },
        onRemoveProject: @escaping (String) -> Void = { _ in },
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
        self.expandedWidth = expandedWidth
        self.onResizeExpandedWidth = onResizeExpandedWidth
        self.onNewChat = onNewChat
        self.onOpenSearch = onOpenSearch
        self.onSelectRoute = onSelectRoute
        self.onToggleProject = onToggleProject
        self.onMoveProject = onMoveProject
        self.onToggleProjectPin = onToggleProjectPin
        self.onRevealProject = onRevealProject
        self.onRenameProject = onRenameProject
        self.onArchiveProjectChats = onArchiveProjectChats
        self.onRemoveProject = onRemoveProject
        self.onStartProjectChat = onStartProjectChat
        self.onSelectProject = onSelectProject
        self.onOpenFolder = onOpenFolder
        self.onSelectChat = onSelectChat
        self.onTogglePinChat = onTogglePinChat
        self.onArchiveChat = onArchiveChat
    }

    public var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: CodexWindowChromeMetrics.titlebarHeight)

            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: snapshot.isCollapsed ? 8 : 16) {
                    routeRows
                    pinnedSection
                    projectlessSection
                    projectListSection
                    olderProjectsSection
                }
                .padding(.horizontal, snapshot.isCollapsed ? 8 : 12)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }

            utilitySection
            accountFooter
        }
        .frame(
            minWidth: resolvedWidth,
            idealWidth: resolvedWidth,
            maxWidth: resolvedWidth
        )
        .frame(maxHeight: .infinity)
        .opacity(snapshot.isCollapsed ? 0 : 1)
        .allowsHitTesting(!snapshot.isCollapsed)
        .accessibilityHidden(snapshot.isCollapsed)
        // Glass samples what is behind the window, so nothing may be layered
        // underneath it: an opaque material stack here would be all it sees.
        .codexGlass(Rectangle(), role: .chrome)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.colors.border.opacity(0.45))
                .frame(width: 1)
        }
        .overlay(alignment: .trailing) { resizeHandle }
    }

    @ViewBuilder
    private var projectlessSection: some View {
        if !snapshot.projectlessRows.isEmpty && !snapshot.isCollapsed {
            VStack(alignment: .leading, spacing: 2) {
                SidebarSectionHeader(
                    title: "Chats",
                    isExpanded: isChatsSectionExpanded,
                    attentionState: CodexSidebarAttentionState.aggregate(snapshot.projectlessRows)
                ) {
                    isChatsSectionExpanded.toggle()
                }
                if isChatsSectionExpanded {
                    ForEach(snapshot.projectlessRows) { row in
                        SidebarChatRow(
                            row: row,
                            indentation: 0,
                            showsRecency: true,
                            onSelect: { onSelectChat(row.summary) },
                            onTogglePin: { onTogglePinChat(row.summary) },
                            onArchive: { onArchiveChat(row.summary) }
                        )
                    }
                }
            }
        }
    }

    private var resolvedWidth: CGFloat {
        snapshot.isCollapsed
            ? 0
            : liveResizeWidth ?? CodexProjectSidebar.clampExpandedWidth(expandedWidth)
    }

    /// A thin transparent strip straddling the trailing edge that drag-resizes
    /// the expanded sidebar. Absent when collapsed or when no resize handler is
    /// wired, so the plain divider shows through unchanged.
    @ViewBuilder
    private var resizeHandle: some View {
        if !snapshot.isCollapsed, let onResizeExpandedWidth {
            Color.clear
                .frame(width: SidebarMetrics.resizeHandleHitWidth)
                .contentShape(Rectangle())
                .onHover { inside in
                    #if canImport(AppKit)
                    if inside {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                    #endif
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let base = dragStartWidth ?? resolvedWidth
                            if dragStartWidth == nil { dragStartWidth = base }
                            let nextWidth = CodexProjectSidebar.clampExpandedWidth(
                                base + value.translation.width
                            )
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                liveResizeWidth = nextWidth
                            }
                        }
                        .onEnded { _ in
                            if let liveResizeWidth {
                                onResizeExpandedWidth(liveResizeWidth)
                            }
                            dragStartWidth = nil
                            liveResizeWidth = nil
                        }
                )
                // Straddle the divider so the hit area covers both sides of the edge.
                .offset(x: SidebarMetrics.resizeHandleHitWidth / 2)
        }
    }

    private var accountFooter: some View {
        let sidebarFonts = theme.fonts.sidebar
        return HStack(spacing: 12) {
            Text(accountSummary.initials)
                .font(sidebarFonts.accountInitials(isCollapsed: snapshot.isCollapsed))
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
                        .font(sidebarFonts.accountName.font)
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    Text(accountSummary.detail)
                        .font(sidebarFonts.accountDetail.font)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: snapshot.isCollapsed ? sidebarFonts.collapsedAccountFooterHeight : sidebarFonts.accountFooterHeight)
        .frame(maxWidth: .infinity, alignment: snapshot.isCollapsed ? .center : .leading)
        .padding(.horizontal, snapshot.isCollapsed ? 8 : 16)
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
            ForEach(CodexAppRoute.primarySidebarRoutes, id: \.rawValue) { route in
                SidebarCommandRow(
                    systemImage: route.systemImage,
                    title: route.title,
                    isSelected: snapshot.selectedRoute == route,
                    isCollapsed: snapshot.isCollapsed,
                    action: { onSelectRoute(route) }
                )
            }
        }
    }

    @ViewBuilder
    private var pinnedSection: some View {
        if (!snapshot.pinnedRows.isEmpty || !snapshot.pinnedProjects.isEmpty) && !snapshot.isCollapsed {
            VStack(alignment: .leading, spacing: 2) {
                SidebarSectionHeader(
                    title: "Pinned",
                    isExpanded: isPinnedSectionExpanded,
                    attentionState: CodexSidebarAttentionState.aggregate(
                        snapshot.pinnedRows + snapshot.pinnedProjects.flatMap(\.rows)
                    )
                ) {
                    isPinnedSectionExpanded.toggle()
                }
                if isPinnedSectionExpanded {
                    ForEach(snapshot.pinnedRows) { row in
                        SidebarChatRow(
                            row: row,
                            indentation: 0,
                            showsRecency: true,
                            onSelect: { onSelectChat(row.summary) },
                            onTogglePin: { onTogglePinChat(row.summary) },
                            onArchive: { onArchiveChat(row.summary) }
                        )
                    }
                    ForEach(snapshot.pinnedProjects) { group in
                        ProjectSidebarGroupView(
                            group: group,
                            isCollapsed: false,
                            isThreadReady: group.isSelected && isThreadReady,
                            onToggleProject: onToggleProject,
                            onMoveProject: onMoveProject,
                            onToggleProjectPin: onToggleProjectPin,
                            onRevealProject: onRevealProject,
                            onRenameProject: onRenameProject,
                            onArchiveProjectChats: onArchiveProjectChats,
                            onRemoveProject: onRemoveProject,
                            onStartProjectChat: onStartProjectChat,
                            onSelectProject: onSelectProject,
                            onSelectChat: onSelectChat,
                            onTogglePinChat: onTogglePinChat,
                            onArchiveChat: onArchiveChat
                        )
                    }
                }
            }
        }
    }

    private var projectListSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !snapshot.isCollapsed {
                SidebarSectionHeader(
                    title: "Projects",
                    isExpanded: isProjectsSectionExpanded,
                    attentionState: CodexSidebarAttentionState.aggregate(
                        (snapshot.projects + snapshot.olderProjects).flatMap(\.rows)
                    )
                ) {
                    isProjectsSectionExpanded.toggle()
                }
            }

            if snapshot.isCollapsed || isProjectsSectionExpanded {
                ForEach(snapshot.projects) { group in
                    ProjectSidebarGroupView(
                        group: group,
                        isCollapsed: snapshot.isCollapsed,
                        isThreadReady: group.isSelected && isThreadReady,
                        onToggleProject: onToggleProject,
                        onMoveProject: onMoveProject,
                        onToggleProjectPin: onToggleProjectPin,
                        onRevealProject: onRevealProject,
                        onRenameProject: onRenameProject,
                        onArchiveProjectChats: onArchiveProjectChats,
                        onRemoveProject: onRemoveProject,
                        onStartProjectChat: onStartProjectChat,
                        onSelectProject: onSelectProject,
                        onSelectChat: onSelectChat,
                        onTogglePinChat: onTogglePinChat,
                        onArchiveChat: onArchiveChat
                    )
                }
            }

            if snapshot.showsNoChats && !snapshot.isCollapsed {
                Text(snapshot.noChatsTitle)
                    .font(theme.fonts.sidebar.emptyState.font)
                    .foregroundStyle(theme.colors.textTertiary)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var olderProjectsSection: some View {
        if !snapshot.olderProjects.isEmpty && isProjectsSectionExpanded {
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
                                .font(theme.fonts.sidebar.disclosureChevron.font)
                                .frame(width: 14)
                            Text("Show older")
                                .font(theme.fonts.sidebar.disclosureTitle.font)
                            Text("\(snapshot.olderProjects.count)")
                                .font(theme.fonts.sidebar.disclosureCount.font)
                                .foregroundStyle(theme.colors.textTertiary.opacity(theme.effects.textFaintOpacity))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(theme.colors.textTertiary)
                        .frame(height: theme.fonts.sidebar.disclosureRowHeight)
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
                                onMoveProject: onMoveProject,
                                onToggleProjectPin: onToggleProjectPin,
                                onRevealProject: onRevealProject,
                                onRenameProject: onRenameProject,
                                onArchiveProjectChats: onArchiveProjectChats,
                                onRemoveProject: onRemoveProject,
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

    private var utilitySection: some View {
        VStack(spacing: 2) {
            SidebarCommandRow(
                systemImage: "folder.badge.plus",
                title: "Open folder",
                isCollapsed: snapshot.isCollapsed,
                action: onOpenFolder
            )
            SidebarCommandRow(
                systemImage: CodexAppRoute.settingsAbout.systemImage,
                title: CodexAppRoute.settingsAbout.title,
                isSelected: snapshot.selectedRoute == .settingsAbout,
                isCollapsed: snapshot.isCollapsed,
                action: { onSelectRoute(.settingsAbout) }
            )
        }
        .padding(.horizontal, snapshot.isCollapsed ? 8 : 12)
        .padding(.vertical, 8)
        .background {
            Rectangle()
                .fill(theme.colors.surface.opacity(0.10))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.colors.border.opacity(0.28))
                        .frame(height: 1)
                }
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
                    .font(theme.fonts.sidebar.commandIcon.font)
                    .foregroundStyle(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                    .frame(width: 20)
                if !isCollapsed {
                    Text(title)
                        .font(theme.fonts.sidebar.commandTitle.font)
                        .foregroundStyle(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let shortcut {
                        Text(shortcut)
                            .font(theme.fonts.sidebar.commandShortcut.font)
                            .foregroundStyle(theme.colors.textTertiary)
                    }
                }
            }
            .frame(height: theme.fonts.sidebar.commandRowHeight)
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
            return theme.colors.selection.opacity(theme.effects.selectionOpacity)
        }
        if isHovered {
            return theme.colors.hover.opacity(theme.effects.hoverOpacity)
        }
        return .clear
    }
}

private struct SidebarSectionHeader: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var isHovered = false

    let title: String
    let isExpanded: Bool
    let attentionState: CodexSidebarAttentionState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(theme.fonts.sidebar.sectionHeader.font)
                Spacer(minLength: 0)
                SidebarAttentionIndicator(state: attentionState)
                    .opacity(isExpanded ? 0 : 1)
                Image(systemName: "chevron.right")
                    .font(theme.fonts.sidebar.disclosureChevron.font)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14, height: 20)
                    .opacity(isHovered ? 1 : 0)
            }
            .foregroundStyle(theme.colors.textTertiary)
            .frame(height: theme.fonts.sidebar.sectionHeaderHeight)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct SidebarAttentionIndicator: View {
    @Environment(\.codexAgentTheme) private var theme

    let state: CodexSidebarAttentionState

    var body: some View {
        Group {
            switch state {
            case .idle:
                Color.clear
            case .unread:
                Circle()
                    .fill(theme.colors.accent)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Unread updates")
            case .running:
                CodexSpinner(color: theme.colors.textSecondary, size: .small)
                    .accessibilityLabel("Running")
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(theme.fonts.caption.weight(.medium))
                    .foregroundStyle(theme.colors.danger)
                    .accessibilityLabel("Failed")
            }
        }
        .frame(width: 20, height: 20)
    }
}

private struct ProjectSidebarGroupView: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var isHovered = false
    @State private var isDropTargeted = false
    @State private var isArchiveConfirmationPresented = false

    let group: CodexSidebarProjectGroup
    let isCollapsed: Bool
    let isThreadReady: Bool
    let onToggleProject: (String) -> Void
    let onMoveProject: (String, String, CodexProjectDropPlacement) -> Void
    let onToggleProjectPin: (String) -> Void
    let onRevealProject: (String) -> Void
    let onRenameProject: (CodexProjectSummary) -> Void
    let onArchiveProjectChats: (String) -> Void
    let onRemoveProject: (String) -> Void
    let onStartProjectChat: (String) -> Void
    let onSelectProject: (String) -> Void
    let onSelectChat: (CodexThreadSummary) -> Void
    let onTogglePinChat: (CodexThreadSummary) -> Void
    let onArchiveChat: (CodexThreadSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Button {
                    if group.isExpanded {
                        onToggleProject(group.project.workspacePath)
                    } else {
                        onToggleProject(group.project.workspacePath)
                        onSelectProject(group.project.workspacePath)
                    }
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: group.isExpanded ? "folder.fill" : "folder")
                            .font(theme.fonts.sidebar.projectIcon.font)
                            .foregroundStyle(theme.colors.textSecondary)
                            .frame(width: 20)
                        if !isCollapsed {
                            Text(group.project.displayName)
                                .font(theme.fonts.sidebar.projectTitle.font)
                                .foregroundStyle(group.isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)
                            Spacer(minLength: 0)
                            if !group.isExpanded {
                                SidebarAttentionIndicator(
                                    state: CodexSidebarAttentionState.aggregate(group.rows)
                                )
                                .opacity(isHovered ? 0 : 1)
                            }
                        }
                    }
                    .frame(height: isCollapsed ? theme.fonts.sidebar.collapsedProjectRowHeight : theme.fonts.sidebar.projectRowHeight)
                    .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
                    .padding(.leading, isCollapsed ? 4 : 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(CodexSidebarAccessibility.projectDisclosureLabel(projectTitle: group.project.displayName, isExpanded: group.isExpanded))
                .help(group.project.displayName)
            }
            .padding(.horizontal, isCollapsed ? 0 : 2)
            .contentShape(Rectangle())
            .background { projectRowBackground }
            .overlay(alignment: .trailing) {
                if !isCollapsed && isHovered {
                    projectActionControls
                }
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .draggable(group.project.workspacePath) {
                Label(group.project.displayName, systemImage: "folder")
                    .font(theme.fonts.sidebar.projectTitle.font)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.colors.surfaceElevated, in: Capsule())
            }
            .dropDestination(for: String.self) { sourcePaths, location in
                guard let sourcePath = sourcePaths.first else { return false }
                let placement: CodexProjectDropPlacement = location.y >= theme.fonts.sidebar.projectRowHeight / 2
                    ? .after
                    : .before
                onMoveProject(sourcePath, group.project.workspacePath, placement)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .confirmationDialog(
                "Archive all chats in \(group.project.displayName)?",
                isPresented: $isArchiveConfirmationPresented
            ) {
                Button("Archive chats", role: .destructive) {
                    onArchiveProjectChats(group.project.workspacePath)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the project's chats from the active sidebar. The project folder is not changed.")
            }

            if group.isExpanded && !isCollapsed {
                if group.rows.isEmpty {
                    Text("No chats")
                        .font(theme.fonts.sidebar.emptyState.font)
                        .foregroundStyle(theme.colors.textTertiary)
                        .padding(.leading, 30)
                        .padding(.vertical, 5)
                } else {
                    ForEach(group.rows) { row in
                        SidebarChatRow(
                            row: row,
                            indentation: 28,
                            showsRecency: false,
                            onSelect: { onSelectChat(row.summary) },
                            onTogglePin: { onTogglePinChat(row.summary) },
                            onArchive: { onArchiveChat(row.summary) }
                        )
                    }
                    if group.hiddenRowCount > 0 {
                        Text("Show \(group.hiddenRowCount) more")
                            .font(theme.fonts.sidebar.hiddenRowsPrompt.font)
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(1)
                            .padding(.leading, 38)
                            .frame(height: theme.fonts.sidebar.hiddenRowsPromptHeight)
                            .help("\(group.hiddenRowCount) older chats hidden")
                    }
                }
            }
        }
    }

    private var hasSelectedThread: Bool {
        group.rows.contains { $0.isSelected }
    }

    private var projectActionControls: some View {
        HStack(spacing: 2) {
            Menu {
                Button {
                    onToggleProjectPin(group.project.workspacePath)
                } label: {
                    Label(
                        group.isPinned ? "Unpin project" : "Pin project",
                        systemImage: group.isPinned ? "pin.slash" : "pin"
                    )
                }
                Button {
                    onRevealProject(group.project.workspacePath)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Button {
                    onRenameProject(group.project)
                } label: {
                    Label("Rename project", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    isArchiveConfirmationPresented = true
                } label: {
                    Label("Archive chats", systemImage: "archivebox")
                }
                Button(role: .destructive) {
                    onRemoveProject(group.project.workspacePath)
                } label: {
                    Label("Remove", systemImage: "xmark")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(theme.fonts.chipLabel)
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Project actions")

            if group.canStartNewChat {
                Button {
                    onStartProjectChat(group.project.workspacePath)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(theme.fonts.chipLabel)
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("New chat in \(group.project.displayName)")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 2)
    }

    @ViewBuilder
    private var projectRowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if isDropTargeted {
            shape.fill(theme.colors.accent.opacity(0.16))
        } else if group.isSelected && !hasSelectedThread {
            SidebarSelectionBackground()
        } else if isHovered {
            shape.fill(theme.colors.hover.opacity(theme.effects.hoverOpacity))
        }
    }
}

private struct SidebarChatRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let row: CodexSidebarThreadRow
    var indentation: CGFloat = 0
    var showsRecency = false
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onArchive: () -> Void

    var body: some View {
        SidebarChatRowHost(
            row: row,
            indentation: indentation,
            showsRecency: showsRecency,
            theme: theme,
            onSelect: onSelect,
            onTogglePin: onTogglePin,
            onArchive: onArchive
        )
        .frame(height: theme.fonts.sidebar.chatRowHeight)
        .help(row.summary.title)
    }
}

private struct SidebarChatRowHost: NSViewRepresentable {
    @Environment(\.controlActiveState) private var controlActiveState

    let row: CodexSidebarThreadRow
    let indentation: CGFloat
    let showsRecency: Bool
    let theme: CodexAgentTheme
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onArchive: () -> Void

    func makeNSView(context: Context) -> SidebarChatRowContainerView {
        let container = SidebarChatRowContainerView()
        update(container)
        return container
    }

    func updateNSView(_ container: SidebarChatRowContainerView, context: Context) {
        update(container)
    }

    private func update(_ container: SidebarChatRowContainerView) {
        container.configure(
            content: AnyView(
                SidebarChatRowContent(
                    row: row,
                    indentation: indentation,
                    showsRecency: showsRecency,
                    onSelect: onSelect,
                    onTogglePin: onTogglePin,
                    onArchive: onArchive
                )
                .codexAgentTheme(theme)
            ),
            actions: AnyView(
                SidebarChatRowActions(
                    row: row,
                    onTogglePin: onTogglePin,
                    onArchive: onArchive
                )
                .codexAgentTheme(theme)
                .accessibilityHidden(true)
            ),
            // Chrome colors are handed over as SwiftUI Colors, not pre-resolved
            // NSColors: they are theme-adaptive, and resolving them here —
            // inside SwiftUI's updateNSView, not a draw pass — would freeze
            // them against whatever appearance happened to be
            // current, which is not necessarily this window's. The container
            // resolves them itself, against its own live effectiveAppearance,
            // every time it actually needs to paint. See CodexAppKitColor.
            hoverColor: theme.colors.hover.opacity(theme.effects.hoverOpacity),
            selectionColor: theme.colors.textPrimary.opacity(
                controlActiveState == .key ? 0.055 : 0.03
            ),
            isSelected: row.isSelected
        )
    }
}

private struct SidebarChatRowContent: View {
    @Environment(\.codexAgentTheme) private var theme

    let row: CodexSidebarThreadRow
    let indentation: CGFloat
    let showsRecency: Bool
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onArchive: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(row.summary.title)
                .font(theme.fonts.sidebar.chatTitle.font)
                .foregroundStyle(row.isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let environmentLabel {
                Text(environmentLabel)
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        theme.colors.surfaceElevated,
                        in: Capsule()
                    )
            }
            if hasTrailingStatus {
                Spacer(minLength: 0)
                trailingStatus
            }
        }
        .padding(.leading, 6 + indentation)
        .padding(.trailing, 8)
        .frame(height: theme.fonts.sidebar.chatRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [row.summary.title, environmentLabel]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        .accessibilityValue(
            CodexSidebarAccessibility.chatStatusValue(
                status: row.liveStatus,
                hasUnreadUpdates: row.hasUnreadWhileInactive,
                recencyLabel: recencyLabel
            )
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onSelect)
        .accessibilityActions {
            if row.canPin {
                Button(
                    CodexSidebarAccessibility.chatPinLabel(
                        isPinned: row.isPinned,
                        title: row.summary.title
                    ),
                    action: onTogglePin
                )
            }
            if row.canArchive {
                Button(
                    CodexSidebarAccessibility.chatArchiveLabel(title: row.summary.title),
                    action: onArchive
                )
            }
        }
    }

    private var trailingStatus: some View {
        HStack(spacing: 0) {
            switch attentionState {
            case .running, .failed, .unread:
                SidebarAttentionIndicator(state: attentionState)
            case .idle:
                if showsRecency {
                    Text(recencyLabel)
                        .font(theme.fonts.sidebar.chatRecency.font)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 42, alignment: .trailing)
    }

    private var attentionState: CodexSidebarAttentionState {
        CodexSidebarAttentionState.resolve(
            liveStatus: row.liveStatus,
            hasUnreadWhileInactive: row.hasUnreadWhileInactive
        )
    }

    private var hasTrailingStatus: Bool {
        SidebarChatRowLayout.hasTrailingStatus(
            attentionState: attentionState,
            showsRecency: showsRecency,
            recencyLabel: recencyLabel
        )
    }

    private var recencyLabel: String {
        guard let timestamp = row.summary.recencyAt ?? row.summary.updatedAt ?? row.summary.createdAt else {
            return ""
        }

        let elapsed = max(0, Date().timeIntervalSince1970 - timestamp)
        switch elapsed {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(elapsed / 60))m"
        case ..<86_400: return "\(Int(elapsed / 3_600))h"
        case ..<604_800: return "\(Int(elapsed / 86_400))d"
        default: return "\(Int(elapsed / 604_800))w"
        }
    }

    private var environmentLabel: String? {
        CodexProjectSidebarEnvironmentLabel.title(workspacePath: row.summary.workspacePath)
    }
}

private struct SidebarChatRowActions: View {
    @Environment(\.codexAgentTheme) private var theme

    let row: CodexSidebarThreadRow
    let onTogglePin: () -> Void
    let onArchive: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if row.canPin {
                sidebarActionButton(
                    systemImage: row.isPinned ? "pin.fill" : "pin",
                    isAccented: row.isPinned,
                    accessibilityLabel: CodexSidebarAccessibility.chatPinLabel(
                        isPinned: row.isPinned,
                        title: row.summary.title
                    ),
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
                .font(theme.fonts.sidebar.chatActionIcon.font)
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isAccented ? theme.colors.accent : theme.colors.textTertiary)
        .accessibilityLabel(accessibilityLabel)
        .help(help)
    }
}

@MainActor
final class SidebarChatRowContainerView: NSView {
    private let contentHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let actionsHost = NSHostingView(rootView: AnyView(EmptyView()))
    private var trackingAreaReference: NSTrackingArea?
    private weak var observedScrollContentView: NSView?
    private var scrollBoundsObserver: NSObjectProtocol?
    private var isHovered = false
    // Held as SwiftUI Colors and resolved to NSColor lazily in updateChrome(),
    // against this view's own live effectiveAppearance. Pre-resolving in
    // configure() is what caused the wrong-appearance freeze; see
    // SidebarChatRowHost.update(_:) and CodexAppKitColor.
    private var hoverColor: Color = .clear
    private var selectionColor: Color = .clear
    private var isSelected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        contentHost.setAccessibilityElement(false)
        actionsHost.isHidden = true
        addSubview(contentHost)
        addSubview(actionsHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        content: AnyView,
        actions: AnyView,
        hoverColor: Color,
        selectionColor: Color,
        isSelected: Bool
    ) {
        contentHost.rootView = content
        actionsHost.rootView = actions
        self.hoverColor = hoverColor
        self.selectionColor = selectionColor
        self.isSelected = isSelected
        updateChrome()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let actionsWidth = min(60, bounds.width)
        contentHost.frame = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(0, bounds.width - (isHovered ? actionsWidth : 0)),
            height: bounds.height
        )
        let actionsFrame = NSRect(
            x: bounds.maxX - actionsWidth,
            y: bounds.minY,
            width: actionsWidth,
            height: bounds.height
        )
        actionsHost.frame = actionsFrame
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installScrollBoundsObserverIfNeeded()
        if window == nil {
            setHovered(false)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        removeScrollBoundsObserver()
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            setHovered(false)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    /// A live appearance flip — system dark/light toggle, or this window's
    /// appearance override changing — does not by itself change `isHovered`
    /// or trigger SwiftUI's `updateNSView`, so nothing else would repaint
    /// this layer. Repaint explicitly.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChrome()
    }

    var contentHostIdentityForTesting: ObjectIdentifier { ObjectIdentifier(contentHost) }
    var contentHostWidthForTesting: CGFloat { contentHost.frame.width }
    var actionControlsAreVisibleForTesting: Bool { !actionsHost.isHidden }
    var backgroundColorForTesting: NSColor {
        NSColor(cgColor: layer?.backgroundColor ?? NSColor.clear.cgColor) ?? .clear
    }
    func setHoveredForTesting(_ hovered: Bool) {
        setHovered(hovered)
    }

    func reconcileHoverForTesting(pointerLocationInWindow: NSPoint) {
        reconcileHover(pointerLocationInWindow: pointerLocationInWindow)
    }

    private func removeScrollBoundsObserver() {
        if let scrollBoundsObserver {
            NotificationCenter.default.removeObserver(scrollBoundsObserver)
        }
        scrollBoundsObserver = nil
        observedScrollContentView = nil
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        updateChrome()
        needsLayout = true
    }

    private func installScrollBoundsObserverIfNeeded() {
        guard let contentView = enclosingScrollView?.contentView else { return }
        guard observedScrollContentView !== contentView else { return }

        removeScrollBoundsObserver()
        contentView.postsBoundsChangedNotifications = true
        observedScrollContentView = contentView
        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileHoverAfterScroll()
            }
        }
    }

    private func reconcileHoverAfterScroll() {
        guard let window else {
            setHovered(false)
            return
        }
        reconcileHover(pointerLocationInWindow: window.mouseLocationOutsideOfEventStream)
    }

    private func reconcileHover(pointerLocationInWindow: NSPoint) {
        let pointerLocation = convert(pointerLocationInWindow, from: nil)
        setHovered(bounds.contains(pointerLocation))
    }

    private func updateChrome() {
        let showsActions = isHovered
        let appearance = effectiveAppearance
        let resolvedHover = appearance.codexResolve(hoverColor)
        let resolvedSelection = appearance.codexResolve(selectionColor)
        // These remain translucent semantic tints. The sidebar's live glass
        // stays underneath instead of being flattened into an opaque surface.
        let background = isSelected
            ? resolvedSelection
            : (isHovered ? resolvedHover : NSColor.clear)
        layer?.backgroundColor = background.cgColor
        actionsHost.isHidden = !showsActions
    }
}

private struct SidebarSelectionBackground: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                theme.colors.textPrimary.opacity(
                    controlActiveState == .key ? 0.055 : 0.03
                )
            )
    }
}

enum SidebarChatRowLayout {
    static func hasTrailingStatus(
        attentionState: CodexSidebarAttentionState,
        showsRecency: Bool,
        recencyLabel: String
    ) -> Bool {
        attentionState != .idle || (showsRecency && !recencyLabel.isEmpty)
    }
}

private enum SidebarMetrics {
    static let expandedWidth: CGFloat = 276
    static let resizeHandleHitWidth: CGFloat = 8
}

public enum CodexWindowChromeMetrics {
    public static let trafficLightLeadingInset: CGFloat = 18
    public static let trafficLightTopInset: CGFloat = 14
    public static let titlebarHeight: CGFloat = 54
    public static let sidebarControlTopInset: CGFloat = 7
    public static let sidebarTrafficLightReserveWidth: CGFloat = 104
}

public extension CodexProjectSidebar {
    /// Default expanded width and the range the resize handle clamps to.
    static let defaultExpandedWidth: CGFloat = 276
    static let minExpandedWidth: CGFloat = 220
    static let maxExpandedWidth: CGFloat = 460
    /// Preserves the 540pt chat workspace beside the narrowest expanded sidebar.
    static let minimumExpandedShellWidth: CGFloat = minExpandedWidth + 540

    static func clampExpandedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minExpandedWidth), maxExpandedWidth)
    }
}
