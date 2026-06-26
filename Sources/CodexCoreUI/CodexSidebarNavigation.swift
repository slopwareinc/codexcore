import Foundation

public enum CodexAppRoute: String, CaseIterable, Sendable, Equatable {
    case chat
    case search
    case plugins
    case automations
    case codexMobile
    case settingsAbout

    public var title: String {
        switch self {
        case .chat: return "Chat"
        case .search: return "Search"
        case .plugins: return "Plugins"
        case .automations: return "Automations"
        case .codexMobile: return "Codex mobile"
        case .settingsAbout: return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.text.bubble.right"
        case .search: return "magnifyingglass"
        case .plugins: return "puzzlepiece.extension"
        case .automations: return "clock.arrow.circlepath"
        case .codexMobile: return "iphone"
        case .settingsAbout: return "gearshape"
        }
    }
}

public struct CodexSidebarThreadRow: Identifiable, Equatable, Sendable {
    public var summary: CodexThreadSummary
    public var isSelected: Bool
    public var isPinned: Bool
    public var canPin: Bool
    public var canArchive: Bool

    public var id: String { summary.id }

    public init(
        summary: CodexThreadSummary,
        isSelected: Bool = false,
        isPinned: Bool = false,
        canPin: Bool = true,
        canArchive: Bool = true
    ) {
        self.summary = summary
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.canPin = canPin
        self.canArchive = canArchive
    }
}

public struct CodexSidebarProjectGroup: Identifiable, Equatable, Sendable {
    public var project: CodexProjectSummary
    public var rows: [CodexSidebarThreadRow]
    public var isExpanded: Bool
    public var isSelected: Bool
    public var canStartNewChat: Bool
    public var hasProjectActionsEntry: Bool

    public var id: String { project.id }

    public init(
        project: CodexProjectSummary,
        rows: [CodexSidebarThreadRow] = [],
        isExpanded: Bool = false,
        isSelected: Bool = false,
        canStartNewChat: Bool = true,
        hasProjectActionsEntry: Bool = true
    ) {
        self.project = project
        self.rows = rows
        self.isExpanded = isExpanded
        self.isSelected = isSelected
        self.canStartNewChat = canStartNewChat
        self.hasProjectActionsEntry = hasProjectActionsEntry
    }
}

public struct CodexSidebarSnapshot: Equatable, Sendable {
    public var selectedRoute: CodexAppRoute
    public var lastContentRoute: CodexAppRoute
    public var isCollapsed: Bool
    public var isSearchOverlayPresented: Bool
    public var selectedProjectPath: String
    public var selectedThreadID: String?
    public var pinnedRows: [CodexSidebarThreadRow]
    public var projects: [CodexSidebarProjectGroup]
    public var showsNoChats: Bool
    public var noChatsTitle: String

    public init(
        selectedRoute: CodexAppRoute,
        lastContentRoute: CodexAppRoute,
        isCollapsed: Bool,
        isSearchOverlayPresented: Bool,
        selectedProjectPath: String,
        selectedThreadID: String?,
        pinnedRows: [CodexSidebarThreadRow] = [],
        projects: [CodexSidebarProjectGroup],
        showsNoChats: Bool,
        noChatsTitle: String = "No chats"
    ) {
        self.selectedRoute = selectedRoute
        self.lastContentRoute = lastContentRoute
        self.isCollapsed = isCollapsed
        self.isSearchOverlayPresented = isSearchOverlayPresented
        self.selectedProjectPath = CodexProjectSummary.normalizedPath(selectedProjectPath)
        self.selectedThreadID = selectedThreadID
        self.pinnedRows = pinnedRows
        self.projects = projects
        self.showsNoChats = showsNoChats
        self.noChatsTitle = noChatsTitle
    }
}

public struct CodexSidebarNavigationSession: Sendable, Equatable {
    public private(set) var selectedRoute: CodexAppRoute
    public private(set) var lastContentRoute: CodexAppRoute
    public private(set) var isCollapsed: Bool
    public private(set) var isSearchOverlayPresented: Bool
    public private(set) var expandedProjectIDs: Set<String>
    public private(set) var selectedProjectPath: String
    public private(set) var selectedThreadID: String?

    public init(
        currentWorkspacePath: String,
        selectedRoute: CodexAppRoute = .chat,
        isCollapsed: Bool = false,
        selectedThreadID: String? = nil
    ) {
        let normalized = CodexProjectSummary.normalizedPath(currentWorkspacePath)
        self.selectedRoute = selectedRoute
        self.lastContentRoute = selectedRoute == .search ? .chat : selectedRoute
        self.isCollapsed = isCollapsed
        self.isSearchOverlayPresented = selectedRoute == .search
        self.expandedProjectIDs = [normalized]
        self.selectedProjectPath = normalized
        self.selectedThreadID = selectedThreadID
    }

    public mutating func selectRoute(_ route: CodexAppRoute) {
        selectedRoute = route
        if route == .search {
            isSearchOverlayPresented = true
        } else {
            lastContentRoute = route
            isSearchOverlayPresented = false
        }
    }

