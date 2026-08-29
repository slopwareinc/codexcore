import XCTest
@testable import CodexCoreUI
import AppKit
import SwiftUI

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

    @MainActor
    func testMountedCustomSectionsDoNotRemountUnrelatedSections() {
        let counter = CodexSidebarMountedRenderCounter()
        let before = makeSnapshot(alphaTitle: "Alpha", betaTitle: "Beta")
        let after = makeSnapshot(alphaTitle: "Alpha changed", betaTitle: "Beta")
        let host = NSHostingView(rootView: MountedSectionsHarness(snapshot: before, counter: counter))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.frame = window.contentView?.bounds ?? .zero
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))

        host.rootView = MountedSectionsHarness(snapshot: after, counter: counter)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        window.close()

        XCTAssertEqual(counter.count(for: "alpha-section"), 1)
        XCTAssertEqual(counter.count(for: "beta-section"), 1)
    }

    private func makeSnapshot(alphaTitle: String, betaTitle: String) -> CodexSidebarSnapshot {
        CodexSidebarProjection.snapshot(.init(
            chats: [
                .init(id: "alpha-task", title: alphaTitle, sectionID: "alpha-section"),
                .init(id: "beta-task", title: betaTitle, sectionID: "beta-section"),
            ],
            sections: [
                .init(id: "alpha-section", name: "Alpha"),
                .init(id: "beta-section", name: "Beta"),
            ],
            currentWorkspacePath: "/tmp",
            now: 100
        ))
    }
}

private struct MountedSectionsHarness: View {
    let snapshot: CodexSidebarSnapshot
    let counter: CodexSidebarMountedRenderCounter

    var body: some View {
        CodexSidebarCustomSectionsView(
            snapshot: snapshot,
            sectionDestinations: [],
            onToggleSection: { _ in },
            onSelectChat: { _ in },
            onTogglePinChat: { _ in },
            onArchiveChat: { _ in },
            onToggleThreadSelection: { _ in },
            onMoveChat: { _, _ in },
            renderCounter: counter
        )
        .codexAgentTheme(.officialDark)
    }
}
