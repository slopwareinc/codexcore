import Foundation

public enum CodexAppRoute: String, CaseIterable, Sendable, Equatable {
    case chat
    case search
    case plugins
    case automations
    case settingsAbout

    public static let primarySidebarRoutes: [CodexAppRoute] = [
        .plugins,
        .automations,
    ]

    public var title: String {
        switch self {
        case .chat: return "Chat"
        case .search: return "Search"
        case .plugins: return "Plugins"
        case .automations: return "Automations"
        case .settingsAbout: return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.text.bubble.right"
        case .search: return "magnifyingglass"
        case .plugins: return "puzzlepiece.extension"
        case .automations: return "clock.arrow.circlepath"
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
    public var liveStatus: CodexThreadLiveStatus
    public var hasUnreadWhileInactive: Bool
    public var isBulkSelected: Bool
    public var isArchived: Bool
    public var progress: Double?
    public var statusText: String?
    public var isPendingMutation: Bool

    public var id: String { summary.id }

    public init(
        summary: CodexThreadSummary,
        isSelected: Bool = false,
        isPinned: Bool = false,
        canPin: Bool = true,
        canArchive: Bool = true,
        liveStatus: CodexThreadLiveStatus = .idle,
        hasUnreadWhileInactive: Bool = false,
        isBulkSelected: Bool = false,
        isArchived: Bool = false,
        progress: Double? = nil,
        statusText: String? = nil,
        isPendingMutation: Bool = false
    ) {
        self.summary = summary
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.canPin = canPin
        self.canArchive = canArchive
        self.liveStatus = liveStatus
        self.hasUnreadWhileInactive = hasUnreadWhileInactive
        self.isBulkSelected = isBulkSelected
        self.isArchived = isArchived
        self.progress = progress.map { min(max($0, 0), 1) }
        self.statusText = statusText?.nilIfBlank
        self.isPendingMutation = isPendingMutation
    }
}

enum CodexSidebarAttentionState: Equatable, Sendable {
    case idle
    case unread
    case running
    case failed

    static func resolve(
        liveStatus: CodexThreadLiveStatus,
        hasUnreadWhileInactive: Bool
    ) -> Self {
        switch liveStatus {
        case .running:
            return .running
        case .failed:
            return .failed
        case .idle:
            return hasUnreadWhileInactive ? .unread : .idle
        }
    }

    static func aggregate(_ rows: [CodexSidebarThreadRow]) -> Self {
        let states = rows.map {
            resolve(
                liveStatus: $0.liveStatus,
                hasUnreadWhileInactive: $0.hasUnreadWhileInactive
            )
        }
        if states.contains(.running) { return .running }
        if states.contains(.failed) { return .failed }
        if states.contains(.unread) { return .unread }
        return .idle
    }
}

public struct CodexSidebarProjectGroup: Identifiable, Equatable, Sendable {
    public var project: CodexProjectSummary
    public var rows: [CodexSidebarThreadRow]
    public var hiddenRowCount: Int
    public var isExpanded: Bool
    public var isSelected: Bool
    public var isPinned: Bool
    public var canStartNewChat: Bool
    public var hasProjectActionsEntry: Bool

    public var id: String { project.id }

    public init(
        project: CodexProjectSummary,
        rows: [CodexSidebarThreadRow] = [],
        hiddenRowCount: Int = 0,
        isExpanded: Bool = false,
        isSelected: Bool = false,
        isPinned: Bool = false,
        canStartNewChat: Bool = true,
        hasProjectActionsEntry: Bool = true
    ) {
        self.project = project
        self.rows = rows
        self.hiddenRowCount = max(0, hiddenRowCount)
        self.isExpanded = isExpanded
        self.isSelected = isSelected
        self.isPinned = isPinned
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
    public var projectlessRows: [CodexSidebarThreadRow]
    public var pinnedProjects: [CodexSidebarProjectGroup]
    public var projects: [CodexSidebarProjectGroup]
    public var olderProjects: [CodexSidebarProjectGroup]
    public var sections: [CodexSidebarSectionGroup]
    public var archivedRows: [CodexSidebarThreadRow]
    public var archivedNextCursor: String?
    public var activeLoadState: CodexSidebarLoadState
    public var archivedLoadState: CodexSidebarLoadState
    public var actionErrorMessage: String?
    public var showsNoChats: Bool
    public var noChatsTitle: String
    public var isProjectlessSelected: Bool
    public var selectedThreadIDs: Set<String>
    public var isBulkSelectionMode: Bool

    public init(
        selectedRoute: CodexAppRoute,
        lastContentRoute: CodexAppRoute,
        isCollapsed: Bool,
        isSearchOverlayPresented: Bool,
        selectedProjectPath: String,
        selectedThreadID: String?,
        pinnedRows: [CodexSidebarThreadRow] = [],
        projectlessRows: [CodexSidebarThreadRow] = [],
        pinnedProjects: [CodexSidebarProjectGroup] = [],
        projects: [CodexSidebarProjectGroup],
        olderProjects: [CodexSidebarProjectGroup] = [],
        sections: [CodexSidebarSectionGroup] = [],
        archivedRows: [CodexSidebarThreadRow] = [],
        archivedNextCursor: String? = nil,
        activeLoadState: CodexSidebarLoadState = .loaded,
        archivedLoadState: CodexSidebarLoadState = .idle,
        actionErrorMessage: String? = nil,
        showsNoChats: Bool,
        noChatsTitle: String = "No chats",
        isProjectlessSelected: Bool = false,
        selectedThreadIDs: Set<String> = [],
        isBulkSelectionMode: Bool = false
    ) {
        self.selectedRoute = selectedRoute
        self.lastContentRoute = lastContentRoute
        self.isCollapsed = isCollapsed
        self.isSearchOverlayPresented = isSearchOverlayPresented
        self.selectedProjectPath = CodexProjectSummary.normalizedPath(selectedProjectPath)
        self.selectedThreadID = selectedThreadID
        self.pinnedRows = pinnedRows
        self.projectlessRows = projectlessRows
        self.pinnedProjects = pinnedProjects
        self.projects = projects
        self.olderProjects = olderProjects
        self.sections = sections
        self.archivedRows = archivedRows
        self.archivedNextCursor = archivedNextCursor
        self.activeLoadState = activeLoadState
        self.archivedLoadState = archivedLoadState
        self.actionErrorMessage = actionErrorMessage?.nilIfBlank
        self.showsNoChats = showsNoChats
        self.noChatsTitle = noChatsTitle
        self.isProjectlessSelected = isProjectlessSelected
        self.selectedThreadIDs = selectedThreadIDs
        self.isBulkSelectionMode = isBulkSelectionMode
    }
}

public enum CodexProjectDropPlacement: Sendable, Equatable {
    case before
    case after
}

public enum CodexSidebarArchiveSelectionGuard {
    public static func shouldClearSelection(
        selectedThreadIDAtStart: String?,
        currentSelectedThreadID: String?,
        selectionGenerationAtStart: Int,
        currentSelectionGeneration: Int,
        archivedThreadIDs: Set<String>
    ) -> Bool {
        guard let selectedThreadIDAtStart else { return false }
        return archivedThreadIDs.contains(selectedThreadIDAtStart)
            && currentSelectedThreadID == selectedThreadIDAtStart
            && currentSelectionGeneration == selectionGenerationAtStart
    }
}

public struct CodexSidebarNavigationSession: Sendable, Equatable {
    public static let projectChatPreviewLimit = 5
    public static let recentProjectInterval: TimeInterval = 7 * 24 * 60 * 60

    public private(set) var selectedRoute: CodexAppRoute
    public private(set) var lastContentRoute: CodexAppRoute
    public private(set) var isCollapsed: Bool
    public private(set) var isSearchOverlayPresented: Bool
    public private(set) var expandedProjectIDs: Set<String>
    public private(set) var projectOrder: [String]
    public private(set) var pinnedProjectIDs: [String]
    public private(set) var hiddenProjectIDs: Set<String>
    public private(set) var projectAliases: [String: String]
    public private(set) var expandedSectionIDs: Set<String>
    public private(set) var collapsedSectionIDs: Set<String>
    public private(set) var selectedThreadIDs: Set<String>
    public private(set) var isBulkSelectionMode: Bool
    public private(set) var sortKey: CodexSidebarSortKey
    public private(set) var selectedProjectPath: String
    public private(set) var selectedThreadID: String?
    public private(set) var isProjectlessSelected: Bool

    public init(
        currentWorkspacePath: String,
        selectedRoute: CodexAppRoute = .chat,
        isCollapsed: Bool = false,
        selectedThreadID: String? = nil,
        expandedProjectIDs: Set<String> = [],
        projectOrder: [String] = [],
        pinnedProjectIDs: [String] = [],
        hiddenProjectIDs: Set<String> = [],
        projectAliases: [String: String] = [:],
        expandedSectionIDs: Set<String> = [],
        collapsedSectionIDs: Set<String> = [],
        selectedThreadIDs: Set<String> = [],
        isBulkSelectionMode: Bool = false,
        sortKey: CodexSidebarSortKey = .recency
    ) {
        let normalized = CodexProjectSummary.normalizedPath(currentWorkspacePath)
        self.selectedRoute = selectedRoute
        self.lastContentRoute = selectedRoute == .search ? .chat : selectedRoute
        self.isCollapsed = isCollapsed
        self.isSearchOverlayPresented = selectedRoute == .search
        self.expandedProjectIDs = Set(expandedProjectIDs.compactMap { id in
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalizedID = CodexProjectSummary.normalizedPath(trimmed)
            return normalizedID.isEmpty ? nil : normalizedID
        })
        self.projectOrder = Self.normalizedProjectOrder(projectOrder)
        self.pinnedProjectIDs = Self.normalizedProjectOrder(pinnedProjectIDs)
        self.hiddenProjectIDs = Set(hiddenProjectIDs.compactMap(Self.normalizedID))
        self.projectAliases = Dictionary(uniqueKeysWithValues: projectAliases.compactMap { path, alias in
            guard let id = Self.normalizedID(path), let name = alias.nilIfBlank else { return nil }
            return (id, name)
        })
        self.expandedSectionIDs = Set(expandedSectionIDs.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        self.collapsedSectionIDs = Set(collapsedSectionIDs.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        self.selectedThreadIDs = selectedThreadIDs
        self.isBulkSelectionMode = isBulkSelectionMode
        self.sortKey = sortKey
        self.selectedProjectPath = normalized
        self.selectedThreadID = selectedThreadID
        self.isProjectlessSelected = false
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

    public mutating func setExpandedProjects(_ workspacePaths: Set<String>) {
        expandedProjectIDs = Set(workspacePaths.compactMap(Self.normalizedID))
    }

    public mutating func expandProject(_ workspacePath: String) {
        let id = CodexProjectSummary.normalizedPath(workspacePath)
        expandedProjectIDs.insert(id)
    }

    public mutating func toggleSection(_ sectionID: String) {
        let id = sectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if collapsedSectionIDs.contains(id) {
            collapsedSectionIDs.remove(id)
        } else {
            collapsedSectionIDs.insert(id)
        }
    }

    public mutating func setExpandedSections(_ sectionIDs: Set<String>) {
        expandedSectionIDs = Set(sectionIDs.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        collapsedSectionIDs.removeAll()
    }

    public mutating func setBulkSelectionMode(_ enabled: Bool) {
        isBulkSelectionMode = enabled
        if !enabled { selectedThreadIDs.removeAll() }
    }

    public mutating func toggleThreadSelection(_ threadID: String) {
        let id = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        isBulkSelectionMode = true
        if !selectedThreadIDs.insert(id).inserted {
            selectedThreadIDs.remove(id)
        }
    }

    public mutating func selectThreads(_ threadIDs: [String]) {
        selectedThreadIDs.formUnion(threadIDs.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        isBulkSelectionMode = !selectedThreadIDs.isEmpty
    }

    public mutating func clearThreadSelection() {
        selectedThreadIDs.removeAll()
        isBulkSelectionMode = false
    }

    public mutating func removeThreadSelections(_ threadIDs: Set<String>) {
        selectedThreadIDs.subtract(threadIDs)
        if selectedThreadIDs.isEmpty { isBulkSelectionMode = false }
    }

    public mutating func setSortKey(_ sortKey: CodexSidebarSortKey) {
        self.sortKey = sortKey
    }

    @discardableResult
    public mutating func moveProject(
        _ sourcePath: String,
        relativeTo targetPath: String,
        placement: CodexProjectDropPlacement,
        among projects: [CodexProjectSummary]
    ) -> Bool {
        let source = CodexProjectSummary.normalizedPath(sourcePath)
        let target = CodexProjectSummary.normalizedPath(targetPath)
        guard source != target else { return false }

        var order = projects.map(\.workspacePath)
            .sorted { lhs, rhs in
                let left = projectOrder.firstIndex(of: lhs)
                let right = projectOrder.firstIndex(of: rhs)
                switch (left, right) {
                case let (left?, right?): return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs < rhs
                }
            }
        if !order.contains(source) { order.append(source) }
        if !order.contains(target) { order.append(target) }
        let previous = order

        guard let reordered = CodexSidebarMutation.reordered(
            sourceID: source,
            targetID: target,
            placement: placement,
            in: order
        ) else { return false }
        order = reordered
        projectOrder = order
        return order != previous
    }

    public mutating func setProjectOrder(_ order: [String]) {
        projectOrder = Self.normalizedProjectOrder(order)
    }

    public mutating func setPinnedProjectIDs(_ ids: [String]) {
        pinnedProjectIDs = Self.normalizedProjectOrder(ids)
    }

    @discardableResult
    public mutating func toggleProjectPin(_ workspacePath: String) -> Bool {
        let id = CodexProjectSummary.normalizedPath(workspacePath)
        let mutation = CodexSidebarMutation.toggledPin(id: id, in: pinnedProjectIDs)
        pinnedProjectIDs = mutation.ids
        return mutation.isPinned
    }

    public mutating func renameProject(_ workspacePath: String, displayName: String) {
        let id = CodexProjectSummary.normalizedPath(workspacePath)
        if let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            projectAliases[id] = name
        } else {
            projectAliases.removeValue(forKey: id)
        }
    }

    public mutating func removeProject(_ workspacePath: String) {
        let id = CodexProjectSummary.normalizedPath(workspacePath)
        hiddenProjectIDs.insert(id)
        pinnedProjectIDs.removeAll { $0 == id }
    }

    public mutating func replaceProjectPath(
        _ oldPath: String,
        with newPath: String
    ) {
        let oldID = CodexProjectSummary.normalizedPath(oldPath)
        let newID = CodexProjectSummary.normalizedPath(newPath)
        guard oldID != newID else { return }

        if expandedProjectIDs.remove(oldID) != nil {
            expandedProjectIDs.insert(newID)
        }
        if hiddenProjectIDs.remove(oldID) != nil {
            hiddenProjectIDs.insert(newID)
        }
        projectOrder = Self.replacing(oldID, with: newID, in: projectOrder)
        pinnedProjectIDs = Self.replacing(oldID, with: newID, in: pinnedProjectIDs)
        if let alias = projectAliases.removeValue(forKey: oldID) {
            projectAliases[newID] = alias
        }
        if selectedProjectPath == oldID {
            selectedProjectPath = newID
        }
    }

    @discardableResult
    public mutating func restoreProject(_ workspacePath: String) -> Bool {
        hiddenProjectIDs.remove(CodexProjectSummary.normalizedPath(workspacePath)) != nil
    }

    public mutating func selectProject(_ workspacePath: String) {
        let normalized = CodexProjectSummary.normalizedPath(workspacePath)
        selectedProjectPath = normalized
        expandedProjectIDs.insert(normalized)
        selectedThreadID = nil
        isProjectlessSelected = false
        selectRoute(.chat)
    }

    public mutating func startNewChat(workspacePath: String) {
        let normalized = CodexProjectSummary.normalizedPath(workspacePath)
        selectedProjectPath = normalized
        expandedProjectIDs.insert(normalized)
        selectedThreadID = nil
        isProjectlessSelected = false
        selectRoute(.chat)
    }

    public mutating func startNewProjectlessChat() {
        selectedThreadID = nil
        isProjectlessSelected = true
        selectRoute(.chat)
    }

    public mutating func selectChat(_ threadID: String, workspacePath: String?) {
        selectedThreadID = threadID
        isProjectlessSelected = false
        if let workspacePath, !workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = CodexProjectSummary.normalizedPath(workspacePath)
            selectedProjectPath = normalized
            expandedProjectIDs.insert(normalized)
        }
        selectRoute(.chat)
    }

    public mutating func selectProjectlessChat(_ threadID: String) {
        selectedThreadID = threadID
        isProjectlessSelected = true
        selectRoute(.chat)
    }

    public mutating func syncCurrentWorkspace(_ workspacePath: String, currentThreadID: String?) {
        let normalized = CodexProjectSummary.normalizedPath(workspacePath)
        selectedProjectPath = normalized
        expandedProjectIDs.insert(normalized)
        selectedThreadID = currentThreadID
        isProjectlessSelected = false
    }

    public func snapshot(
        projects: [CodexProjectSummary],
        chats: [CodexThreadSummary],
        currentWorkspacePath: String,
        currentThreadID: String?,
        pinnedThreadIDs: [String] = [],
        projectlessThreadIDs: Set<String> = [],
        threadStatusEntries: [String: CodexThreadStatusEntry] = [:],
        archivedChats: [CodexThreadSummary] = [],
        sections: [CodexSidebarSectionSummary] = [],
        archivedNextCursor: String? = nil,
        activeLoadState: CodexSidebarLoadState = .loaded,
        archivedLoadState: CodexSidebarLoadState = .idle,
        actionErrorMessage: String? = nil,
        pendingThreadIDs: Set<String> = [],
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> CodexSidebarSnapshot {
        CodexSidebarProjection.snapshot(.init(
            projects: projects,
            chats: chats,
            archivedChats: archivedChats,
            sections: sections,
            currentWorkspacePath: currentWorkspacePath,
            currentThreadID: currentThreadID,
            pinnedThreadIDs: pinnedThreadIDs,
            projectlessThreadIDs: projectlessThreadIDs,
            expandedProjectIDs: expandedProjectIDs,
            expandedSectionIDs: expandedSectionIDs,
            collapsedSectionIDs: collapsedSectionIDs,
            projectOrder: projectOrder,
            pinnedProjectIDs: pinnedProjectIDs,
            hiddenProjectIDs: hiddenProjectIDs,
            projectAliases: projectAliases,
            selectedProjectPath: selectedProjectPath,
            selectedThreadID: selectedThreadID,
            isProjectlessSelected: isProjectlessSelected,
            selectedThreadIDs: selectedThreadIDs,
            isBulkSelectionMode: isBulkSelectionMode,
            selectedRoute: selectedRoute,
            lastContentRoute: lastContentRoute,
            isCollapsed: isCollapsed,
            isSearchOverlayPresented: isSearchOverlayPresented,
            activeLoadState: activeLoadState,
            archivedLoadState: archivedLoadState,
            archivedNextCursor: archivedNextCursor,
            threadStatusEntries: threadStatusEntries,
            actionErrorMessage: actionErrorMessage,
            pendingThreadIDs: pendingThreadIDs,
            now: now,
            projectChatPreviewLimit: Self.projectChatPreviewLimit,
            recentProjectInterval: Self.recentProjectInterval,
            sortKey: sortKey
        ))
    }

    public static func defaultExpandedProjectIDs(projects _: [CodexProjectSummary], now _: TimeInterval = Date().timeIntervalSince1970) -> Set<String> {
        []
    }

    private static func normalizedID(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalizedID = CodexProjectSummary.normalizedPath(trimmed)
        return normalizedID.isEmpty ? nil : normalizedID
    }

    private static func normalizedProjectOrder(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            guard let normalized = normalizedID(path), seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func replacing(
        _ oldID: String,
        with newID: String,
        in ids: [String]
    ) -> [String] {
        normalizedProjectOrder(ids.map { $0 == oldID ? newID : $0 })
    }

}
