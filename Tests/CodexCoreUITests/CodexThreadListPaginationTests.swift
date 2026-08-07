import Foundation
import Testing
@testable import CodexCore
@testable import CodexCoreUI

struct CodexThreadListPaginationTests {
    @Test func activeAndArchivedPagesKeepIndependentCursorsAndDeduplicateRows() {
        var session = CodexThreadListSession(currentWorkspacePath: "/tmp/Core")
        session.applyThreadListPages(
            currentRaw: page([
                thread(id: "current", name: "Current", cwd: "/tmp/Core")
            ]),
            allRaw: page([
                thread(id: "current", name: "Current", cwd: "/tmp/Core"),
                thread(id: "other", name: "Other", cwd: "/tmp/Other")
            ], nextCursor: "all-2"),
            archivedRaw: page([
                thread(id: "old", name: "Old", cwd: "/tmp/Core", archived: true)
            ], nextCursor: "archived-2"),
            currentWorkspacePath: "/tmp/Core"
        )

        #expect(session.recentChats.map(\.id) == ["current"])
        #expect(session.allChats.map(\.id) == ["current", "other"])
        #expect(session.archivedChats.map(\.id) == ["old"])
        #expect(session.allChatsNextCursor == "all-2")
        #expect(session.archivedChatsNextCursor == "archived-2")

        session.applyThreadListPage(
            page([
                thread(id: "other", name: "Other (fresh)", cwd: "/tmp/Other"),
                thread(id: "third", name: "Third", cwd: "/tmp/Core")
            ], nextCursor: "all-3"),
            kind: .all,
            currentWorkspacePath: "/tmp/Core"
        )
        session.applyThreadListPage(
            page([
                thread(id: "old", name: "Old", cwd: "/tmp/Core", archived: true),
                thread(id: "older", name: "Older", cwd: "/tmp/Core", archived: true)
            ]),
            kind: .archived,
            currentWorkspacePath: "/tmp/Core"
        )

        #expect(session.allChats.map(\.id) == ["current", "other", "third"])
        #expect(session.allChats.first(where: { $0.id == "other" })?.title == "Other (fresh)")
        #expect(session.archivedChats.map(\.id) == ["old", "older"])
        #expect(session.archivedChatsNextCursor == nil)
    }

    @Test func canonicalIndexMovesRowsAndEvictsDeletedRows() {
        var session = CodexThreadListSession(currentWorkspacePath: "/tmp/Core")
        session.applyThreadListPages(
            currentRaw: page([thread(id: "live", name: "Live", cwd: "/tmp/Core")]),
            allRaw: page([
                thread(id: "live", name: "Live", cwd: "/tmp/Core"),
                thread(id: "gone", name: "Gone", cwd: "/tmp/Core")
            ]),
            archivedRaw: page([thread(id: "old", name: "Old", cwd: "/tmp/Core", archived: true)]),
            currentWorkspacePath: "/tmp/Core"
        )

        session.applyCanonicalThreadIndex(
            snapshot([
                canonical(id: "live", name: "Live", archived: false),
                canonical(id: "gone", name: "Gone", archived: false),
                canonical(id: "old", name: "Old", archived: true)
            ]),
            currentWorkspacePath: "/tmp/Core"
        )
        session.applyCanonicalThreadIndex(
            snapshot([
                canonical(id: "live", name: "Live", archived: false),
                canonical(id: "old", name: "Old", archived: true)
            ]),
            currentWorkspacePath: "/tmp/Core"
        )

        #expect(session.allChats.map(\.id) == ["live"])
        #expect(session.archivedChats.map(\.id) == ["old"])
        #expect(session.recentChats.map(\.id) == ["live"])
        #expect(session.allChats.contains(where: { $0.id == "gone" }) == false)
    }

    @Test func searchPagesUseOpaqueCursorAndDoNotDuplicateHits() {
        var session = CodexThreadListSession(currentWorkspacePath: "/tmp/Core")
        _ = session.applySearchResults(from: page([
            searchResult(id: "one", snippet: "first")
        ], nextCursor: "search-2"))
        #expect(session.searchResults.map(\.id) == ["one"])
        #expect(session.searchNextCursor == "search-2")

        _ = session.applySearchResults(from: page([
            searchResult(id: "one", snippet: "duplicate"),
            searchResult(id: "two", snippet: "second")
        ]))
        #expect(session.searchResults.map(\.id) == ["one", "two"])
        #expect(session.searchResults.first?.snippet == "first")
        #expect(session.searchNextCursor == nil)
    }

    private func page(_ rows: [CodexJSONValue], nextCursor: String? = nil) -> CodexJSONValue {
        var object: [String: CodexJSONValue] = ["data": .array(rows)]
        if let nextCursor { object["nextCursor"] = .string(nextCursor) }
        return .dictionary(object)
    }

    private func thread(
        id: String,
        name: String,
        cwd: String,
        archived: Bool = false
    ) -> CodexJSONValue {
        .dictionary([
            "id": .string(id),
            "name": .string(name),
            "cwd": .string(cwd),
            "archived": .bool(archived),
            "ephemeral": .bool(false),
            "updatedAt": .int(10)
        ])
    }

    private func searchResult(id: String, snippet: String) -> CodexJSONValue {
        .dictionary([
            "thread": thread(id: id, name: id, cwd: "/tmp/Core"),
            "snippet": .string(snippet)
        ])
    }

    private func snapshot(_ entries: [CanonicalThreadIndexSummary]) -> CanonicalThreadIndexSnapshot {
        CanonicalThreadIndexSnapshot(revision: .init(1), threads: entries)
    }

    private func canonical(id: String, name: String, archived: Bool) -> CanonicalThreadIndexSummary {
        CanonicalThreadIndexSummary(
            id: ThreadID(id),
            order: 0,
            status: .idle,
            latestTurnID: nil,
            latestTurnStatus: nil,
            isArchived: archived,
            isLoaded: true,
            name: name,
            preview: nil,
            cwd: .string("/tmp/Core"),
            parentThreadID: nil,
            agentNickname: nil,
            agentRole: nil,
            path: nil,
            updatedAt: ProtocolSeconds(20),
            lastChangedRevision: .init(1),
            attentionRevision: .init(1),
            hasPendingServerRequest: false
        )
    }
}
