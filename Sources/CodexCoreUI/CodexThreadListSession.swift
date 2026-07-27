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
    public private(set) var recentProjects: [CodexProjectSummary]
    public private(set) var searchResults: [CodexThreadSearchResult]
    public private(set) var isSearching: Bool
    public private(set) var searchErrorMessage: String?

    public init(currentWorkspacePath: String) {
        self.recentChats = []
        self.allChats = []
        self.recentProjects = CodexProjectSummary.projects(from: [], currentWorkspacePath: currentWorkspacePath)
        self.searchResults = []
        self.isSearching = false
        self.searchErrorMessage = nil
    }

    public mutating func reset(currentWorkspacePath: String) {
        recentChats = []
        allChats = []
        recentProjects = CodexProjectSummary.projects(from: [], currentWorkspacePath: currentWorkspacePath)
        clearSearch()
    }

    public mutating func refreshProjects(currentWorkspacePath: String) {
        recentProjects = CodexProjectSummary.projects(from: allChats.isEmpty ? recentChats : allChats, currentWorkspacePath: currentWorkspacePath)
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
        recentProjects = CodexProjectSummary.projects(from: allChats, currentWorkspacePath: currentWorkspacePath)
    }

    public mutating func applyThreadListFailure(currentWorkspacePath: String) {
        refreshProjects(currentWorkspacePath: currentWorkspacePath)
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
        errorMessage: (Error) -> String
    ) async -> CodexThreadListActivity? {
        do {
            let currentRaw = try CodexJSONValue(encoding: await codex.perform(CodexRequest.threadList(.init(
                archived: false,
                cwd: CodexAppServerSchemaValue(.string(currentWorkspacePath)),
                limit: 50,
                sortDirection: .desc,
                sortKey: .recencyAt
            ))))
            let allRaw = try CodexJSONValue(encoding: await codex.perform(CodexRequest.threadList(.init(
                archived: false,
                limit: 100,
                sortDirection: .desc,
                sortKey: .recencyAt
            ))))
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
