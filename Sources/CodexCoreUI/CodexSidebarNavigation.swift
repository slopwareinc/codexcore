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
    public var canUnarchive: Bool
    public var canDelete: Bool
    public var liveStatus: CodexThreadLiveStatus
    public var hasUnreadWhileInactive: Bool

    public var id: String { summary.id }

    public init(
        summary: CodexThreadSummary,
        isSelected: Bool = false,
        isPinned: Bool = false,
        canPin: Bool = true,
        canArchive: Bool = true,
        canUnarchive: Bool = false,
        canDelete: Bool = false,
        liveStatus: CodexThreadLiveStatus = .idle,
        hasUnreadWhileInactive: Bool = false
    ) {
        self.summary = summary
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.canPin = canPin
        self.canArchive = canArchive
        self.canUnarchive = canUnarchive
        self.canDelete = canDelete
        self.liveStatus = liveStatus
        self.hasUnreadWhileInactive = hasUnreadWhileInactive
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
    public var archivedRows: [CodexSidebarThreadRow]
    public var pinnedProjects: [CodexSidebarProjectGroup]
    public var projects: [CodexSidebarProjectGroup]
    public var olderProjects: [CodexSidebarProjectGroup]
    public var showsNoChats: Bool
    public var noChatsTitle: String
    public var isProjectlessSelected: Bool

    public init(
        selectedRoute: CodexAppRoute,
        lastContentRoute: CodexAppRoute,
        isCollapsed: Bool,
        isSearchOverlayPresented: Bool,
        selectedProjectPath: String,
        selectedThreadID: String?,
        pinnedRows: [CodexSidebarThreadRow] = [],
        projectlessRows: [CodexSidebarThreadRow] = [],
        archivedRows: [CodexSidebarThreadRow] = [],
        pinnedProjects: [CodexSidebarProjectGroup] = [],
        projects: [CodexSidebarProjectGroup],
        olderProjects: [CodexSidebarProjectGroup] = [],
        showsNoChats: Bool,
        noChatsTitle: String = "No chats",
        isProjectlessSelected: Bool = false
    ) {
        self.selectedRoute = selectedRoute
        self.lastContentRoute = lastContentRoute
        self.isCollapsed = isCollapsed
        self.isSearchOverlayPresented = isSearchOverlayPresented
        self.selectedProjectPath = CodexProjectSummary.normalizedPath(selectedProjectPath)
        self.selectedThreadID = selectedThreadID
        self.pinnedRows = pinnedRows
        self.projectlessRows = projectlessRows
        self.archivedRows = archivedRows
        self.pinnedProjects = pinnedProjects
        self.projects = projects
        self.olderProjects = olderProjects
        self.showsNoChats = showsNoChats
        self.noChatsTitle = noChatsTitle
        self.isProjectlessSelected = isProjectlessSelected
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
        projectAliases: [String: String] = [:]
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

        var order = orderedProjects(projects).map(\.workspacePath)
        if !order.contains(source) { order.append(source) }
        if !order.contains(target) { order.append(target) }
        let previous = order

        order.removeAll { $0 == source }
        guard let targetIndex = order.firstIndex(of: target) else { return false }
        let insertionIndex = placement == .after ? targetIndex + 1 : targetIndex
        order.insert(source, at: insertionIndex)
        projectOrder = order
        return order != previous
    }

    @discardableResult
    public mutating func toggleProjectPin(_ workspacePath: String) -> Bool {
        let id = CodexProjectSummary.normalizedPath(workspacePath)
        if pinnedProjectIDs.contains(id) {
            pinnedProjectIDs.removeAll { $0 == id }
        } else {
            pinnedProjectIDs.insert(id, at: 0)
        }
        return pinnedProjectIDs.contains(id)
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
        archivedChats: [CodexThreadSummary] = [],
        currentWorkspacePath: String,
        currentThreadID: String?,
        pinnedThreadIDs: [String] = [],
        projectlessThreadIDs: Set<String> = [],
        threadStatusEntries: [String: CodexThreadStatusEntry] = [:]
    ) -> CodexSidebarSnapshot {
        let normalizedCurrent = CodexProjectSummary.normalizedPath(currentWorkspacePath)
        let effectiveThreadID = selectedThreadID ?? currentThreadID
        let pinnedOrder = Dictionary(uniqueKeysWithValues: pinnedThreadIDs.enumerated().map { ($0.element, $0.offset) })
        let pinnedIDSet = Set(pinnedThreadIDs)
        let projectChats = chats.filter { !projectlessThreadIDs.contains($0.id) }
        let effectiveProjects = projects.isEmpty
            ? CodexProjectSummary.projects(from: projectChats, currentWorkspacePath: normalizedCurrent)
            : projects

        let row: (CodexThreadSummary) -> CodexSidebarThreadRow = { chat in
            let live = threadStatusEntries[chat.id]
            return CodexSidebarThreadRow(
                summary: chat,
                isSelected: chat.id == effectiveThreadID,
                isPinned: pinnedIDSet.contains(chat.id),
                canPin: true,
                canArchive: true,
                canDelete: true,
                liveStatus: live?.status ?? .idle,
                hasUnreadWhileInactive: live?.hasUnreadWhileInactive ?? false
            )
        }

        let archivedRows = archivedChats.map { chat in
            CodexSidebarThreadRow(
                summary: chat,
                isSelected: chat.id == effectiveThreadID,
                isPinned: false,
                canPin: false,
                canArchive: false,
                canUnarchive: true,
                canDelete: true,
                liveStatus: .idle,
                hasUnreadWhileInactive: false
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

        let projectlessRows = chats
            .filter {
                projectlessThreadIDs.contains($0.id)
                    && !pinnedIDSet.contains($0.id)
            }
            .sorted(by: Self.compareByRecency)
            .map(row)

        let visibleProjects = effectiveProjects
            .filter { !hiddenProjectIDs.contains($0.workspacePath) }
            .map { project -> CodexProjectSummary in
                var project = project
                project.customDisplayName = projectAliases[project.workspacePath]
                return project
            }
        let orderedProjects = orderedProjects(visibleProjects)
        let pinnedProjectIDSet = Set(pinnedProjectIDs)

        let projectGroups = orderedProjects.map { project in
            let sortedChats = projectChats
                .filter { chat in
                    project.contains(workspacePath: chat.workspacePath ?? normalizedCurrent)
                }
                .sorted { lhs, rhs in
                    let leftPinned = pinnedIDSet.contains(lhs.id)
                    let rightPinned = pinnedIDSet.contains(rhs.id)
                    if leftPinned != rightPinned { return leftPinned && !rightPinned }
                    return Self.compareByRecency(lhs, rhs)
                }
            let visibleChats = Array(sortedChats.prefix(Self.projectChatPreviewLimit))
            return CodexSidebarProjectGroup(
                project: project,
                rows: visibleChats.map(row),
                hiddenRowCount: sortedChats.count - visibleChats.count,
                isExpanded: expandedProjectIDs.contains(project.workspacePath),
                isSelected: project.workspacePath == selectedProjectPath,
                isPinned: pinnedProjectIDSet.contains(project.workspacePath),
                canStartNewChat: true,
                hasProjectActionsEntry: true
            )
        }
        let recentCutoff = Date().timeIntervalSince1970 - Self.recentProjectInterval
        let pinnedProjectOrder = Dictionary(
            uniqueKeysWithValues: pinnedProjectIDs.enumerated().map { ($0.element, $0.offset) }
        )
        let pinnedGroups = projectGroups
            .filter { $0.isPinned }
            .sorted { lhs, rhs in
                let left = pinnedProjectOrder[lhs.project.workspacePath] ?? Int.max
                let right = pinnedProjectOrder[rhs.project.workspacePath] ?? Int.max
                return left < right
            }
        let unpinnedGroups = projectGroups.filter { !$0.isPinned }
        let recentGroups = unpinnedGroups.filter { group in
            group.project.updatedAt.map { $0 >= recentCutoff } ?? false
        }
        let olderGroups = unpinnedGroups.filter { group in
            group.project.updatedAt.map { $0 < recentCutoff } ?? true
        }

        return CodexSidebarSnapshot(
            selectedRoute: selectedRoute,
            lastContentRoute: lastContentRoute,
            isCollapsed: isCollapsed,
            isSearchOverlayPresented: isSearchOverlayPresented,
            selectedProjectPath: selectedProjectPath,
            selectedThreadID: effectiveThreadID,
            pinnedRows: pinnedRows,
            projectlessRows: projectlessRows,
            archivedRows: archivedRows,
            pinnedProjects: pinnedGroups,
            projects: recentGroups,
            olderProjects: olderGroups,
            showsNoChats: chats.isEmpty,
            isProjectlessSelected: isProjectlessSelected
        )
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

    private func orderedProjects(_ projects: [CodexProjectSummary]) -> [CodexProjectSummary] {
        let projectOrderIndex = Dictionary(uniqueKeysWithValues: projectOrder.enumerated().map { ($0.element, $0.offset) })
        return projects.sorted { lhs, rhs in
            let left = projectOrderIndex[lhs.workspacePath]
            let right = projectOrderIndex[rhs.workspacePath]
            switch (left, right) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
                return lhs.workspacePath.localizedCaseInsensitiveCompare(rhs.workspacePath) == .orderedAscending
            }
        }
    }

    private static func compareByRecency(_ lhs: CodexThreadSummary, _ rhs: CodexThreadSummary) -> Bool {
        let left = lhs.recencyAt ?? lhs.updatedAt ?? lhs.createdAt ?? 0
        let right = rhs.recencyAt ?? rhs.updatedAt ?? rhs.createdAt ?? 0
        if left != right { return left > right }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}
