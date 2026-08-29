import Foundation
import CodexCore

public struct CodexThreadListActivity: Equatable, Sendable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

public struct CodexThreadListSession: Sendable {
    public private(set) var recentChats: [CodexThreadSummary]
    public private(set) var allChats: [CodexThreadSummary]
    /// Authoritative project/list facts when the connected server supports
    /// durable projects. Empty means the compatibility fallback derives
    /// project shells from thread cwd values.
    public private(set) var serverProjects: [CodexProjectSummary]
    public private(set) var archivedChats: [CodexThreadSummary]
    public private(set) var archivedNextCursor: String?
    public private(set) var archivedSeenCursors: Set<String>
    public private(set) var isLoadingArchived = false
    public private(set) var archivedErrorMessage: String?
    public private(set) var hasLoadedArchived = false
    public private(set) var activeLoadState: CodexSidebarLoadState
    public private(set) var activeErrorMessage: String?
    public private(set) var recentProjects: [CodexProjectSummary]
    public private(set) var searchResults: [CodexThreadSearchResult]
    public private(set) var isSearching: Bool
    public private(set) var searchErrorMessage: String?

    public init(currentWorkspacePath: String) {
        self.recentChats = []
        self.allChats = []
        self.serverProjects = []
        self.archivedChats = []
        self.archivedNextCursor = nil
        self.archivedSeenCursors = []
        self.isLoadingArchived = false
        self.archivedErrorMessage = nil
        self.hasLoadedArchived = false
        self.activeLoadState = .idle
        self.activeErrorMessage = nil
        self.recentProjects = CodexSidebarProjection.presentedProjects(
            serverProjects: [],
            chats: [],
            currentWorkspacePath: currentWorkspacePath,
            projectlessThreadIDs: [],
            sourceFoldersByPrimaryPath: [:]
        )
        self.searchResults = []
        self.isSearching = false
        self.searchErrorMessage = nil
    }

    public mutating func reset(currentWorkspacePath: String) {
        recentChats = []
        allChats = []
        serverProjects = []
        archivedChats = []
        archivedNextCursor = nil
        archivedSeenCursors.removeAll()
        isLoadingArchived = false
        archivedErrorMessage = nil
        hasLoadedArchived = false
        activeLoadState = .idle
        activeErrorMessage = nil
        recentProjects = CodexSidebarProjection.presentedProjects(
            serverProjects: [],
            chats: [],
            currentWorkspacePath: currentWorkspacePath,
            projectlessThreadIDs: [],
            sourceFoldersByPrimaryPath: [:]
        )
        clearSearch()
    }

    public mutating func refreshProjects(currentWorkspacePath: String) {
        if !serverProjects.isEmpty {
            recentProjects = serverProjects
        } else {
            recentProjects = CodexSidebarProjection.presentedProjects(
                serverProjects: [],
                chats: allChats.isEmpty ? recentChats : allChats,
                currentWorkspacePath: currentWorkspacePath,
                projectlessThreadIDs: [],
                sourceFoldersByPrimaryPath: [:]
            )
        }
    }

    public mutating func clearServerProjects() {
        serverProjects.removeAll(keepingCapacity: true)
    }

    public mutating func applyProjectList(
        _ response: CodexSchemaProjectListResponse,
        reset: Bool = true
    ) {
        let projects = response.data.enumerated().map {
            CodexProjectSummary(schema: $0.element)
        }
        if reset { serverProjects.removeAll(keepingCapacity: true) }
        guard !projects.isEmpty else {
            recentProjects = []
            return
        }
        var merged = Dictionary(uniqueKeysWithValues: serverProjects.map { ($0.id, $0) })
        for project in projects { merged[project.id] = project }
        serverProjects = merged.values.sorted {
            if let left = $0.serverPosition, let right = $1.serverPosition, left != right {
                return left < right
            }
            if $0.serverPosition != nil { return true }
            if $1.serverPosition != nil { return false }
            let name = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if name != .orderedSame { return name == .orderedAscending }
            return $0.id < $1.id
        }
        recentProjects = serverProjects
    }

