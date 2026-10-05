import AppKit
import CodexCore
import SwiftUI
import Testing
@testable import CodexCoreUI

@MainActor
struct CodexThreadResourceWorkspaceTests {
    @Test func typedRequestRoundTripsResourceIdentityAndOrigin() throws {
        let resource = CodexThreadResource(
            id: "generated-image:fixture-thread/fixture-turn/image",
            kind: .generatedImage,
            title: "Generated image",
            origin: .init(threadID: "fixture-thread", turnID: "fixture-turn", itemID: "image"),
            metadata: .init(path: "/workspace/image.png")
        )
        let request = resource.workspaceTabRequest(opener: .transcript, placement: .right)
        let restored = try JSONDecoder().decode(
            CodexWorkspaceTabRequest.self,
            from: JSONEncoder().encode(request)
        )

        #expect(restored == request)
        #expect(restored.resourceKind == .generatedImage)
        #expect(restored.origin.stableID == "fixture-thread/fixture-turn/image")
        #expect(resource.workspaceTabRequest(opener: .newTab).opener == .newTab)
    }

    @Test func summaryAndNewTabReadExactlyTheSameInventory() {
        let inventory = CodexThreadResourceInventory(
            threadID: "fixture-thread",
            key: .init(canonicalRevision: StateRevision(4)),
            resources: [
                .init(
                    id: "source:one",
                    kind: .source,
                    title: "README.md",
                    origin: .init(threadID: "fixture-thread", turnID: "fixture-turn")
                ),
                .init(
                    id: "artifact:one",
                    kind: .artifact,
                    title: "report.html",
                    origin: .init(threadID: "fixture-thread", turnID: "fixture-turn")
                ),
            ]
        )
        let summaryIDs = Set(inventory.resources.map(\.id))
        let newTabIDs = Set(
            CodexThreadResourcePresentation.orderedKinds.flatMap {
                inventory.resources(of: $0).map(\.id)
            }
        )

        #expect(summaryIDs == newTabIDs)
        #expect(CodexThreadResourcePresentation.sectionTitle(for: .artifact) == "Artifacts")
        #expect(CodexThreadResourcePresentation.accessibilityLabel(for: inventory.resources[0]).contains("README.md"))
    }

    @Test func typedRequestOpeningPreservesWorkspaceTabIdentityAcrossRestoration() throws {
        let resource = CodexThreadResource(
            id: "review:fixture-thread:workspace",
            kind: .review,
            title: "Review",
            origin: .init(threadID: "fixture-thread")
        )
        let request = resource.workspaceTabRequest(opener: .summary)
        let adapter = CodexReviewWorkspaceTabAdapter(
            workspaceURL: URL(fileURLWithPath: "/tmp"),
            session: CodexGitReviewSession(
                snapshot: CodexGitReviewSnapshot(
                    revision: .init(sourceID: "fixture-review", value: 1),
                    branchName: "main"
                )
            )
        )
        let tabs = CodexWorkspaceTabs()
        let id = tabs.open(adapter, request: request)
        let state = tabs.restorationState
        let restored = CodexWorkspaceTabs(restoring: state)

        #expect(restored.snapshot.instance(id: id)?.isMaterialized == false)
        #expect(restored.snapshot.instance(id: id)?.openMetadata.opener == .summary)
        #expect(restored.snapshot.instance(id: id)?.durableRoute == adapter.workspaceTabRegistration.durableRoute)
    }

    @Test func resourceRowsExposeStableAccessibleOpenAffordances() throws {
        let resource = CodexThreadResource(
            id: "background-terminal:fixture-thread:process-1",
            kind: .backgroundTerminal,
            title: "swift test",
            detail: "/workspace/FixtureProject",
            status: .inProgress,
            origin: .init(threadID: "fixture-thread", turnID: "fixture-turn"),
            metadata: .init(processID: "process-1", command: "swift test")
        )
        let hosting = NSHostingView(
            rootView: CodexThreadResourceRow(resource: resource) { _ in }
                .frame(width: 420, height: 48)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 48)
        hosting.layoutSubtreeIfNeeded()
        _ = hosting
        #expect(CodexThreadResourcePresentation.accessibilityLabel(for: resource).contains("in progress"))
    }

    @Test func projectionPerformanceRemainsBoundedForLongThread() {
        let snapshot = largeSnapshot(itemCount: 1_085)
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<10 {
            _ = CodexThreadResourceProjection.project(
                snapshot: snapshot,
                threadID: "fixture-thread"
            )
        }
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed < .seconds(2))
    }

    private func largeSnapshot(itemCount: Int) -> CanonicalStateSnapshot {
        let threadID: ThreadID = "fixture-thread"
        let turnID: TurnID = "fixture-turn"
        let turnKey = TurnKey(threadID: threadID, turnID: turnID)
        let keys = (0..<itemCount).map { ItemID("item-\($0)") }
        let items = Dictionary(uniqueKeysWithValues: keys.map { itemID in
            let key = ItemKey(threadID: threadID, turnID: turnID, itemID: itemID)
            return (key, CanonicalItem(
                key: key,
                kind: .webSearch,
                payload: ["query": .string(itemID.rawValue)],
                authority: .completed
            ))
        })
        return CanonicalStateSnapshot(
            revision: StateRevision(1),
            threads: [threadID: CanonicalThread(id: threadID, turnOrder: [turnID])],
            turns: [turnKey: CanonicalTurn(key: turnKey, itemOrder: keys)],
            items: items
        )
    }
}
