import Foundation
import CodexCore

/// Server-owned metadata for one independently persisted sidebar section.
/// The projection intentionally copies this value instead of letting local
/// expansion/selection preferences mutate the canonical section fact.
public struct CodexSidebarSectionSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var icon: String?
    public var color: String?
    public var position: Int

    public init(
        id: String,
        name: String,
        icon: String? = nil,
        color: String? = nil,
        position: Int = 0
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.position = position
    }

    public init(schema: CodexSchemaThreadSection, position: Int = 0) {
        self.init(
            id: schema.id,
            name: schema.name,
            icon: schema.appearance?.icon,
            color: schema.appearance?.color,
            position: position
        )
    }
}

public struct CodexSidebarSectionGroup: Identifiable, Equatable, Sendable {
    public var section: CodexSidebarSectionSummary
    public var rows: [CodexSidebarThreadRow]
    public var isExpanded: Bool
    public var isSelected: Bool

    public var id: String { section.id }

    public init(
        section: CodexSidebarSectionSummary,
        rows: [CodexSidebarThreadRow] = [],
        isExpanded: Bool = true,
        isSelected: Bool = false
    ) {
        self.section = section
        self.rows = rows
        self.isExpanded = isExpanded
        self.isSelected = isSelected
    }
}

public enum CodexSidebarLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var errorMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

public enum CodexSidebarSortKey: String, CaseIterable, Sendable, Equatable {
    case recency
    case title
    case createdAt
    case updatedAt
}

/// The only input accepted by the sidebar projection. Server task/project
/// facts are supplied separately from presentation preferences, which prevents
/// a pin, alias, expansion, or selection from leaking back into protocol data.
public struct CodexSidebarProjectionInput: Sendable, Equatable {
    public var projects: [CodexProjectSummary]
    public var chats: [CodexThreadSummary]
    public var archivedChats: [CodexThreadSummary]
    public var sections: [CodexSidebarSectionSummary]
    public var currentWorkspacePath: String
    public var currentThreadID: String?
    public var pinnedThreadIDs: [String]
    public var projectlessThreadIDs: Set<String>
    public var expandedProjectIDs: Set<String>
    public var expandedSectionIDs: Set<String>
    public var collapsedSectionIDs: Set<String>
    public var projectOrder: [String]
    public var pinnedProjectIDs: [String]
    public var hiddenProjectIDs: Set<String>
    public var projectAliases: [String: String]
    public var selectedProjectPath: String
    public var selectedThreadID: String?
    public var isProjectlessSelected: Bool
    public var selectedThreadIDs: Set<String>
    public var isBulkSelectionMode: Bool
    public var selectedRoute: CodexAppRoute
    public var lastContentRoute: CodexAppRoute
    public var isCollapsed: Bool
    public var isSearchOverlayPresented: Bool
    public var activeLoadState: CodexSidebarLoadState
    public var archivedLoadState: CodexSidebarLoadState
    public var archivedNextCursor: String?
    public var threadStatusEntries: [String: CodexThreadStatusEntry]
    public var actionErrorMessage: String?
    public var pendingThreadIDs: Set<String>
    public var now: TimeInterval
    public var projectChatPreviewLimit: Int
    public var recentProjectInterval: TimeInterval
    public var sortKey: CodexSidebarSortKey

