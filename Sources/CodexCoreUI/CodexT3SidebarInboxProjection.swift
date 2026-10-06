import Foundation

/// Optional server search facts for the inline T3 sidebar. The host owns the
/// request and its generation; results are rendered only for their exact query.
public struct CodexSidebarInboxSearchState: Equatable, Sendable {
    public var query: String
    public var results: [CodexThreadSearchResult]
    public var isSearching: Bool
    public var errorMessage: String?
    public var hasMoreResults: Bool

    public init(query: String = "", results: [CodexThreadSearchResult] = [], isSearching: Bool = false,
                errorMessage: String? = nil, hasMoreResults: Bool = false) {
        self.query = query
        self.results = results
        self.isSearching = isSearching
        self.errorMessage = errorMessage
        self.hasMoreResults = hasMoreResults
    }
}

struct CodexT3SidebarInboxItem: Identifiable, Equatable {
    var row: CodexSidebarThreadRow
    var project: CodexProjectSummary?
    var id: String { row.id }
}

/// Current T3's inbox order deliberately ignores activity timestamps. A live
/// status change must not move a row away from the user's pointer.
struct CodexT3SidebarInboxProjection {
    let projects: [CodexProjectSummary]
    let pinned: [CodexT3SidebarInboxItem]
    let active: [CodexT3SidebarInboxItem]
    let archived: [CodexT3SidebarInboxItem]
    private let knownItemByID: [String: CodexT3SidebarInboxItem]
    private let projectByID: [String: CodexProjectSummary]
    private let projectsByPath: [String: [CodexProjectSummary]]

