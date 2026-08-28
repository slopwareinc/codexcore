import CodexCore
import Foundation
import SwiftUI
import Testing
@testable import CodexCoreUI

@MainActor
struct CodexWorkspaceTabsTests {
    @Test func planAndReviewOpenThroughOneAdapterInterfaceWithStableIdentity() throws {
        let tabs = CodexWorkspaceTabs()
        let plan = CodexPlanWorkspaceTabAdapter(plan: CodexPlanSummary(
            steps: [TurnPlanStep(step: "Inspect", status: .inProgress)]
        ))
        let review = CodexReviewWorkspaceTabAdapter(
            workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
            session: CodexGitReviewSession(
                snapshot: CodexGitReviewSnapshot(branchName: "main")
            )
        )

        let planID = tabs.open(plan, from: .summary)
        let originalContentID = try #require(tabs.snapshot.instance(id: planID)?.contentID)
        let reviewID = tabs.open(review, from: .commandMenu)

        #expect(tabs.snapshot.topology.right.orderedTabIDs == [planID, reviewID])
        #expect(tabs.snapshot.topology.right.activeTabID == reviewID)

        let reopenedPlanID = tabs.open(
            CodexPlanWorkspaceTabAdapter(plan: CodexPlanSummary(
                steps: [TurnPlanStep(step: "Inspect", status: .completed)]
            )),
            from: .summary
        )

        #expect(reopenedPlanID == planID)
        #expect(tabs.snapshot.instance(id: planID)?.contentID == originalContentID)
        #expect(tabs.snapshot.topology.right.orderedTabIDs == [planID, reviewID])
        #expect(tabs.snapshot.topology.right.activeTabID == planID)
    }

    @Test func closingTheActiveTabChoosesItsNeighborThenClosesAnEmptyPanel() {
        let tabs = CodexWorkspaceTabs()
        let planID = tabs.open(
            CodexPlanWorkspaceTabAdapter(plan: CodexPlanSummary(steps: [])),
            from: .summary
        )
        let reviewID = tabs.open(
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                session: CodexGitReviewSession(
                    snapshot: CodexGitReviewSnapshot(branchName: "main")
                )
            ),
            from: .commandMenu
        )

        tabs.close(reviewID)

        #expect(tabs.snapshot.topology.right.orderedTabIDs == [planID])
        #expect(tabs.snapshot.topology.right.activeTabID == planID)
        #expect(tabs.snapshot.topology.right.isOpen)

        tabs.close(planID)

