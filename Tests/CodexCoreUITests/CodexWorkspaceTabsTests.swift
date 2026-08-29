import CodexCore
import Foundation
import SwiftUI
import Testing
@testable import CodexCoreUI

@MainActor
struct CodexWorkspaceTabsTests {
    @Test func terminalAdapterUsesScopedStableIdentityAndBottomPlacement() throws {
        let identity = CodexTerminalIdentity(
            threadID: "thread-235",
            worktreePath: "/tmp/codex-worktree",
            ordinal: 1
        )
        let first = CodexTerminalSession(
            workingDirectory: identity.worktreePath,
            command: "swift test",
            identity: identity
        )
        let second = CodexTerminalSession(
            workingDirectory: identity.worktreePath,
            command: "swift test",
            identity: identity
        )

        #expect(first.id == second.id)
        #expect(first.title == "swift test")

        let tabs = CodexWorkspaceTabs()
        let id = tabs.open(
            CodexTerminalWorkspaceTabAdapter(session: first),
            from: .background,
            placement: .bottom
        )

        #expect(tabs.snapshot.topology.right.orderedTabs.isEmpty)
        #expect(tabs.snapshot.topology.bottom.orderedTabIDs == [id])
        #expect(tabs.snapshot.topology.bottom.activeTabID == id)
        #expect(tabs.snapshot.instance(id: id)?.durableRoute?.resourceID == first.id)
        #expect(tabs.content(for: id) != nil)
    }

    @Test func backgroundOpenAndRestorePreservePanelFocusAndTabIdentity() throws {
        let tabs = CodexWorkspaceTabs()
        let rightID = tabs.open(
            TestWorkspaceTabAdapter(resourceKey: "right", lifetime: .pinned),
            from: .summary,
            placement: .right
        )
        let terminal = CodexTerminalSession(
            workingDirectory: "/tmp/worktree",
            command: "swift test",
            identity: CodexTerminalIdentity(
                threadID: "thread-235",
                worktreePath: "/tmp/worktree",
                ordinal: 1
            )
        )
        let bottomID = tabs.openInBackground(
            CodexTerminalWorkspaceTabAdapter(session: terminal),
            placement: .bottom
        )

        #expect(tabs.snapshot.topology.right.activeTabID == rightID)
        #expect(tabs.snapshot.topology.bottom.activeTabID == bottomID)
        #expect(tabs.snapshot.topology.focusedPlacement == .right)

        tabs.setOpen(false, placement: .right)
        tabs.restoreFocus()
        #expect(tabs.snapshot.topology.focusedPlacement == .bottom)

        let restored = CodexWorkspaceTabs(restoring: try JSONDecoder().decode(
            CodexWorkspaceTabRestorationState.self,
            from: JSONEncoder().encode(tabs.restorationState)
        ))
        restored.register([CodexTerminalWorkspaceTabAdapter(session: terminal)])
        restored.activate(bottomID)

        #expect(restored.snapshot.topology.bottom.orderedTabIDs == [bottomID])
        #expect(restored.snapshot.topology.bottom.activeTabID == bottomID)
        #expect(restored.snapshot.instance(id: bottomID)?.contentID == tabs.snapshot.instance(id: bottomID)?.contentID)
    }

    @Test func terminalRouteRestoresByScopedIdentityWhenCommandTitleChanges() throws {
        let identity = CodexTerminalIdentity(
            threadID: "thread-235",
            worktreePath: "/tmp/worktree",
            ordinal: 1
        )
        let sourceSession = CodexTerminalSession(
            title: "Terminal",
            workingDirectory: "/tmp/worktree",
            command: "swift test",
            identity: identity
        )
        let source = CodexWorkspaceTabs()
        let id = source.open(
            CodexTerminalWorkspaceTabAdapter(session: sourceSession),
            from: .commandMenu,
            placement: .bottom
        )

        let restored = CodexWorkspaceTabs(restoring: source.restorationState)
        let replacementSession = CodexTerminalSession(
            title: "Terminal",
            workingDirectory: "/tmp/worktree",
            command: "swift build",
            identity: identity
        )
        let adapter = CodexTerminalWorkspaceTabAdapter(session: replacementSession)
        restored.register([adapter])
        #expect(restored.isAvailable(id))
        restored.activate(id)
        #expect(restored.snapshot.instance(id: id)?.isMaterialized == true)
    }

