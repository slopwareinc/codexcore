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
    public private(set) var recentProjects: [CodexProjectSummary]
    public private(set) var searchResults: [CodexThreadSearchResult]
    public private(set) var isSearching: Bool
    public private(set) var searchErrorMessage: String?

    public init(currentWorkspacePath: String) {
        self.recentChats = []
        self.recentProjects = CodexProjectSummary.projects(from: [], currentWorkspacePath: currentWorkspacePath)
        self.searchResults = []
        self.isSearching = false
        self.searchErrorMessage = nil
    }

    public mutating func reset(currentWorkspacePath: String) {
        recentChats = []
        recentProjects = CodexProjectSummary.projects(from: [], currentWorkspacePath: currentWorkspacePath)
        clearSearch()
    }

    public mutating func refreshProjects(currentWorkspacePath: String) {
        recentProjects = CodexProjectSummary.projects(from: recentChats, currentWorkspacePath: currentWorkspacePath)
    }

    public mutating func applyThreadList(
        currentRaw: CodexJSONValue,
        allRaw: CodexJSONValue,
        currentWorkspacePath: String
    ) {
        let currentChats = Self.visibleThreadSummaries(from: currentRaw)
        let allChats = Self.mergedThreadSummaries(currentChats + Self.visibleThreadSummaries(from: allRaw))
        recentChats = currentChats
        recentProjects = CodexProjectSummary.projects(from: allChats, currentWorkspacePath: currentWorkspacePath)
    }

    public mutating func applyThreadListFailure(currentWorkspacePath: String) {
        refreshProjects(currentWorkspacePath: currentWorkspacePath)
    }

    @discardableResult
    public mutating func refreshRecentChats(
        using codex: Codex,
        currentWorkspacePath: String,
        errorMessage: (Error) -> String
    ) async -> CodexThreadListActivity? {
        do {
            let currentRaw = try await codex.threadListRaw(params: [
                "archived": .bool(false),
                "cwd": .string(currentWorkspacePath),
                "limit": .int(50),
                "sortDirection": .string(SortDirection.desc.rawValue),
                "sortKey": .string(ThreadSortKey.updatedAt.rawValue)
            ])
            let allRaw = try await codex.threadListRaw(params: [
                "archived": .bool(false),
                "limit": .int(100),
                "sortDirection": .string(SortDirection.desc.rawValue),
                "sortKey": .string(ThreadSortKey.updatedAt.rawValue)
            ])
            applyThreadList(currentRaw: currentRaw, allRaw: allRaw, currentWorkspacePath: currentWorkspacePath)
            return nil
        } catch {
            applyThreadListFailure(currentWorkspacePath: currentWorkspacePath)
            return CodexThreadListActivity(title: "Chat list unavailable", detail: errorMessage(error))
        }
    }

    public mutating func beginSearch() {
        isSearching = true
        searchErrorMessage = nil
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
            failSearch(message: "Connect to Codex before searching.")
            return nil
        }

        beginSearch()
        do {
            let raw = try await codex.threadSearchRaw(searchTerm: searchTerm, limit: 25)
            let count = applySearchResults(from: raw)
            return CodexThreadListActivity(title: "Searched chats", detail: "\(count) matches for \(searchTerm)")
        } catch {
            let message = errorMessage(error)
            failSearch(message: message)
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
}