    public mutating func dismissSearchOverlay() {
        isSearchOverlayPresented = false
        if selectedRoute == .search {
            selectedRoute = lastContentRoute
        }
    }

    public mutating func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
    }

    public mutating func toggleCollapsed() {
        isCollapsed.toggle()
    }

    public mutating func toggleProject(_ workspacePath: String) {
        let id = CodexProjectSummary.normalizedPath(workspacePath)
        if expandedProjectIDs.contains(id) {
            expandedProjectIDs.remove(id)
        } else {
            expandedProjectIDs.insert(id)
        }
    }

    public mutating func expandProject(_ workspacePath: String) {
        let id = CodexProjectSummary.normalizedPath(workspacePath)
        expandedProjectIDs.insert(id)
    }

    public mutating func selectProject(_ workspacePath: String) {
        let normalized = CodexProjectSummary.normalizedPath(workspacePath)
        selectedProjectPath = normalized
        selectedThreadID = nil
        expandedProjectIDs.insert(normalized)
        selectRoute(.chat)
    }

    public mutating func startNewChat(workspacePath: String) {
        let normalized = CodexProjectSummary.normalizedPath(workspacePath)
        selectedProjectPath = normalized
        selectedThreadID = nil
        expandedProjectIDs.insert(normalized)
        selectRoute(.chat)
    }

    public mutating func selectChat(_ threadID: String, workspacePath: String?) {
        selectedThreadID = threadID
        if let workspacePath, !workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = CodexProjectSummary.normalizedPath(workspacePath)
            selectedProjectPath = normalized
            expandedProjectIDs.insert(normalized)
        }
        selectRoute(.chat)
    }

    public mutating func syncCurrentWorkspace(_ workspacePath: String, currentThreadID: String?) {
        let normalized = CodexProjectSummary.normalizedPath(workspacePath)
        selectedProjectPath = normalized
        selectedThreadID = currentThreadID
        expandedProjectIDs.insert(normalized)
    }

    public func snapshot(
        projects: [CodexProjectSummary],
        chats: [CodexThreadSummary],
        currentWorkspacePath: String,
        currentThreadID: String?,
        pinnedThreadIDs: [String] = []
    ) -> CodexSidebarSnapshot {
        let normalizedCurrent = CodexProjectSummary.normalizedPath(currentWorkspacePath)
        let effectiveThreadID = selectedThreadID ?? currentThreadID
        let pinnedOrder = Dictionary(uniqueKeysWithValues: pinnedThreadIDs.enumerated().map { ($0.element, $0.offset) })
        let pinnedIDSet = Set(pinnedThreadIDs)
        let effectiveProjects = projects.isEmpty
            ? CodexProjectSummary.projects(from: chats, currentWorkspacePath: normalizedCurrent)
            : projects

        let groupedChats = Dictionary(grouping: chats) { summary in
            CodexProjectSummary.normalizedPath(summary.workspacePath ?? normalizedCurrent)
        }

        let row: (CodexThreadSummary) -> CodexSidebarThreadRow = { chat in
            CodexSidebarThreadRow(
                summary: chat,
                isSelected: chat.id == effectiveThreadID,
                isPinned: pinnedIDSet.contains(chat.id),
                canPin: true,
                canArchive: true
            )
        }

        let pinnedRows = chats
            .filter { pinnedIDSet.contains($0.id) }
            .sorted { lhs, rhs in
                let left = pinnedOrder[lhs.id] ?? Int.max
                let right = pinnedOrder[rhs.id] ?? Int.max
                if left != right { return left < right }
                return Self.compareByRecency(lhs, rhs)
            }
            .map(row)

        let projectGroups = effectiveProjects.map { project in
            let rows = (groupedChats[project.workspacePath] ?? [])
                .sorted { lhs, rhs in
                    let leftPinned = pinnedIDSet.contains(lhs.id)
                    let rightPinned = pinnedIDSet.contains(rhs.id)
                    if leftPinned != rightPinned { return leftPinned && !rightPinned }
                    return Self.compareByRecency(lhs, rhs)
                }
                .map(row)
            return CodexSidebarProjectGroup(
                project: project,
                rows: rows,
                isExpanded: expandedProjectIDs.contains(project.workspacePath),
                isSelected: project.workspacePath == selectedProjectPath,
                canStartNewChat: true,
                hasProjectActionsEntry: true
            )
        }

        return CodexSidebarSnapshot(
            selectedRoute: selectedRoute,
            lastContentRoute: lastContentRoute,
            isCollapsed: isCollapsed,
            isSearchOverlayPresented: isSearchOverlayPresented,
            selectedProjectPath: selectedProjectPath,
            selectedThreadID: effectiveThreadID,
            pinnedRows: pinnedRows,
            projects: projectGroups,
            showsNoChats: chats.isEmpty
        )
    }

    private static func compareByRecency(_ lhs: CodexThreadSummary, _ rhs: CodexThreadSummary) -> Bool {
        let left = lhs.recencyAt ?? lhs.updatedAt ?? lhs.createdAt ?? 0
        let right = rhs.recencyAt ?? rhs.updatedAt ?? rhs.createdAt ?? 0
        if left != right { return left > right }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}