    public mutating func applyThreadList(
        currentRaw: CodexJSONValue,
        allRaw: CodexJSONValue,
        currentWorkspacePath: String
    ) {
        let currentChats = Self.visibleThreadSummaries(from: currentRaw)
        let allChats = Self.mergedThreadSummaries(currentChats + Self.visibleThreadSummaries(from: allRaw))
        recentChats = currentChats
        self.allChats = allChats
        activeLoadState = .loaded
        activeErrorMessage = nil
        recentProjects = CodexSidebarProjection.presentedProjects(
            serverProjects: serverProjects,
            chats: allChats,
            currentWorkspacePath: currentWorkspacePath,
            projectlessThreadIDs: [],
            sourceFoldersByPrimaryPath: [:]
        )
    }

    public mutating func applyThreadListFailure(
        currentWorkspacePath: String,
        message: String = "Chat list unavailable"
    ) {
        refreshProjects(currentWorkspacePath: currentWorkspacePath)
        activeLoadState = .failed(message)
        activeErrorMessage = message
    }

    public mutating func beginThreadListLoad() -> Bool {
        guard !activeLoadState.isLoading else { return false }
        activeLoadState = .loading
        activeErrorMessage = nil
        return true
    }

    /// Replaces the archived page while retaining previously fetched pages.
    /// The cursor is opaque; a repeated cursor is rejected so a broken server
    /// cannot make the sidebar spin forever or duplicate rows.
    @discardableResult
    public mutating func applyArchivedPage(
        _ response: CodexSchemaThreadListResponse,
        reset: Bool = false
    ) -> Bool {
        if reset {
            archivedChats.removeAll(keepingCapacity: true)
            archivedNextCursor = nil
            archivedSeenCursors.removeAll()
        }
        if !reset, let current = archivedNextCursor, response.nextCursor == current {
            isLoadingArchived = false
            archivedErrorMessage = "Archived chat pagination returned a repeated cursor."
            return false
        }
        let page = response.data
            .map(CodexThreadSummary.init(schema:))
            .filter { !$0.isEphemeral && $0.parentThreadID == nil }
        var byID = Dictionary(uniqueKeysWithValues: archivedChats.map { ($0.id, $0) })
        for summary in page { byID[summary.id] = summary }
        archivedChats = byID.values.sorted(by: Self.compareByRecency)
        archivedNextCursor = response.nextCursor
        hasLoadedArchived = true
        archivedErrorMessage = nil
        isLoadingArchived = false
        return true
    }

    public mutating func beginArchivedLoad(reset: Bool) -> Bool {
        guard !isLoadingArchived else { return false }
        if reset {
            archivedChats.removeAll(keepingCapacity: true)
            archivedNextCursor = nil
            archivedSeenCursors.removeAll()
            hasLoadedArchived = false
        }
        isLoadingArchived = true
        archivedErrorMessage = nil
        return true
    }

    public mutating func failArchivedLoad(message: String) {
        isLoadingArchived = false
        archivedErrorMessage = message
        hasLoadedArchived = true
    }

    @discardableResult
    public mutating func removeArchivedThread(id threadID: String) -> CodexThreadSummary? {
        guard let index = archivedChats.firstIndex(where: { $0.id == threadID }) else { return nil }
        return archivedChats.remove(at: index)
    }

    @discardableResult
    public mutating func refreshArchivedChats(
        using codex: Codex,
        errorMessage: (Error) -> String,
        beginLoading: Bool = true
    ) async -> CodexThreadListActivity? {
        if beginLoading {
            guard beginArchivedLoad(reset: true) else { return nil }
        }
        do {
            let response = try await codex.perform(CodexRequest.threadList(.init(
                archived: true,
                limit: 50,
                sortDirection: .desc,
                sortKey: .recencyAt
            )))
            _ = applyArchivedPage(response, reset: true)
            return nil
        } catch {
            let message = errorMessage(error)
            failArchivedLoad(message: message)
            return CodexThreadListActivity(title: "Archived chats unavailable", detail: message)
        }
    }

