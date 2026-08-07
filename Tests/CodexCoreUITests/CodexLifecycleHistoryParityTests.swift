import CodexCore
import XCTest
@testable import CodexCoreUI

final class CodexLifecycleHistoryParityTests: XCTestCase {
    func testArchivedListIsKeptSeparateFromActiveSidebarChats() {
        var session = CodexThreadListSession(currentWorkspacePath: "/workspace")
        session.applyThreadList(
            currentRaw: listRaw(id: "active", title: "Active"),
            allRaw: listRaw(id: "active", title: "Active"),
            archivedRaw: listRaw(id: "archived", title: "Archived"),
            currentWorkspacePath: "/workspace"
        )

        XCTAssertEqual(session.allChats.map(\.id), ["active"])
        XCTAssertEqual(session.archivedChats.map(\.id), ["archived"])

        let navigation = CodexSidebarNavigationSession(currentWorkspacePath: "/workspace")
        let snapshot = navigation.snapshot(
            projects: [],
            chats: session.allChats,
            archivedChats: session.archivedChats,
            currentWorkspacePath: "/workspace",
            currentThreadID: nil
        )
        XCTAssertEqual(snapshot.archivedRows.map(\.summary.id), ["archived"])
        XCTAssertTrue(snapshot.archivedRows[0].canUnarchive)
        XCTAssertTrue(snapshot.archivedRows[0].canDelete)
        XCTAssertFalse(snapshot.archivedRows[0].canArchive)
    }

    private func listRaw(id: String, title: String) -> CodexJSONValue {
        .dictionary([
            "data": .array([
                .dictionary([
                    "id": .string(id),
                    "name": .string(title),
                    "cwd": .string("/workspace")
                ])
            ])
        ])
    }
}