    @Test func subagentsWorkspaceProjectionSeparatesActiveAndDoneRows() {
        let agents = [
            CodexSubagentState(
                id: "active",
                name: "Scout",
                title: "Explorer",
                prompt: "Find the seam",
                status: .running
            ),
            CodexSubagentState(
                id: "done",
                name: "Builder",
                title: "Implementer",
                prompt: "Build the adapter",
                status: .completed
            ),
        ]

        let snapshot = CodexSubagentsWorkspaceProjection.snapshot(
            subagents: agents,
            selectedThreadID: "active"
        )

        #expect(snapshot.active.map(\.id) == ["active"])
        #expect(snapshot.done.map(\.id) == ["done"])
        #expect(snapshot.selectedThreadID == "active")
        #expect(snapshot.active[0].statusSummary == "Working")
        #expect(snapshot.done[0].statusSummary == "Completed")
    }

    @Test func subagentsWorkspaceSelectionStateRoundTripsWithoutTranscriptData() throws {
        let state = CodexSubagentsWorkspaceTabState(selectedThreadID: "child")
            .workspaceTabState
        let restored = CodexSubagentsWorkspaceTabState(state)

        #expect(restored.selectedThreadID == "child")
        #expect(state.data.contains(Data("child".utf8)))
        #expect(!state.data.contains(Data("transcript".utf8)))
    }

    @Test func unresolvedSubagentOpenerUsesOneWorkspaceTabWhileChildHydrates() async throws {
        let homeURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codexcore-subagents-unresolved-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let transport = CoordinatorTestTransport(homePath: homeURL.path)
        let codex = try await Codex(
            transport: transport,
            config: .init(codexHome: CodexHome(path: homeURL.path))
        )
        let coordinator = CodexSubagentPresentationCoordinator(codex: codex)
        let tabs = CodexWorkspaceTabs()
        let childID = "child-not-loaded-yet"

        let tabID = tabs.open(
            CodexSubagentsWorkspaceTabAdapter(
                parentThreadID: "parent",
                coordinator: coordinator,
                selectedThreadID: childID
            ),
            from: .transcript
        )

        #expect(tabs.snapshot.topology.right.orderedTabs == [.workspace(tabID)])
        #expect(tabs.snapshot.topology.right.activeTab == .workspace(tabID))
        #expect(
            CodexSubagentsWorkspaceTabState.selectedThreadID(
                in: try #require(tabs.snapshot.instance(id: tabID)?.state)
            ) == childID
        )
        #expect(tabs.snapshot.topology.right.orderedTabs.allSatisfy { $0.legacyID == nil })