    public init(
        projects: [CodexProjectSummary] = [],
        chats: [CodexThreadSummary] = [],
        archivedChats: [CodexThreadSummary] = [],
        sections: [CodexSidebarSectionSummary] = [],
        currentWorkspacePath: String,
        currentThreadID: String? = nil,
        pinnedThreadIDs: [String] = [],
        projectlessThreadIDs: Set<String> = [],
        expandedProjectIDs: Set<String> = [],
        expandedSectionIDs: Set<String> = [],
        collapsedSectionIDs: Set<String> = [],
        projectOrder: [String] = [],
        pinnedProjectIDs: [String] = [],
        hiddenProjectIDs: Set<String> = [],
        projectAliases: [String: String] = [:],
        selectedProjectPath: String? = nil,
        selectedThreadID: String? = nil,
        isProjectlessSelected: Bool = false,
        selectedThreadIDs: Set<String> = [],
        isBulkSelectionMode: Bool = false,
        selectedRoute: CodexAppRoute = .chat,
        lastContentRoute: CodexAppRoute = .chat,
        isCollapsed: Bool = false,
        isSearchOverlayPresented: Bool = false,
        activeLoadState: CodexSidebarLoadState = .loaded,
        archivedLoadState: CodexSidebarLoadState = .idle,
        archivedNextCursor: String? = nil,
        threadStatusEntries: [String: CodexThreadStatusEntry] = [:],
        actionErrorMessage: String? = nil,
        pendingThreadIDs: Set<String> = [],
        now: TimeInterval = Date().timeIntervalSince1970,
        projectChatPreviewLimit: Int = 5,
        recentProjectInterval: TimeInterval = 7 * 24 * 60 * 60,
        sortKey: CodexSidebarSortKey = .recency
    ) {
        self.projects = projects
        self.chats = chats
        self.archivedChats = archivedChats
        self.sections = sections
        self.currentWorkspacePath = CodexProjectSummary.normalizedPath(currentWorkspacePath)
        self.currentThreadID = currentThreadID
        self.pinnedThreadIDs = Self.normalizedIDs(pinnedThreadIDs)
        self.projectlessThreadIDs = Set(projectlessThreadIDs)
        self.expandedProjectIDs = Set(expandedProjectIDs.map(CodexProjectSummary.normalizedPath))
        self.expandedSectionIDs = Set(expandedSectionIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        self.collapsedSectionIDs = Set(collapsedSectionIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        self.projectOrder = Self.normalizedIDs(projectOrder)
        self.pinnedProjectIDs = Self.normalizedIDs(pinnedProjectIDs)
        self.hiddenProjectIDs = Set(hiddenProjectIDs.map(CodexProjectSummary.normalizedPath))
        self.projectAliases = Dictionary(uniqueKeysWithValues: projectAliases.compactMap { path, alias in
            let normalized = CodexProjectSummary.normalizedPath(path)
            guard let alias = alias.nilIfBlank else { return nil }
            return (normalized, alias)
        })
        self.selectedProjectPath = CodexProjectSummary.normalizedPath(selectedProjectPath ?? currentWorkspacePath)
        self.selectedThreadID = selectedThreadID ?? currentThreadID
        self.isProjectlessSelected = isProjectlessSelected
        self.selectedThreadIDs = selectedThreadIDs
        self.isBulkSelectionMode = isBulkSelectionMode
        self.selectedRoute = selectedRoute
        self.lastContentRoute = lastContentRoute
        self.isCollapsed = isCollapsed
        self.isSearchOverlayPresented = isSearchOverlayPresented
        self.activeLoadState = activeLoadState
        self.archivedLoadState = archivedLoadState
        self.archivedNextCursor = archivedNextCursor
        self.threadStatusEntries = threadStatusEntries
        self.actionErrorMessage = actionErrorMessage?.nilIfBlank
        self.pendingThreadIDs = pendingThreadIDs
        self.now = now
        self.projectChatPreviewLimit = max(1, projectChatPreviewLimit)
        self.recentProjectInterval = max(0, recentProjectInterval)
        self.sortKey = sortKey
    }

    private static func normalizedIDs(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.compactMap { id in
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}

public enum CodexSidebarProjection {
    /// Combines authoritative project/list facts with the host's local
    /// multi-folder presentation preferences. No display alias, hidden flag,
    /// or ordering is written into the returned server summaries.
    public static func presentedProjects(
        serverProjects: [CodexProjectSummary],
        chats: [CodexThreadSummary],
        currentWorkspacePath: String,
        projectlessThreadIDs: Set<String>,
        sourceFoldersByPrimaryPath: [String: [String]]
    ) -> [CodexProjectSummary] {
        let projectChats = chats.filter { !projectlessThreadIDs.contains($0.id) }
        let inferred = serverProjects.isEmpty
            ? CodexProjectSummary.projects(from: projectChats, currentWorkspacePath: currentWorkspacePath)
            : serverProjects
        guard !sourceFoldersByPrimaryPath.isEmpty else { return inferred }

        let claimedRoots = Set(sourceFoldersByPrimaryPath.values.flatMap { $0 })
        var projects = inferred.filter { !claimedRoots.contains($0.workspacePath) }
        for (primary, roots) in sourceFoldersByPrimaryPath {
            let members = inferred.filter { roots.contains($0.workspacePath) }
            let chatCount = members.reduce(0) { $0 + $1.chatCount }
            let updatedAt = members.compactMap(\.updatedAt).max()
            let serverRepresentative = members.first
            projects.append(CodexProjectSummary(
                workspacePath: primary,
                sourceFolders: roots,
                chatCount: chatCount,
                updatedAt: updatedAt,
                serverID: serverRepresentative?.serverID,
                serverName: serverRepresentative?.serverName,
                serverPosition: serverRepresentative?.serverPosition
            ))
        }
        return projects.sorted {
            let name = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if name != .orderedSame { return name == .orderedAscending }
            return $0.workspacePath < $1.workspacePath
        }
    }

    /// Fast, allocation-bounded local filtering used while the server search
    /// request is in flight. It scans each summary once and applies the same
    /// deterministic tie-breakers as the rendered rows.
    public static func search(
        _ summaries: [CodexThreadSummary],
        query: String,
        sortKey: CodexSidebarSortKey = .recency,
        limit: Int? = nil
    ) -> [CodexThreadSummary] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !term.isEmpty else { return [] }
        let matches = summaries.filter { summary in
            [summary.title, summary.preview, summary.workspacePath ?? "", summary.sectionName ?? ""]
                .contains { $0.localizedLowercase.contains(term) }
        }
        let sorted = matches.sorted { compareThreads($0, $1, sortKey: sortKey) }
        guard let limit else { return sorted }
        return Array(sorted.prefix(max(0, limit)))
    }

    public static func snapshot(_ input: CodexSidebarProjectionInput) -> CodexSidebarSnapshot {
        let normalizedCurrent = CodexProjectSummary.normalizedPath(input.currentWorkspacePath)
        let effectiveThreadID = input.selectedThreadID ?? input.currentThreadID
        let pinnedIDs = Set(input.pinnedThreadIDs)
        let selectableIDs = Set(input.chats.map(\.id))
        let selectedThreadIDs = input.selectedThreadIDs.intersection(selectableIDs)
        let pinnedOrder = Dictionary(uniqueKeysWithValues: input.pinnedThreadIDs.enumerated().map { ($0.element, $0.offset) })
        let projectlessIDs = input.projectlessThreadIDs
        let row: (CodexThreadSummary, Bool) -> CodexSidebarThreadRow = { chat, archived in
            let live = archived ? nil : input.threadStatusEntries[chat.id]
            return CodexSidebarThreadRow(
                summary: chat,
                isSelected: !archived && chat.id == effectiveThreadID,
                isPinned: !archived && pinnedIDs.contains(chat.id),
                canPin: !archived,
                canArchive: !archived,
                liveStatus: live?.status ?? .idle,
                hasUnreadWhileInactive: live?.hasUnreadWhileInactive ?? false,
                isBulkSelected: selectedThreadIDs.contains(chat.id),
                isArchived: archived,
                progress: live?.progress,
                statusText: live?.statusText,
                isPendingMutation: input.pendingThreadIDs.contains(chat.id)
            )
        }

        let pinnedRows = input.chats
            .filter { pinnedIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let left = pinnedOrder[lhs.id] ?? Int.max
                let right = pinnedOrder[rhs.id] ?? Int.max
                if left != right { return left < right }
                return compareThreads(lhs, rhs)
            }
            .map { row($0, false) }

        let activeChats = input.chats.filter { !pinnedIDs.contains($0.id) }
        let effectiveProjects = input.projects.isEmpty
            ? presentedProjects(
                serverProjects: [],
                chats: activeChats,
                currentWorkspacePath: normalizedCurrent,
                projectlessThreadIDs: projectlessIDs,
                sourceFoldersByPrimaryPath: [:]
            )
            : input.projects
        let visibleProjects = effectiveProjects
            .filter { !input.hiddenProjectIDs.contains($0.workspacePath) }
            .map { project -> CodexProjectSummary in
                var project = project
                if let alias = input.projectAliases[project.workspacePath] {
                    project.customDisplayName = alias
                }
                return project
            }
        let orderedProjects = orderedProjects(visibleProjects, order: input.projectOrder)
        let sectionIDs = Set(input.sections.map(\.id))
        let sectionChats = activeChats.filter { $0.sectionID.map(sectionIDs.contains) == true }
        let sectionGroups = input.sections
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                let name = $0.name.localizedCaseInsensitiveCompare($1.name)
                if name != .orderedSame { return name == .orderedAscending }
                return $0.id < $1.id
            }
            .compactMap { section -> CodexSidebarSectionGroup? in
                let rows = sectionChats
                    .filter { $0.sectionID == section.id }
                    .sorted { compareThreads($0, $1, sortKey: input.sortKey) }
                    .map { row($0, false) }
                return CodexSidebarSectionGroup(
                    section: section,
                    rows: rows,
                    isExpanded: !input.collapsedSectionIDs.contains(section.id)
                        && (input.expandedSectionIDs.isEmpty || input.expandedSectionIDs.contains(section.id)),
                    isSelected: rows.contains { $0.isSelected }
                )
            }
        let sectionChatIDs = Set(sectionChats.map(\.id))

        let projectChats = activeChats.filter {
            !projectlessIDs.contains($0.id) && !sectionChatIDs.contains($0.id)
        }
        var chatsByWorkspacePath: [String: [CodexThreadSummary]] = [:]
        for chat in projectChats {
            let path = CodexProjectSummary.normalizedPath(chat.workspacePath ?? normalizedCurrent)
            chatsByWorkspacePath[path, default: []].append(chat)
        }
        let pinnedProjectIDs = Set(input.pinnedProjectIDs)
        let projectGroups = orderedProjects.map { project in
            var seenPaths: Set<String> = []
            var chatsForProject: [CodexThreadSummary] = []
            for sourceFolder in project.sourceFolders {
                let path = CodexProjectSummary.normalizedPath(sourceFolder)
                guard seenPaths.insert(path).inserted else { continue }
                chatsForProject.append(contentsOf: chatsByWorkspacePath[path] ?? [])
            }
            let sortedChats = chatsForProject.sorted { compareThreads($0, $1, sortKey: input.sortKey) }
            let visible = Array(sortedChats.prefix(input.projectChatPreviewLimit))
            return CodexSidebarProjectGroup(
                project: project,
                rows: visible.map { row($0, false) },
                hiddenRowCount: sortedChats.count - visible.count,
                isExpanded: input.expandedProjectIDs.contains(project.workspacePath),
                isSelected: project.workspacePath == input.selectedProjectPath,
                isPinned: pinnedProjectIDs.contains(project.workspacePath)
            )
        }
        let pinnedProjectOrder = Dictionary(uniqueKeysWithValues: input.pinnedProjectIDs.enumerated().map { ($0.element, $0.offset) })
        let pinnedGroups = projectGroups
            .filter(\.isPinned)
            .sorted {
                let left = pinnedProjectOrder[$0.project.workspacePath] ?? Int.max
                let right = pinnedProjectOrder[$1.project.workspacePath] ?? Int.max
                if left != right { return left < right }
                return $0.project.workspacePath < $1.project.workspacePath
            }
        let unpinnedGroups = projectGroups.filter { !$0.isPinned }
        let recentCutoff = input.now - input.recentProjectInterval
        let recentGroups = unpinnedGroups.filter { ($0.project.updatedAt ?? 0) >= recentCutoff }
        let olderGroups = unpinnedGroups.filter { ($0.project.updatedAt ?? 0) < recentCutoff }

        let projectlessRows = activeChats
            .filter { projectlessIDs.contains($0.id) && !pinnedIDs.contains($0.id) && !sectionChatIDs.contains($0.id) }
            .sorted { compareThreads($0, $1, sortKey: input.sortKey) }
            .map { row($0, false) }
        let archivedRows = input.archivedChats
            .filter { !$0.isEphemeral }
            .sorted { compareThreads($0, $1, sortKey: input.sortKey) }
            .map { row($0, true) }

        return CodexSidebarSnapshot(
            selectedRoute: input.selectedRoute,
            lastContentRoute: input.lastContentRoute,
            isCollapsed: input.isCollapsed,
            isSearchOverlayPresented: input.isSearchOverlayPresented,
            selectedProjectPath: input.selectedProjectPath,
            selectedThreadID: effectiveThreadID,
            pinnedRows: pinnedRows,
            projectlessRows: projectlessRows,
            pinnedProjects: pinnedGroups,
            projects: recentGroups,
            olderProjects: olderGroups,
            sections: sectionGroups,
            archivedRows: archivedRows,
            archivedNextCursor: input.archivedNextCursor,
            activeLoadState: input.activeLoadState,
            archivedLoadState: input.archivedLoadState,
            actionErrorMessage: input.actionErrorMessage,
            showsNoChats: input.chats.isEmpty && input.activeLoadState != .loading,
            noChatsTitle: input.activeLoadState.errorMessage ?? "No chats",
            isProjectlessSelected: input.isProjectlessSelected,
            selectedThreadIDs: selectedThreadIDs,
            isBulkSelectionMode: input.isBulkSelectionMode && !selectedThreadIDs.isEmpty
        )
    }

    private static func orderedProjects(
        _ projects: [CodexProjectSummary],
        order: [String]
    ) -> [CodexProjectSummary] {
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return projects.sorted {
            let left = index[$0.workspacePath]
            let right = index[$1.workspacePath]
            switch (left, right) {
            case let (left?, right?):
                if left != right { return left < right }
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
            if let leftPosition = $0.serverPosition,
               let rightPosition = $1.serverPosition,
               leftPosition != rightPosition {
                return leftPosition < rightPosition
            }
            if $0.serverPosition != nil { return true }
            if $1.serverPosition != nil { return false }
            let names = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if names != .orderedSame { return names == .orderedAscending }
            return $0.workspacePath < $1.workspacePath
        }
    }

    private static func compareThreads(
        _ lhs: CodexThreadSummary,
        _ rhs: CodexThreadSummary,
        sortKey: CodexSidebarSortKey = .recency
    ) -> Bool {
        let left: TimeInterval
        let right: TimeInterval
        switch sortKey {
        case .recency:
            left = lhs.recencyAt ?? lhs.updatedAt ?? lhs.createdAt ?? 0
            right = rhs.recencyAt ?? rhs.updatedAt ?? rhs.createdAt ?? 0
        case .createdAt:
            left = lhs.createdAt ?? lhs.recencyAt ?? lhs.updatedAt ?? 0
            right = rhs.createdAt ?? rhs.recencyAt ?? rhs.updatedAt ?? 0
        case .updatedAt:
            left = lhs.updatedAt ?? lhs.recencyAt ?? lhs.createdAt ?? 0
            right = rhs.updatedAt ?? rhs.recencyAt ?? rhs.createdAt ?? 0
        case .title:
            left = 0
            right = 0
        }
        if sortKey == .title {
            let title = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if title != .orderedSame { return title == .orderedAscending }
        }
        if left != right { return left > right }
        let title = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if title != .orderedSame { return title == .orderedAscending }
        return lhs.id < rhs.id
    }
}

/// Small pure helpers used by presentation mutations. Keeping these operations
/// here makes local preference updates transactional and easy to test without a
/// live app-server connection.
public enum CodexSidebarMutation {
    public static func shouldRollback(
        operationGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        operationGeneration == currentGeneration
    }

    public static func reordered(
        sourceID: String,
        targetID: String,
        placement: CodexProjectDropPlacement,
        in current: [String]
    ) -> [String]? {
        guard sourceID != targetID, current.contains(sourceID), current.contains(targetID) else { return nil }
        var result = current
        result.removeAll { $0 == sourceID }
        guard let targetIndex = result.firstIndex(of: targetID) else { return nil }
        result.insert(sourceID, at: placement == .after ? targetIndex + 1 : targetIndex)
        return result
    }

    public static func toggledPin(id: String, in current: [String]) -> (ids: [String], isPinned: Bool) {
        var ids = current.filter { $0 != id }
        if current.contains(id) { return (ids, false) }
        ids.insert(id, at: 0)
        return (ids, true)
    }
}
