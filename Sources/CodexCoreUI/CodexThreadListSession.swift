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

/// The independently paginated sections used by the sidebar/history store.
public enum CodexThreadListPageKind: Sendable, Equatable {
    case recent
    case all
    case archived
}

/// Main-actor-owned presentation state for the server's thread catalogue.
///
/// The app-server returns opaque cursors, so this type intentionally owns both
/// the rows and their cursors. Pages are merged by thread id rather than
/// replacing the whole catalogue; this keeps a newly received canonical
/// notification from being lost when an older page finishes loading.
public struct CodexThreadListSession: Sendable {
    public private(set) var recentChats: [CodexThreadSummary]
    public private(set) var allChats: [CodexThreadSummary]
    public private(set) var archivedChats: [CodexThreadSummary]
    public private(set) var recentProjects: [CodexProjectSummary]
    public private(set) var searchResults: [CodexThreadSearchResult]
    public private(set) var allChatsNextCursor: String?
    public private(set) var archivedChatsNextCursor: String?
    public private(set) var searchNextCursor: String?
    public private(set) var isLoadingAllChats: Bool
    public private(set) var isLoadingArchivedChats: Bool
    public private(set) var isLoadingSearchResults: Bool
    public private(set) var isSearching: Bool
    public private(set) var searchErrorMessage: String?

    private var searchQuery: String?
    private var searchGeneration: UInt64
    private var seenAllCursors: Set<String>
    private var seenArchivedCursors: Set<String>
    private var seenSearchCursors: Set<String>
    private var canonicalThreadIDs: Set<String>

    public var hasMoreAllChats: Bool { allChatsNextCursor != nil }
    public var hasMoreArchivedChats: Bool { archivedChatsNextCursor != nil }
    public var hasMoreSearchResults: Bool { searchNextCursor != nil }

    public init(currentWorkspacePath: String) {
        self.recentChats = []
        self.allChats = []
        self.archivedChats = []
        self.recentProjects = CodexProjectSummary.projects(from: [], currentWorkspacePath: currentWorkspacePath)
        self.searchResults = []
        self.allChatsNextCursor = nil
        self.archivedChatsNextCursor = nil
        self.searchNextCursor = nil
        self.isLoadingAllChats = false
        self.isLoadingArchivedChats = false
        self.isLoadingSearchResults = false
        self.isSearching = false
        self.searchErrorMessage = nil
        self.searchQuery = nil
        self.searchGeneration = 0
        self.seenAllCursors = []
        self.seenArchivedCursors = []
        self.seenSearchCursors = []
        self.canonicalThreadIDs = []
    }

    public mutating func reset(currentWorkspacePath: String) {
        recentChats = []
        allChats = []
        archivedChats = []
        canonicalThreadIDs = []
        seenAllCursors = []
        seenArchivedCursors = []
        seenSearchCursors = []
        allChatsNextCursor = nil
        archivedChatsNextCursor = nil
        isLoadingAllChats = false
        isLoadingArchivedChats = false
        recentProjects = CodexProjectSummary.projects(from: [], currentWorkspacePath: currentWorkspacePath)
        clearSearch()
    }

    public mutating func refreshProjects(currentWorkspacePath: String) {
        recentProjects = CodexProjectSummary.projects(
            from: allChats.isEmpty ? recentChats : allChats,
            currentWorkspacePath: currentWorkspacePath
        )
    }

    /// Compatibility entry point for callers that already fetched the two
    /// active list pages. It also establishes a clean pagination session.
    public mutating func applyThreadList(
        currentRaw: CodexJSONValue,
        allRaw: CodexJSONValue,
        archivedRaw: CodexJSONValue? = nil,
        currentWorkspacePath: String
    ) {
        if let archivedRaw {
            applyThreadListPages(
                currentRaw: currentRaw,
                allRaw: allRaw,
                archivedRaw: archivedRaw,
                currentWorkspacePath: currentWorkspacePath
            )
            return
        }
        recentChats = Self.activeThreadSummaries(from: currentRaw)
        allChats = Self.mergedThreadSummaries(
            recentChats + Self.activeThreadSummaries(from: allRaw)
        )
        archivedChats = []
        seenAllCursors = []
        seenArchivedCursors = []
        allChatsNextCursor = Self.nextCursor(from: allRaw)
        archivedChatsNextCursor = nil
        refreshProjects(currentWorkspacePath: currentWorkspacePath)
    }