        #expect(tabs.snapshot.topology.right.orderedTabIDs.isEmpty)
        #expect(tabs.snapshot.topology.right.activeTabID == nil)
        #expect(!tabs.snapshot.topology.right.isOpen)
    }

    @Test func previewReplacementPreservesTheSlotUntilPinningMakesItDurable() throws {
        let tabs = CodexWorkspaceTabs()
        let firstID = tabs.open(
            TestWorkspaceTabAdapter(resourceKey: "preview-a", lifetime: .preview),
            from: .transcript
        )
        let contentID = try #require(tabs.snapshot.instance(id: firstID)?.contentID)

        let replacementID = tabs.open(
            TestWorkspaceTabAdapter(resourceKey: "preview-b", lifetime: .preview),
            from: .transcript
        )

        #expect(replacementID == firstID)
        #expect(tabs.snapshot.instance(id: replacementID)?.contentID == contentID)
        #expect(tabs.snapshot.instance(id: replacementID)?.isPinned == false)
        #expect(tabs.snapshot.instance(id: replacementID)?.durableRoute == nil)
        #expect(tabs.snapshot.instance(id: replacementID)?.openMetadata.replacedResourceKey == "preview-a")
        #expect(tabs.restorationState.tabs.isEmpty)

        tabs.pin(replacementID)
        let nextPreviewID = tabs.open(
            TestWorkspaceTabAdapter(resourceKey: "preview-c", lifetime: .preview),
            from: .transcript
        )

        #expect(tabs.snapshot.instance(id: replacementID)?.isPinned == true)
        #expect(tabs.snapshot.instance(id: replacementID)?.durableRoute != nil)
        #expect(tabs.restorationState.tabs.map(\.id) == [replacementID])
        #expect(nextPreviewID != replacementID)
    }

    @Test func restorationKeepsPerTabStateAndDefersContentMaterialization() throws {
        var contentBuildCount = 0
        let adapter = TestWorkspaceTabAdapter(
            resourceKey: "durable",
            lifetime: .pinned,
            onBuildContent: { contentBuildCount += 1 }
        )
        let tabs = CodexWorkspaceTabs()
        let id = tabs.open(adapter, from: .summary)
        let state = CodexWorkspaceTabState(data: Data("selected.swift".utf8))
        tabs.updateState(state, for: id)

        let encoded = try JSONEncoder().encode(tabs.restorationState)
        let decoded = try JSONDecoder().decode(
            CodexWorkspaceTabRestorationState.self,
            from: encoded
        )
        let restored = CodexWorkspaceTabs(restoring: decoded)

        #expect(restored.snapshot.instance(id: id)?.state == state)
        #expect(restored.snapshot.instance(id: id)?.isMaterialized == false)
        restored.register([adapter])
        #expect(contentBuildCount == 0)

        restored.activate(id)

        #expect(restored.snapshot.instance(id: id)?.isMaterialized == true)
        #expect(restored.content(for: id) != nil)
        #expect(contentBuildCount == 1)
    }

    @Test func movingBetweenPanelsPreservesContentAndPanelLocalFallback() throws {
        let tabs = CodexWorkspaceTabs()
        let planID = tabs.open(
            CodexPlanWorkspaceTabAdapter(plan: CodexPlanSummary(steps: [])),
            from: .summary
        )
        let reviewID = tabs.open(
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                session: CodexGitReviewSession(
                    snapshot: CodexGitReviewSnapshot(branchName: "main")
                )
            ),
            from: .commandMenu
        )
        let contentID = try #require(tabs.snapshot.instance(id: reviewID)?.contentID)

        tabs.move(reviewID, to: .bottom)

        #expect(tabs.snapshot.topology.right.orderedTabIDs == [planID])
        #expect(tabs.snapshot.topology.right.activeTabID == planID)
        #expect(tabs.snapshot.topology.bottom.orderedTabIDs == [reviewID])
        #expect(tabs.snapshot.topology.bottom.activeTabID == reviewID)
        #expect(tabs.snapshot.topology.focusedPlacement == .bottom)
        #expect(tabs.snapshot.instance(id: reviewID)?.contentID == contentID)

        tabs.close(reviewID)

        #expect(tabs.snapshot.topology.bottom.orderedTabIDs.isEmpty)
        #expect(!tabs.snapshot.topology.bottom.isOpen)
        #expect(tabs.snapshot.topology.focusedPlacement == .right)
        #expect(tabs.snapshot.topology.right.activeTabID == planID)
    }

    @Test func undoCloseRestoresTheDurableRouteStateAndStableIdentities() throws {
        let tabs = CodexWorkspaceTabs()
        let id = tabs.open(
            TestWorkspaceTabAdapter(resourceKey: "undo", lifetime: .pinned),
            from: .summary
        )
        let original = try #require(tabs.snapshot.instance(id: id))
        let state = CodexWorkspaceTabState(data: Data("filter=swift".utf8))
        tabs.updateState(state, for: id)

        tabs.close(id)

        #expect(tabs.lastClosedRoute?.route == original.durableRoute)
        let restoredID = try #require(tabs.undoClose())

        #expect(restoredID == id)
        #expect(tabs.snapshot.instance(id: id)?.contentID == original.contentID)
        #expect(tabs.snapshot.instance(id: id)?.state == state)
        #expect(tabs.snapshot.topology.right.orderedTabIDs == [id])
        #expect(tabs.snapshot.topology.right.activeTabID == id)
    }

    @Test func reviewOpenersReplaceRouteStateWithoutChangingContentIdentity() throws {
        let tabs = CodexWorkspaceTabs()
        let session = CodexGitReviewSession(
            snapshot: CodexGitReviewSnapshot(branchName: "main")
        )
        let genericID = tabs.open(
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                session: session
            ),
            from: .summary
        )
        let generic = try #require(tabs.snapshot.instance(id: genericID))

        let transcriptID = tabs.open(
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                session: session,
                source: .transcript,
                selectedFilePath: "Sources/Feature.swift"
            ),
            from: .transcript
        )
        let transcript = try #require(tabs.snapshot.instance(id: transcriptID))

        #expect(transcriptID == genericID)
        #expect(transcript.contentID == generic.contentID)
        #expect(transcript.durableRoute != generic.durableRoute)
        #expect(transcript.openMetadata.replacedRoute == generic.durableRoute)
        #expect(
            CodexReviewWorkspaceTabAdapter.selectedFilePath(in: transcript.state)
                == "Sources/Feature.swift"
        )

        let reopenedID = tabs.open(
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                session: session
            ),
            from: .summary
        )

        #expect(reopenedID == genericID)
        #expect(tabs.snapshot.instance(id: genericID)?.durableRoute == generic.durableRoute)
        #expect(
            CodexReviewWorkspaceTabAdapter.selectedFilePath(
                in: try #require(tabs.snapshot.instance(id: genericID)?.state)
            ) == nil
        )
    }
}

@MainActor
private struct TestWorkspaceTabAdapter: CodexWorkspaceTabAdapter {
    var resourceKey: String
    var lifetime: CodexWorkspaceTabLifetime
    var onBuildContent: () -> Void

    init(
        resourceKey: String,
        lifetime: CodexWorkspaceTabLifetime,
        onBuildContent: @escaping () -> Void = {}
    ) {
        self.resourceKey = resourceKey
        self.lifetime = lifetime
        self.onBuildContent = onBuildContent
    }

    var workspaceTabRegistration: CodexWorkspaceTabRegistration {
        CodexWorkspaceTabRegistration(
            resourceKey: resourceKey,
            title: resourceKey,
            systemImage: "doc",
            lifetime: lifetime,
            durableRoute: CodexWorkspaceTabRoute(
                adapterID: "test",
                version: 1,
                resourceID: resourceKey
            )
        ) { _ in
            onBuildContent()
            return AnyView(EmptyView())
        }
    }
}