    init(snapshot: CodexSidebarSnapshot, projectScopeID: String? = nil) {
        let groups = snapshot.pinnedProjects + snapshot.projects + snapshot.olderProjects
        projects = Self.uniqueProjects(snapshot.inboxProjects.isEmpty ? groups.map(\.project) : snapshot.inboxProjects)
        let fallback = snapshot.pinnedRows + snapshot.projectlessRows + snapshot.sections.flatMap(\.rows) + groups.flatMap(\.rows)
        let rows = Self.uniqueRows(snapshot.inboxRows.isEmpty ? fallback : snapshot.inboxRows)
        let pinnedOrder = Dictionary(snapshot.pinnedRows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let projectByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var projectByPath: [String: [CodexProjectSummary]] = [:]
        for project in projects {
            for path in Set(project.sourceFolders.map(CodexProjectSummary.normalizedPath)) {
                projectByPath[path, default: []].append(project)
            }
        }
        self.projectByID = projectByID
        self.projectsByPath = projectByPath
        let resolvedProjectsByPath = projectByPath
        let item: (CodexSidebarThreadRow) -> CodexT3SidebarInboxItem = { row in
            let project: CodexProjectSummary?
            if row.isProjectless { project = nil }
            else if let id = row.summary.projectID { project = projectByID[id] }
            else if let path = row.summary.workspacePath {
                let matches = resolvedProjectsByPath[CodexProjectSummary.normalizedPath(path)] ?? []
                // A shared folder cannot disambiguate two opaque server IDs.
                project = matches.count == 1 ? matches.first : nil
            } else { project = nil }
            return .init(row: row, project: project)
        }
        let scoped: (CodexT3SidebarInboxItem) -> Bool = { value in
            projectScopeID == nil || value.project?.id == projectScopeID
        }
        pinned = rows.filter { $0.isPinned || pinnedOrder[$0.id] != nil }
            .sorted {
                let lhs = pinnedOrder[$0.id] ?? Int.max, rhs = pinnedOrder[$1.id] ?? Int.max
                return lhs == rhs ? Self.creationOrder($0, $1) : lhs < rhs
            }.map(item).filter(scoped)
        active = rows.filter { !$0.isPinned && pinnedOrder[$0.id] == nil }
            .sorted(by: Self.creationOrder).map(item).filter(scoped)
        let archivedRows = Self.uniqueRows(snapshot.archivedRows)
        knownItemByID = Dictionary((rows + archivedRows).map(item).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        archived = archivedRows.sorted {
            let lhs = $0.summary.recencyAt ?? $0.summary.updatedAt ?? $0.summary.createdAt ?? 0
            let rhs = $1.summary.recencyAt ?? $1.summary.updatedAt ?? $1.summary.createdAt ?? 0
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }.map(item).filter(scoped)
    }

    var allActive: [CodexT3SidebarInboxItem] { pinned + active }

    func localSearch(_ query: String) -> [CodexThreadSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var seen: Set<String> = []
        return (allActive + archived).filter { item in
            guard seen.insert(item.id).inserted else { return false }
            return [item.row.summary.title, item.row.summary.preview, item.project?.displayName ?? "", item.row.summary.sectionName ?? ""]
                .contains { $0.localizedStandardContains(query) }
        }.map { .init(thread: $0.row.summary, snippet: $0.row.summary.preview) }
    }

    func project(for summary: CodexThreadSummary) -> CodexProjectSummary? {
        if let value = knownItemByID[summary.id] { return value.project }
        if let id = summary.projectID { return projectByID[id] }
        guard let path = summary.workspacePath else { return nil }
        let matches = projectsByPath[CodexProjectSummary.normalizedPath(path)] ?? []
        return matches.count == 1 ? matches.first : nil
    }

    func searchResults(_ state: CodexSidebarInboxSearchState?, query: String, projectScopeID: String?) -> [CodexThreadSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let state, state.query == query, !state.isSearching, state.errorMessage == nil else { return localSearch(query) }
        var seen: Set<String> = []
        return state.results.filter {
            !$0.thread.isEphemeral && $0.thread.parentThreadID?.nilIfBlank == nil && seen.insert($0.id).inserted
                && (projectScopeID == nil || project(for: $0.thread)?.id == projectScopeID)
        }
    }

    static func archivedPage(_ items: [CodexT3SidebarInboxItem], visibleCount: Int, selectedID: String?, expanded: Bool) -> [CodexT3SidebarInboxItem] {
        var visible = expanded ? Array(items.prefix(max(0, visibleCount))) : []
        if let selected = items.first(where: { $0.id == selectedID }), !visible.contains(where: { $0.id == selected.id }) {
            visible.append(selected)
        }
        return visible
    }

    private static func creationOrder(_ lhs: CodexSidebarThreadRow, _ rhs: CodexSidebarThreadRow) -> Bool {
        let left = lhs.summary.createdAt ?? 0, right = rhs.summary.createdAt ?? 0
        return left == right ? lhs.id < rhs.id : left > right
    }

    private static func uniqueRows(_ rows: [CodexSidebarThreadRow]) -> [CodexSidebarThreadRow] {
        var seen: Set<String> = []
        return rows.filter { !$0.summary.isEphemeral && $0.summary.parentThreadID?.nilIfBlank == nil && seen.insert($0.id).inserted }
    }

    private static func uniqueProjects(_ projects: [CodexProjectSummary]) -> [CodexProjectSummary] {
        var seen: Set<String> = []
        return projects.filter { seen.insert($0.id).inserted }
    }
}

/// One retained projection, shared by the header/list/search reads in a render.
/// The cache is not observable: hover/focus changes stay inside each row.
@MainActor
final class CodexT3SidebarInboxProjectionCache {
    private var snapshot: CodexSidebarSnapshot?
    private var scopeID: String?
    private var projection: CodexT3SidebarInboxProjection?

    func value(snapshot: CodexSidebarSnapshot, scopeID: String?) -> CodexT3SidebarInboxProjection {
        if self.snapshot == snapshot, self.scopeID == scopeID, let projection { return projection }
        let projection = CodexT3SidebarInboxProjection(snapshot: snapshot, projectScopeID: scopeID)
        self.snapshot = snapshot
        self.scopeID = scopeID
        self.projection = projection
        return projection
    }
}

enum CodexT3SidebarSelectionIntent: Equatable {
    case navigate
    case toggle(String)
    case addRange([String])

    static func resolve(clickedID: String, visibleIDs: [String], selectedIDs: Set<String>, anchorID: String?,
                        commandPressed: Bool, shiftPressed: Bool, selectionMode: Bool) -> Self {
        if shiftPressed, let anchorID, let anchor = visibleIDs.firstIndex(of: anchorID), let clicked = visibleIDs.firstIndex(of: clickedID) {
            return .addRange(Array(visibleIDs[min(anchor, clicked)...max(anchor, clicked)]).filter { !selectedIDs.contains($0) })
        }
        return commandPressed || selectionMode ? .toggle(clickedID) : .navigate
    }
}