    /// Applies the initial active and archived pages in one state transition.
    /// `archivedRaw` may be nil when an older app-server does not expose the
    /// archived list; active sidebar state remains usable in that case.
    public mutating func applyThreadListPages(
        currentRaw: CodexJSONValue,
        allRaw: CodexJSONValue,
        archivedRaw: CodexJSONValue?,
        currentWorkspacePath: String
    ) {
        recentChats = Self.activeThreadSummaries(from: currentRaw)
        allChats = Self.mergedThreadSummaries(
            recentChats + Self.activeThreadSummaries(from: allRaw)
        )
        seenAllCursors = []
        seenArchivedCursors = []
        // The archived=true request scopes the page even when older servers
        // omit the per-row archived flag from their response.
        archivedChats = archivedRaw.map {
            Self.visibleThreadSummaries(from: $0).map { $0.withArchived(true) }
        } ?? []
        allChatsNextCursor = Self.nextCursor(from: allRaw)
        archivedChatsNextCursor = archivedRaw.flatMap(Self.nextCursor(from:))
        refreshProjects(currentWorkspacePath: currentWorkspacePath)
    }

    /// Applies one subsequent page. A page is idempotent, which matters when
    /// a server repeats a cursor during reconnect or cache revalidation.
    public mutating func applyThreadListPage(
        _ raw: CodexJSONValue,
        kind: CodexThreadListPageKind,
        currentWorkspacePath: String,
        replacingPage: Bool = false
    ) {
        let incoming: [CodexThreadSummary]
        switch kind {
        case .recent:
            incoming = Self.activeThreadSummaries(from: raw)
            recentChats = replacingPage ? incoming : Self.mergedThreadSummaries(recentChats + incoming)
        case .all:
            incoming = Self.activeThreadSummaries(from: raw)
            allChats = replacingPage ? incoming : Self.mergedThreadSummaries(allChats + incoming)
            // A current-workspace request is intentionally independent from
            // the all-chat cursor, but a full page can still contain rows that
            // belong in the recent section when it is the first page.
            if replacingPage {
                allChats = Self.mergedThreadSummaries(recentChats + allChats)
            }
            allChatsNextCursor = Self.nextCursor(from: raw)
        case .archived:
            incoming = Self.archivedThreadSummaries(from: raw)
            archivedChats = replacingPage ? incoming : Self.mergedThreadSummaries(archivedChats + incoming)
            archivedChatsNextCursor = Self.nextCursor(from: raw)
        }
        refreshProjects(currentWorkspacePath: currentWorkspacePath)
    }

    public mutating func applyThreadListFailure(currentWorkspacePath: String) {
        refreshProjects(currentWorkspacePath: currentWorkspacePath)
    }

    /// Reconciles list rows with the canonical notification-driven index.
    /// Existing list metadata wins where the canonical snapshot is partial;
    /// status, archive placement, and newer names/previews are updated in
    /// place. This makes thread/archived, /deleted, /unarchived, /started and
    /// status changes visible without a broad list refresh.
    public mutating func applyCanonicalThreadIndex(
        _ snapshot: CanonicalThreadIndexSnapshot,
        currentWorkspacePath: String
    ) {
        let currentCanonicalIDs = Set(snapshot.threads.map { $0.id.rawValue })
        for removedID in canonicalThreadIDs.subtracting(currentCanonicalIDs) {
            recentChats.removeAll { $0.id == removedID }
            allChats.removeAll { $0.id == removedID }
            archivedChats.removeAll { $0.id == removedID }
            searchResults.removeAll { $0.id == removedID }
        }
        canonicalThreadIDs = currentCanonicalIDs

        for canonical in snapshot.threads {
            let existing = findThread(id: canonical.id.rawValue)
            let candidate = Self.summary(from: canonical, existing: existing)
            guard !candidate.isEphemeral, candidate.parentThreadID == nil else { continue }

            switch canonical.isArchived {
            case true:
                removeFromActive(id: candidate.id)
                archivedChats = Self.upserting(archivedChats, candidate.withArchived(true))
            case false:
                archivedChats.removeAll { $0.id == candidate.id }
                allChats = Self.upserting(allChats, candidate.withArchived(false))
                if candidate.workspacePath.map(CodexProjectSummary.normalizedPath)
                    == CodexProjectSummary.normalizedPath(currentWorkspacePath) {
                    recentChats = Self.upserting(recentChats, candidate.withArchived(false))
                }
            case nil:
                updateInPlace(candidate)
            }
        }
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
        archivedChats.renameThread(id: threadID, title: trimmed)
        searchResults.renameThread(id: threadID, title: trimmed)
        refreshProjects(currentWorkspacePath: currentWorkspacePath)
    }