    @discardableResult
    public mutating func loadMoreArchivedChats(
        using codex: Codex,
        errorMessage: (Error) -> String,
        beginLoading: Bool = true
    ) async -> CodexThreadListActivity? {
        guard archivedNextCursor != nil else { return nil }
        if beginLoading {
            guard beginArchivedLoad(reset: false) else { return nil }
        }
        guard let cursor = archivedNextCursor,
              archivedSeenCursors.insert(cursor).inserted else {
            failArchivedLoad(message: "Archived chat pagination returned a repeated cursor.")
            return nil
        }
        do {
            let response = try await codex.perform(CodexRequest.threadList(.init(
                archived: true,
                cursor: cursor,
                limit: 50,
                sortDirection: .desc,
                sortKey: .recencyAt
            )))
            _ = applyArchivedPage(response)
            return nil
        } catch {
            archivedSeenCursors.remove(cursor)
            let message = errorMessage(error)
            failArchivedLoad(message: message)
            return CodexThreadListActivity(title: "Archived chats unavailable", detail: message)
        }
    }

    public mutating func renameThread(
        id threadID: String,
        title: String,
        currentWorkspacePath: String
    ) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentChats.renameThread(id: threadID, title: trimmed)
        allChats.renameThread(id: threadID, title: trimmed)
        searchResults.renameThread(id: threadID, title: trimmed)
        refreshProjects(currentWorkspacePath: currentWorkspacePath)
    }

    public mutating func removeThread(
        id threadID: String,
        currentWorkspacePath: String
    ) {
        recentChats.removeAll { $0.id == threadID }
        allChats.removeAll { $0.id == threadID }
        searchResults.removeAll { $0.id == threadID }
        refreshProjects(currentWorkspacePath: currentWorkspacePath)
    }

    @discardableResult
    public mutating func refreshRecentChats(
        using codex: Codex,
        currentWorkspacePath: String,
        errorMessage: (Error) -> String,
        beginLoading: Bool = true
    ) async -> CodexThreadListActivity? {
        if beginLoading { _ = beginThreadListLoad() }
        let currentRequest = CodexRequest.threadList(.init(
            archived: false,
            cwd: CodexAppServerSchemaValue(.string(currentWorkspacePath)),
            limit: 50,
            sortDirection: .desc,
            sortKey: .recencyAt
        ))
        let allRequest = CodexRequest.threadList(.init(
            archived: false,
            limit: 100,
            sortDirection: .desc,
            sortKey: .recencyAt
        ))

        // These lists are independent reads. Start both requests together so
        // sidebar readiness is bounded by the slower response rather than the
        // sum of the two round trips; applyThreadList remains deterministic.
        async let currentResponse = codex.perform(currentRequest)
        async let allResponse = codex.perform(allRequest)
        do {
            let (currentResponse, allResponse) = try await (currentResponse, allResponse)
            let currentRaw = try CodexJSONValue(encoding: currentResponse)
            let allRaw = try CodexJSONValue(encoding: allResponse)
            applyThreadList(currentRaw: currentRaw, allRaw: allRaw, currentWorkspacePath: currentWorkspacePath)
            // Project/list is a separate capability on newer servers. Keep it
            // best-effort so older servers retain cwd-derived project shells.
            var projectCursor: String?
            var seenProjectCursors: Set<String> = []
            var isFirstProjectPage = true
            repeat {
                guard !Task.isCancelled else { break }
                guard let projectResponse = try? await codex.perform(CodexRequest.projectList(.init(
                    cursor: projectCursor,
                    limit: 100
                ))) else { break }
                applyProjectList(projectResponse, reset: isFirstProjectPage)
                isFirstProjectPage = false
                projectCursor = projectResponse.nextCursor
                if let projectCursor, !seenProjectCursors.insert(projectCursor).inserted {
                    break
                }
            } while projectCursor != nil
            return nil
        } catch {
            let message = errorMessage(error)
            applyThreadListFailure(currentWorkspacePath: currentWorkspacePath, message: message)
            return CodexThreadListActivity(title: "Chat list unavailable", detail: message)
        }
    }

    public mutating func beginSearch() {
        isSearching = true
        searchErrorMessage = nil
    }

    @discardableResult
    public mutating func applyLocalSearch(
        query: String,
        sortKey: CodexSidebarSortKey = .recency,
        limit: Int = 25
    ) -> Int {
        let local = CodexSidebarProjection.search(
            allChats.isEmpty ? recentChats : allChats,
            query: query,
            sortKey: sortKey,
            limit: limit
        )
        searchResults = local.map {
            CodexThreadSearchResult(thread: $0, snippet: $0.detail)
        }
        return local.count
    }

    public mutating func applySearchResults(from raw: CodexJSONValue) -> Int {
        searchResults = CodexThreadSearchResult.results(from: raw)
        isSearching = false
        return searchResults.count
    }

    public mutating func failSearch(message: String) {
        searchResults = []
        searchErrorMessage = message
        isSearching = false
    }

    public mutating func clearSearch() {
        searchResults = []
        searchErrorMessage = nil
        isSearching = false
    }

    @discardableResult
    public mutating func searchChats(
        query: String,
        using codex: Codex?,
        errorMessage: (Error) -> String
    ) async -> CodexThreadListActivity? {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchTerm.isEmpty else {
            clearSearch()
            return nil
        }
        guard let codex else {
            let count = applyLocalSearch(query: searchTerm)
            if count == 0 {
                failSearch(message: "Connect to Codex before searching.")
            } else {
                isSearching = false
            }
            return nil
        }

        beginSearch()
        let localCount = applyLocalSearch(query: searchTerm)
        do {
            let response = try await codex.perform(CodexRequest.threadSearch(.init(
                archived: false,
                limit: 25,
                searchTerm: searchTerm,
                sortDirection: .desc,
                sortKey: .recencyAt
            )))
            let raw = try CodexJSONValue(encoding: response)
            let count = applySearchResults(from: raw)
            return CodexThreadListActivity(title: "Searched chats", detail: "\(count) matches for \(searchTerm)")
        } catch {
            let message = errorMessage(error)
            if localCount == 0 {
                failSearch(message: message)
            } else {
                isSearching = false
                searchErrorMessage = message
            }
            return CodexThreadListActivity(title: "Search failed", detail: message)
        }
    }

    public static func visibleThreadSummaries(from raw: CodexJSONValue) -> [CodexThreadSummary] {
        CodexThreadSummary.summaries(from: raw)
            .filter { $0.parentThreadID == nil && !$0.isEphemeral }
    }

    public static func mergedThreadSummaries(_ summaries: [CodexThreadSummary]) -> [CodexThreadSummary] {
        var seen: Set<String> = []
        var merged: [CodexThreadSummary] = []
        for summary in summaries where seen.insert(summary.id).inserted {
            merged.append(summary)
        }
        return merged
    }

    private static func compareByRecency(_ lhs: CodexThreadSummary, _ rhs: CodexThreadSummary) -> Bool {
        let left = lhs.recencyAt ?? lhs.updatedAt ?? lhs.createdAt ?? 0
        let right = rhs.recencyAt ?? rhs.updatedAt ?? rhs.createdAt ?? 0
        if left != right { return left > right }
        let title = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if title != .orderedSame { return title == .orderedAscending }
        return lhs.id < rhs.id
    }

}

private extension Array where Element == CodexThreadSummary {
    mutating func renameThread(id threadID: String, title: String) {
        self = map { summary in
            guard summary.id == threadID else { return summary }
            var updated = summary
            updated.title = title
            return updated
        }
    }
}

private extension Array where Element == CodexThreadSearchResult {
    mutating func renameThread(id threadID: String, title: String) {
        self = map { result in
            guard result.id == threadID else { return result }
            var thread = result.thread
            thread.title = title
            return CodexThreadSearchResult(thread: thread, snippet: result.snippet)
        }
    }
}
