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

    @Test func unavailableRestoredRouteFailsClosedWithoutMaterializingContent() throws {
        let source = CodexWorkspaceTabs()
        let id = source.open(
            TestWorkspaceTabAdapter(resourceKey: "available-before-restart", lifetime: .pinned),
            from: .summary
        )
        let restored = CodexWorkspaceTabs(restoring: source.restorationState)
        restored.register([
            TestWorkspaceTabAdapter(resourceKey: "different-resource", lifetime: .pinned)
        ])

        restored.activate(id)

        #expect(restored.snapshot.instance(id: id)?.isMaterialized == false)
        #expect(restored.content(for: id) == nil)
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

        #expect(tabs.lastClosedRoute == original.durableRoute)
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

    @Test func transcriptReviewRouteRestoresWhenItsCanonicalSourceIsAvailable() throws {
        let session = CodexGitReviewSession(
            snapshot: CodexGitReviewSnapshot(branchName: "main")
        )
        let adapter = CodexReviewWorkspaceTabAdapter(
            workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
            session: session,
            source: .transcript,
            selectedFilePath: "Sources/Restored.swift"
        )
        let source = CodexWorkspaceTabs()
        let id = source.open(adapter, from: .transcript)
        let restored = CodexWorkspaceTabs(restoring: source.restorationState)

        restored.register([
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                session: session,
                source: .transcript
            )
        ])
        restored.activate(id)

        #expect(restored.snapshot.instance(id: id)?.isMaterialized == true)
        #expect(
            CodexReviewWorkspaceTabAdapter.selectedFilePath(
                in: try #require(restored.snapshot.instance(id: id)?.state)
            ) == "Sources/Restored.swift"
        )
    }

    @Test func legacyBridgeSharesManagedOrderingSelectionAndFallback() {
        let tabs = CodexWorkspaceTabs()
        tabs.openLegacy("terminal")
        let planID = tabs.open(
            CodexPlanWorkspaceTabAdapter(plan: CodexPlanSummary(steps: [])),
            from: .summary
        )

        #expect(
            tabs.snapshot.topology.right.orderedTabs
                == [.legacy("terminal"), .workspace(planID)]
        )
        #expect(tabs.snapshot.topology.right.activeTab == .workspace(planID))

        tabs.activateLegacy("terminal")
        #expect(tabs.snapshot.topology.right.activeTab == .legacy("terminal"))

        tabs.closeLegacy("terminal")
        #expect(tabs.snapshot.topology.right.orderedTabs == [.workspace(planID)])
        #expect(tabs.snapshot.topology.right.activeTab == .workspace(planID))
    }

    @Test func reducerStressPreservesIdentityTopologyAndDurabilityInvariants() async {
        let tabs = CodexWorkspaceTabs()

        for index in 0..<20_000 {
            switch index % 10 {
            case 0:
                tabs.open(
                    TestWorkspaceTabAdapter(
                        resourceKey: "pinned-\(index % 23)",
                        lifetime: .pinned
                    ),
                    from: .summary
                )
            case 1:
                tabs.open(
                    TestWorkspaceTabAdapter(
                        resourceKey: "preview-\(index % 31)",
                        lifetime: .preview
                    ),
                    from: .transcript
                )
            case 2:
                if let id = tabs.snapshot.instances.first?.id { tabs.activate(id) }
            case 3:
                if let id = tabs.snapshot.instances.last?.id {
                    tabs.move(id, to: index.isMultiple(of: 2) ? .right : .bottom)
                }
            case 4:
                if let id = tabs.snapshot.instances.first(where: { !$0.isPinned })?.id {
                    tabs.pin(id)
                }
            case 5:
                if let id = tabs.snapshot.instances.first?.id { tabs.close(id) }
            case 6:
                tabs.openLegacy("legacy-\(index % 13)")
            case 7:
                tabs.activateLegacy("legacy-\((index - 1) % 13)")
            case 8:
                tabs.closeLegacy("legacy-\((index - 2) % 13)")
            default:
                _ = tabs.undoClose()
            }

            assertInvariants(tabs.snapshot, restoration: tabs.restorationState)
            if index.isMultiple(of: 16) { await Task.yield() }
        }
    }

    private func assertInvariants(
        _ snapshot: CodexWorkspaceTabSnapshot,
        restoration: CodexWorkspaceTabRestorationState
    ) {
        let right = snapshot.topology.right
        let bottom = snapshot.topology.bottom
        #expect(Set(right.orderedTabs).count == right.orderedTabs.count)
        #expect(Set(bottom.orderedTabs).count == bottom.orderedTabs.count)
        #expect(Set(right.orderedTabs).isDisjoint(with: Set(bottom.orderedTabs)))
        #expect(right.activeTab.map(right.orderedTabs.contains) ?? true)
        #expect(bottom.activeTab.map(bottom.orderedTabs.contains) ?? true)
        #expect(!right.orderedTabs.isEmpty || !right.isOpen)
        #expect(!bottom.orderedTabs.isEmpty || !bottom.isOpen)

        let instanceIDs = snapshot.instances.map(\.id)
        let topologyIDs = (right.orderedTabs + bottom.orderedTabs).compactMap(\.workspaceTabID)
        #expect(Set(instanceIDs).count == instanceIDs.count)
        #expect(Set(snapshot.instances.map(\.contentID)).count == snapshot.instances.count)
        #expect(Set(instanceIDs) == Set(topologyIDs))
        #expect(snapshot.instances.allSatisfy { $0.isPinned || $0.durableRoute == nil })
        #expect(restoration.tabs.allSatisfy { tab in
            snapshot.instance(id: tab.id)?.isPinned == true
                && tab.durableRoute == snapshot.instance(id: tab.id)?.durableRoute
        })
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