    public mutating func removeArchivedThread(id threadID: String) {
        archivedChats.removeAll { $0.id == threadID }
    }

    /// Moves a row to archived history after a successful archive request or
    /// notification. Unlike deletion, the row remains recoverable.
    public mutating func markThreadArchived(
        id threadID: String,
        currentWorkspacePath: String
    ) {
        guard let summary = findThread(id: threadID) else { return }
        removeFromActive(id: threadID)
        archivedChats = Self.upserting(archivedChats, summary.withArchived(true))
        refreshProjects(currentWorkspacePath: currentWorkspacePath)
    }

    public mutating func markThreadUnarchived(
        id threadID: String,
        currentWorkspacePath: String
    ) {
        guard let summary = archivedChats.first(where: { $0.id == threadID }) else { return }
        archivedChats.removeAll { $0.id == threadID }
        allChats = Self.upserting(allChats, summary.withArchived(false))
        if summary.workspacePath.map(CodexProjectSummary.normalizedPath)
            == CodexProjectSummary.normalizedPath(currentWorkspacePath) {
            recentChats = Self.upserting(recentChats, summary.withArchived(false))
        }
        refreshProjects(currentWorkspacePath: currentWorkspacePath)
    }

    public mutating func removeThread(
        id threadID: String,
        currentWorkspacePath: String
    ) {
        recentChats.removeAll { $0.id == threadID }
        allChats.removeAll { $0.id == threadID }
        archivedChats.removeAll { $0.id == threadID }
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
            async let currentResponse = codex.perform(CodexRequest.threadList(.init(
                archived: false,
                cwd: CodexAppServerSchemaValue(.string(currentWorkspacePath)),
                limit: 50,
                sortDirection: .desc,
                sortKey: .recencyAt
            )))
            async let allResponse = codex.perform(CodexRequest.threadList(.init(
                archived: false,
                limit: 500,
                sortDirection: .desc,
                sortKey: .recencyAt
            )))
            let currentRaw = try CodexJSONValue(encoding: await currentResponse)
            let allRaw = try CodexJSONValue(encoding: await allResponse)
            // Archived history is a separate optional surface. Do not throw
            // away a healthy active sidebar when an older server rejects it.
            let archivedRaw: CodexJSONValue?
            do {
                let response = try await codex.perform(CodexRequest.threadList(.init(
                    archived: true,
                    limit: 200,
                    sortDirection: .desc,
                    sortKey: .updatedAt
                )))
                archivedRaw = try CodexJSONValue(encoding: response)
            } catch {
                archivedRaw = nil
            }
            applyThreadListPages(
                currentRaw: currentRaw,
                allRaw: allRaw,
                archivedRaw: archivedRaw,
                currentWorkspacePath: currentWorkspacePath
            )
            return nil
        } catch {
            applyThreadListFailure(currentWorkspacePath: currentWorkspacePath)
            return CodexThreadListActivity(title: "Chat list unavailable", detail: errorMessage(error))
        }
    }

    @discardableResult
    public mutating func loadMoreAllChats(
        using codex: Codex,
        currentWorkspacePath: String,
        errorMessage: (Error) -> String
    ) async -> CodexThreadListActivity? {
        guard let cursor = allChatsNextCursor, !isLoadingAllChats else { return nil }
        guard seenAllCursors.insert(cursor).inserted else {
            allChatsNextCursor = nil
            return CodexThreadListActivity(title: "Chat list pagination stopped", detail: "The server repeated a chat cursor.")
        }
        isLoadingAllChats = true
        do {
            let response = try await codex.perform(CodexRequest.threadList(.init(
                archived: false,
                cursor: cursor,
                limit: 500,
                sortDirection: .desc,
                sortKey: .recencyAt
            )))
            let raw = try CodexJSONValue(encoding: response)
            applyThreadListPage(raw, kind: .all, currentWorkspacePath: currentWorkspacePath)
            isLoadingAllChats = false
            return nil
        } catch {
            seenAllCursors.remove(cursor)
            isLoadingAllChats = false
            return CodexThreadListActivity(title: "More chats unavailable", detail: errorMessage(error))
        }
    }

    @discardableResult
    public mutating func loadMoreArchivedChats(
        using codex: Codex,
        currentWorkspacePath: String,
        errorMessage: (Error) -> String
    ) async -> CodexThreadListActivity? {
        guard let cursor = archivedChatsNextCursor, !isLoadingArchivedChats else { return nil }
        guard seenArchivedCursors.insert(cursor).inserted else {
            archivedChatsNextCursor = nil
            return CodexThreadListActivity(title: "Archived list pagination stopped", detail: "The server repeated an archived cursor.")
        }
        isLoadingArchivedChats = true
        do {
            let response = try await codex.perform(CodexRequest.threadList(.init(
                archived: true,
                cursor: cursor,
                limit: 200,
                sortDirection: .desc,
                sortKey: .updatedAt
            )))
            let raw = try CodexJSONValue(encoding: response)
            applyThreadListPage(raw, kind: .archived, currentWorkspacePath: currentWorkspacePath)
            isLoadingArchivedChats = false
            return nil
        } catch {
            seenArchivedCursors.remove(cursor)
            isLoadingArchivedChats = false
            return CodexThreadListActivity(title: "Archived chats unavailable", detail: errorMessage(error))
        }
    }

    public mutating func beginSearch() {
        beginSearch(query: nil)
    }

    private mutating func beginSearch(query: String?) {
        searchGeneration &+= 1
        isSearching = true
        searchErrorMessage = nil
        searchQuery = query
        searchResults = []
        searchNextCursor = nil
        seenSearchCursors = []
    }

    @discardableResult
    public mutating func applySearchResults(from raw: CodexJSONValue) -> Int {
        let incoming = CodexThreadSearchResult.results(from: raw)
        searchResults = Self.mergedSearchResults(searchResults + incoming)
        searchNextCursor = Self.nextCursor(from: raw)
        isSearching = false
        isLoadingSearchResults = false
        return searchResults.count
    }

    public mutating func failSearch(message: String) {
        searchResults = []
        searchNextCursor = nil
        searchErrorMessage = message
        isSearching = false
        isLoadingSearchResults = false
    }

    public mutating func clearSearch() {
        searchGeneration &+= 1
        searchResults = []
        searchNextCursor = nil
        searchErrorMessage = nil
        isSearching = false
        isLoadingSearchResults = false
        searchQuery = nil
        seenSearchCursors = []
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

        beginSearch(query: searchTerm)
        let generation = searchGeneration
        do {
            let response = try await codex.perform(CodexRequest.threadSearch(.init(
                archived: false,
                limit: 50,
                searchTerm: searchTerm,
                sortDirection: .desc,
                sortKey: .recencyAt
            )))
            guard generation == searchGeneration, searchQuery == searchTerm else { return nil }
            let raw = try CodexJSONValue(encoding: response)
            let count = applySearchResults(from: raw)
            return CodexThreadListActivity(title: "Searched chats", detail: "\(count) matches for \(searchTerm)")
        } catch {
            guard generation == searchGeneration, searchQuery == searchTerm else { return nil }
            let message = errorMessage(error)
            failSearch(message: message)
            return CodexThreadListActivity(title: "Search failed", detail: message)
        }
    }

    @discardableResult
    public mutating func loadMoreSearchResults(
        using codex: Codex,
        errorMessage: (Error) -> String
    ) async -> CodexThreadListActivity? {
        guard let cursor = searchNextCursor,
              let searchQuery,
              !isLoadingSearchResults else { return nil }
        let generation = searchGeneration
        guard seenSearchCursors.insert(cursor).inserted else {
            searchNextCursor = nil
            return CodexThreadListActivity(title: "Search pagination stopped", detail: "The server repeated a search cursor.")
        }
        isLoadingSearchResults = true
        do {
            let response = try await codex.perform(CodexRequest.threadSearch(.init(
                archived: false,
                cursor: cursor,
                limit: 50,
                searchTerm: searchQuery,
                sortDirection: .desc,
                sortKey: .recencyAt
            )))
            guard generation == searchGeneration, self.searchQuery == searchQuery else {
                return nil
            }
            let raw = try CodexJSONValue(encoding: response)
            _ = applySearchResults(from: raw)
            return nil
        } catch {
            guard generation == searchGeneration, self.searchQuery == searchQuery else {
                return nil
            }
            seenSearchCursors.remove(cursor)
            isLoadingSearchResults = false
            return CodexThreadListActivity(title: "More search results unavailable", detail: errorMessage(error))
        }
    }

    public static func visibleThreadSummaries(from raw: CodexJSONValue) -> [CodexThreadSummary] {
        CodexThreadSummary.summaries(from: raw)
            .filter { $0.parentThreadID == nil && !$0.isEphemeral }
    }

    public static func activeThreadSummaries(from raw: CodexJSONValue) -> [CodexThreadSummary] {
        visibleThreadSummaries(from: raw).filter { !$0.isArchived }
    }

    public static func archivedThreadSummaries(from raw: CodexJSONValue) -> [CodexThreadSummary] {
        visibleThreadSummaries(from: raw).filter(\.isArchived)
    }

    public static func mergedThreadSummaries(_ summaries: [CodexThreadSummary]) -> [CodexThreadSummary] {
        upserting([], summaries)
    }

    private static func upserting(
        _ existing: [CodexThreadSummary],
        _ incoming: CodexThreadSummary
    ) -> [CodexThreadSummary] {
        upserting(existing, [incoming])
    }

    private static func upserting(
        _ existing: [CodexThreadSummary],
        _ incoming: [CodexThreadSummary]
    ) -> [CodexThreadSummary] {
        var result = existing
        for summary in incoming {
            guard summary.parentThreadID == nil, !summary.isEphemeral else { continue }
            if let index = result.firstIndex(where: { $0.id == summary.id }) {
                result[index] = merge(result[index], summary)
            } else {
                result.append(summary)
            }
        }
        return result
    }

    private static func merge(_ current: CodexThreadSummary, _ incoming: CodexThreadSummary) -> CodexThreadSummary {
        var result = incoming
        if incoming.title == "Untitled chat" || incoming.title.nilIfBlank == nil { result.title = current.title }
        if incoming.preview.isEmpty { result.preview = current.preview }
        result.workspacePath = incoming.workspacePath ?? current.workspacePath
        result.status = incoming.status ?? current.status
        result.modelProvider = incoming.modelProvider ?? current.modelProvider
        result.threadSource = incoming.threadSource ?? current.threadSource
        result.parentThreadID = incoming.parentThreadID ?? current.parentThreadID
        result.createdAt = incoming.createdAt ?? current.createdAt
        result.updatedAt = incoming.updatedAt ?? current.updatedAt
        result.recencyAt = incoming.recencyAt ?? current.recencyAt
        return result
    }

    private static func mergedSearchResults(_ results: [CodexThreadSearchResult]) -> [CodexThreadSearchResult] {
        var seen: Set<String> = []
        return results.filter { seen.insert($0.id).inserted }
    }

    private static func nextCursor(from raw: CodexJSONValue) -> String? {
        guard case .dictionary(let object) = raw else { return nil }
        guard let value = object["nextCursor"] else { return nil }
        if case .string(let cursor) = value, !cursor.isEmpty { return cursor }
        return nil
    }

    private static func summary(
        from canonical: CanonicalThreadIndexSummary,
        existing: CodexThreadSummary?
    ) -> CodexThreadSummary {
        let cwd: String?
        if case .string(let value) = canonical.cwd { cwd = value } else { cwd = nil }
        let title = canonical.name?.nilIfBlank ?? existing?.title ?? canonical.preview?.nilIfBlank ?? "Untitled chat"
        var result = CodexThreadSummary(
            id: canonical.id.rawValue,
            title: title,
            preview: canonical.preview ?? existing?.preview ?? "",
            workspacePath: cwd ?? existing?.workspacePath,
            status: statusString(canonical.status),
            modelProvider: existing?.modelProvider,
            threadSource: existing?.threadSource,
            parentThreadID: canonical.parentThreadID?.rawValue ?? existing?.parentThreadID,
            isArchived: canonical.isArchived ?? existing?.isArchived ?? false,
            isEphemeral: existing?.isEphemeral ?? false,
            createdAt: existing?.createdAt,
            updatedAt: canonical.updatedAt.map { TimeInterval($0.rawValue) },
            recencyAt: existing?.recencyAt
        )
        if result.preview.isEmpty { result.preview = existing?.preview ?? "" }
        return result
    }

    private static func statusString(_ status: CanonicalThreadStatus) -> String {
        switch status {
        case .notLoaded: return "notLoaded"
        case .idle: return "idle"
        case .active: return "active"
        case .systemError: return "error"
        case .unknown(let type, _): return type ?? "unknown"
        }
    }

    private func findThread(id: String) -> CodexThreadSummary? {
        recentChats.first(where: { $0.id == id })
            ?? allChats.first(where: { $0.id == id })
            ?? archivedChats.first(where: { $0.id == id })
    }

    private mutating func removeFromActive(id: String) {
        recentChats.removeAll { $0.id == id }
        allChats.removeAll { $0.id == id }
    }

    private mutating func updateInPlace(_ candidate: CodexThreadSummary) {
        recentChats = Self.upserting(recentChats, candidate)
        allChats = Self.upserting(allChats, candidate)
        archivedChats = Self.upserting(archivedChats, candidate)
    }
}

private extension CodexThreadSummary {
    func withArchived(_ value: Bool) -> Self {
        var copy = self
        copy.isArchived = value
        return copy
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
