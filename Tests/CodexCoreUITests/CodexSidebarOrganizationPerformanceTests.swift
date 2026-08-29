import XCTest
@testable import CodexCoreUI

final class CodexSidebarOrganizationPerformanceTests: XCTestCase {
    func testLargeListProjectionUsesStableRows() {
        let project = CodexProjectSummary(workspacePath: "/tmp/large", updatedAt: 1)
        let chats = (0..<2_000).map { index in
            CodexThreadSummary(
                id: "task-\(index)",
                title: "Task \(index)",
                workspacePath: project.workspacePath,
                recencyAt: TimeInterval(index)
            )
        }
        let input = CodexSidebarProjectionInput(
            projects: [project],
            chats: chats,
            currentWorkspacePath: project.workspacePath,
            now: 1
        )

        measure {
            let snapshot = CodexSidebarProjection.snapshot(input)
            XCTAssertEqual(snapshot.projects.first?.rows.count, 5)
            XCTAssertEqual(snapshot.projects.first?.rows.map(\.id).count, 5)
        }
    }
}