        await codex.close()
    }

    @Test func subagentsWorkspaceAccessibilityUsesStableMasterAndRowVocabulary() {
        let row = CodexSubagentsWorkspaceRow(CodexSubagentState(
            id: "child",
            name: "Scout",
            title: "Explorer",
            prompt: "",
            status: .running
        ))

        #expect(CodexSubagentsWorkspaceAccessibility.masterIdentifier == "subagents.master")
        #expect(CodexSubagentsWorkspaceAccessibility.backToMasterLabel == "Back to subagents")
        #expect(CodexSubagentsWorkspaceAccessibility.rowIdentifier(row.id) == "subagent.row.child")
        #expect(CodexSubagentsWorkspaceAccessibility.rowLabel(row) == "Scout, Working")
        #expect(CodexSubagentsWorkspaceAccessibility.rowHint == "Show subagent transcript")
    }

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

    @Test func explicitlyOpeningAnEmptyPanelShowsItsLauncher() {
        let tabs = CodexWorkspaceTabs()

        tabs.setOpen(true)
        tabs.reconcileLegacy([])

        #expect(tabs.snapshot.topology.right.isOpen)
        #expect(tabs.snapshot.topology.right.orderedTabs.isEmpty)
        #expect(tabs.snapshot.topology.right.activeTab == nil)

        tabs.setOpen(false)

        #expect(!tabs.snapshot.topology.right.isOpen)
    }

    @Test func removingTheLastLegacyTabDuringReconciliationClosesThePanel() {
        let tabs = CodexWorkspaceTabs()
        tabs.openLegacy("terminal")

        tabs.reconcileLegacy([])

        #expect(tabs.snapshot.topology.right.orderedTabs.isEmpty)
        #expect(tabs.snapshot.topology.right.activeTab == nil)
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

    @Test func registrationReplacementDematerializesDisappearedPlanWithoutClosingItsTab() throws {
        let tabs = CodexWorkspaceTabs()
        let id = tabs.open(
            CodexPlanWorkspaceTabAdapter(plan: CodexPlanSummary(
                steps: [TurnPlanStep(step: "Old plan", status: .inProgress)]
            )),
            from: .summary
        )
        let contentID = try #require(tabs.snapshot.instance(id: id)?.contentID)

        tabs.register([])

        #expect(tabs.snapshot.instance(id: id)?.contentID == contentID)
        #expect(tabs.snapshot.topology.right.activeTab == .workspace(id))
        #expect(tabs.snapshot.instance(id: id)?.isMaterialized == false)
        #expect(!tabs.isAvailable(id))
        #expect(tabs.content(for: id) == nil)

        tabs.register([
            CodexPlanWorkspaceTabAdapter(plan: CodexPlanSummary(
                steps: [TurnPlanStep(step: "Current plan", status: .completed)]
            ))
        ])
        #expect(tabs.snapshot.instance(id: id)?.isMaterialized == false)
        #expect(tabs.isAvailable(id))

        tabs.activate(id)
        #expect(tabs.snapshot.instance(id: id)?.isMaterialized == true)
        #expect(tabs.content(for: id) != nil)
    }

    @Test func registrationReplacementRejectsSupersededTranscriptReviewSource() throws {
        let oldSession = reviewSession(sourceID: "turn-old")
        let tabs = CodexWorkspaceTabs()
        let id = tabs.open(
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                session: oldSession,
                source: .transcript
            ),
            from: .summary
        )
        let contentID = try #require(tabs.snapshot.instance(id: id)?.contentID)
        let newSession = reviewSession(sourceID: "turn-new")

        tabs.register([
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                session: newSession
            ),
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                session: newSession,
                source: .transcript
            ),
        ])

        #expect(tabs.snapshot.instance(id: id)?.contentID == contentID)
        #expect(tabs.snapshot.instance(id: id)?.isMaterialized == false)
        #expect(!tabs.isAvailable(id))
        #expect(tabs.content(for: id) == nil)
    }

    @Test func genericReviewRouteAdvancesToCanonicalSourceWithoutChangingIdentity() throws {
        let tabs = CodexWorkspaceTabs()
        let id = tabs.open(
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                session: CodexGitReviewSession(
                    snapshot: CodexGitReviewSnapshot(branchName: "main")
                )
            ),
            from: .summary
        )
        let original = try #require(tabs.snapshot.instance(id: id))

        tabs.register([
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                session: reviewSession(
                    sourceID: "canonical/thread/turn",
                    revision: 7
                )
            )
        ])

        let advanced = try #require(tabs.snapshot.instance(id: id))
        #expect(advanced.id == original.id)
        #expect(advanced.contentID == original.contentID)
        #expect(advanced.durableRoute != original.durableRoute)
        #expect(advanced.isMaterialized)
        #expect(tabs.isAvailable(id))
        #expect(tabs.registeredContentRevision(for: id) == 7)
    }

    @Test func changedReviewFactsRefreshRegistrationWithoutChangingTabOrRouteIdentity() throws {
        let tabs = CodexWorkspaceTabs()
        let sourceID = "canonical/thread/turn"
        let id = tabs.open(
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                session: reviewSession(sourceID: sourceID, revision: 7)
            ),
            from: .summary
        )
        let original = try #require(tabs.snapshot.instance(id: id))

        tabs.register([
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                session: reviewSession(sourceID: sourceID, revision: 8)
            )
        ])

        let refreshed = try #require(tabs.snapshot.instance(id: id))
        #expect(refreshed.id == original.id)
        #expect(refreshed.contentID == original.contentID)
        #expect(refreshed.durableRoute == original.durableRoute)
        #expect(refreshed.isMaterialized)
        #expect(tabs.registeredContentRevision(for: id) == 8)
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

    @Test func reopeningClosedResourceConsumesUndoWithoutCreatingDuplicateInstance() throws {
        let tabs = CodexWorkspaceTabs()
        let adapter = TestWorkspaceTabAdapter(resourceKey: "undo-resource", lifetime: .pinned)
        let originalID = tabs.open(adapter, from: .summary)
        let contentID = try #require(tabs.snapshot.instance(id: originalID)?.contentID)
        tabs.close(originalID)

        let reopenedID = tabs.open(adapter, from: .summary)

        #expect(reopenedID == originalID)
        #expect(tabs.snapshot.instances.count == 1)
        #expect(tabs.snapshot.instance(id: reopenedID)?.contentID == contentID)
        #expect(tabs.undoClose() == nil)
        #expect(tabs.snapshot.instances.count == 1)
        #expect(tabs.snapshot.topology.right.orderedTabIDs == [originalID])
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

    @Test func reducerStressPreservesIdentityTopologyAndDurabilityInvariants() async throws {
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
            if index.isMultiple(of: 8) {
                try await Task.sleep(for: .milliseconds(1))
            }
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

    private func reviewSession(sourceID: String, revision: UInt64 = 1) -> CodexGitReviewSession {
        CodexGitReviewSession(snapshot: CodexGitReviewSnapshot(
            revision: CodexGitReviewRevision(sourceID: sourceID, value: revision),
            branchName: "main"
        ))
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
