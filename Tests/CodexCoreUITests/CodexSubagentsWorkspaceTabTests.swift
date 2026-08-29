import AppKit
import CodexCore
@testable import CodexCoreUI
import Foundation
import SwiftUI
import Testing

@MainActor
struct CodexSubagentsWorkspaceTabTests {
    @Test func subagentsAdapterRestoresOneTabAndItsInternalSelection() async throws {
        let homeURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "codexcore-subagent-tab-restoration-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let home = CodexHome(path: homeURL.path)
        let transport = CoordinatorTestTransport(homePath: home.path)
        let codex = try await Codex(
            transport: transport,
            config: .init(codexHome: home)
        )
        let coordinator = CodexSubagentPresentationCoordinator(codex: codex)
        coordinator.selectParent("parent")
        await transport.sendParentDiscovery(childIDs: ["child", "other"])
        try await eventually { coordinator.agents.count == 2 }

        let adapter = CodexSubagentsWorkspaceTabAdapter(
            parentThreadID: "parent",
            coordinator: coordinator,
            selectedThreadID: "child"
        )
        let tabs = CodexWorkspaceTabs()
        let id = tabs.open(adapter, from: .transcript)
        let contentID = try #require(tabs.snapshot.instance(id: id)?.contentID)

        #expect(tabs.snapshot.topology.right.orderedTabIDs == [id])
        #expect(tabs.snapshot.instance(id: id)?.title == "Subagents")
        #expect(
            CodexSubagentsWorkspaceTabState.selectedThreadID(
                in: try #require(tabs.snapshot.instance(id: id)?.state)
            ) == "child"
        )

        let reopenedID = tabs.open(
            CodexSubagentsWorkspaceTabAdapter(
                parentThreadID: "parent",
                coordinator: coordinator,
                selectedThreadID: "other"
            ),
            from: .summary
        )
        #expect(reopenedID == id)
        #expect(tabs.snapshot.instance(id: id)?.contentID == contentID)
        #expect(
            CodexSubagentsWorkspaceTabState.selectedThreadID(
                in: try #require(tabs.snapshot.instance(id: id)?.state)
            ) == "other"
        )

        let restored = CodexWorkspaceTabs(restoring: tabs.restorationState)
        restored.register([adapter])
        restored.activate(id)

        #expect(restored.snapshot.topology.right.orderedTabIDs == [id])
        #expect(restored.snapshot.instance(id: id)?.isMaterialized == true)
        #expect(restored.content(for: id) != nil)
        #expect(
            CodexSubagentsWorkspaceTabState.selectedThreadID(
                in: try #require(restored.snapshot.instance(id: id)?.state)
            ) == "other"
        )

        await coordinator.disconnect()
        await codex.close()
    }

    @Test func coordinatorStatusChangeUpdatesOnlyThatProductionRow() async throws {
        let homeURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codexcore-subagents-row-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let home = CodexHome(path: homeURL.path)
        let transport = CoordinatorTestTransport(homePath: home.path)
        let codex = try await Codex(
            transport: transport,
            config: .init(codexHome: home)
        )
        let coordinator = CodexSubagentPresentationCoordinator(codex: codex)
        coordinator.selectParent("parent")
        await transport.sendParentDiscovery(childIDs: ["child", "other"])
        try await eventually { coordinator.panelSubagents.count == 2 }

        let before = CodexSubagentsWorkspaceProjection.snapshot(
            subagents: coordinator.panelSubagents
        )
        coordinator.store.updateStatus(
            threadID: "child",
            status: .completed(durationMs: 12)
        )
        coordinator.refreshMapperAndPublish()
        let after = CodexSubagentsWorkspaceProjection.snapshot(
            subagents: coordinator.panelSubagents
        )

        let changedIDs = before.allRows.compactMap { row -> String? in
            guard let updated = after.row(id: row.id), updated != row else { return nil }
            return row.id
        }
        #expect(changedIDs == ["child"])
        #expect(after.active.map(\.id) == ["other"])
        #expect(after.done.map(\.id) == ["child"])
        #expect(after.row(id: "other")?.id == before.row(id: "other")?.id)

        await coordinator.disconnect()
        await codex.close()
    }

    @Test func mountedSubagentUpdatesPreserveParentTranscriptHostAndProjectionCount() async throws {
        let homeURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "codexcore-subagent-mounted-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let home = CodexHome(path: homeURL.path)
        let transport = CoordinatorTestTransport(homePath: home.path)
        let codex = try await Codex(
            transport: transport,
            config: .init(codexHome: home)
        )
        let coordinator = CodexSubagentPresentationCoordinator(codex: codex)
        coordinator.selectParent("parent")
        await transport.sendParentDiscovery(childIDs: ["child", "other"])
        try await eventually { coordinator.agents.count == 2 }
        coordinator.selectTranscript("child")
        try await eventually { coordinator.agents.first?.transcript.turns.isEmpty == false }

        let turn = CodexTurnV2(
            id: "parent-turn",
            finalAnswer: .init(id: "parent-answer", text: "Stable parent", isStreaming: false),
            status: .done(durationMs: 1)
        )
        let presentation = CodexThreadUIPresentation(
            threadID: "parent",
            transcript: .init(turns: [turn])
        )
        let renderUpdate = CodexCanonicalTranscriptRenderUpdate(
            threadID: ThreadID("parent"),
            sourceRevision: StateRevision(1),
            requestSourceRevision: 0,
            turnOrder: [TurnID("parent-turn")],
            upsertedTurns: [turn],
            removedTurnIDs: [],
            dirtyTurnIDs: [TurnID("parent-turn")],
            pendingRequests: [],
            isFullRebuild: true
        )
        let tabs = CodexWorkspaceTabs()
        let adapter = CodexSubagentsWorkspaceTabAdapter(
            parentThreadID: "parent",
            coordinator: coordinator,
            selectedThreadID: "child"
        )
        let tabID = tabs.open(adapter, from: .transcript)
        let store = CodexPresentationStore()
        let hosting = NSHostingView(rootView: SubagentsMountedHarness(
            tabs: tabs,
            store: store,
            presentation: presentation,
            renderUpdate: renderUpdate
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: 1_420, height: 820)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let parentHost = try #require(subagentsTranscriptDescendant(in: hosting))
        await parentHost.waitForProjectionForTesting?()
        let projectionCount = try #require(
            parentHost.readDiagnosticsForTesting?().render.projectionCount
        )
        try await eventually {
            subagentsTranscriptDescendants(in: hosting).count >= 2
        }
        let detailHost = try #require(
            subagentsTranscriptDescendants(in: hosting).dropFirst().first
        )

        await transport.sendChildDelta(" after mount")
        try await eventually {
            coordinator.agents.first.map {
                Self.transcriptText($0.transcript).contains("after mount")
            } == true
        }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))

        #expect(subagentsTranscriptDescendant(in: hosting) === parentHost)
        #expect(subagentsTranscriptDescendants(in: hosting).dropFirst().first === detailHost)
        #expect(
            parentHost.readDiagnosticsForTesting?().render.projectionCount
                == projectionCount
        )

        tabs.updateState(
            CodexSubagentsWorkspaceTabState(selectedThreadID: "other").workspaceTabState,
            for: tabID
        )
        coordinator.selectTranscript("other")
        hosting.layoutSubtreeIfNeeded()
        try await eventually {
            subagentsTranscriptDescendants(in: hosting).count >= 2
        }
        try await eventually { coordinator.selectedProjection?.lease != nil }
        #expect(subagentsTranscriptDescendant(in: hosting) === parentHost)
        #expect(subagentsTranscriptDescendants(in: hosting).dropFirst().first === detailHost)
        #expect(
            parentHost.readDiagnosticsForTesting?().render.projectionCount
                == projectionCount
        )

        let releaseCount = coordinator.diagnostics.childLeaseReleaseCount
        tabs.close(tabID)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        try await eventually {
            coordinator.diagnostics.childLeaseReleaseCount > releaseCount
        }

        await coordinator.disconnect()
        await codex.close()
    }

    private static func transcriptText(_ transcript: CodexTranscriptV2) -> String {
        transcript.turns.flatMap { turn in
            var values = turn.narrative.compactMap { entry -> String? in
                guard case .prose(let prose) = entry else { return nil }
                return prose.text
            }
            if let finalAnswer = turn.finalAnswer?.text {
                values.append(finalAnswer)
            }
            if let liveTail = turn.liveTail {
                values.append(liveTail)
            }
            return values
        }.joined(separator: "\n")
    }
}

@MainActor
private struct SubagentsMountedHarness: View {
    @ObservedObject var tabs: CodexWorkspaceTabs
    let store: CodexPresentationStore
    let presentation: CodexThreadUIPresentation
    let renderUpdate: CodexCanonicalTranscriptRenderUpdate

    var body: some View {
        HStack(spacing: 0) {
            CodexTranscriptListHost(
                presentation: presentation,
                renderUpdate: renderUpdate,
                presentationStore: store,
                bottomContentInset: 170,
                contentHorizontalOffset: 0,
                responseAnnotations: [],
                onUpsertResponseAnnotation: { _ in },
                onRemoveResponseAnnotation: { _ in },
                productToolRenderer: nil,
                onOpenSubagent: { _ in },
                onEditUserMessage: { _ in },
                onRetryTurn: nil,
                onForkChat: nil,
                onResolveApproval: { _, _ in },
                retryRevision: 0,
                onProjectionError: { _ in }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if tabs.snapshot.topology.right.isOpen {
                CodexAgentSidePanel(
                    tabs: [],
                    workspaceTabs: tabs,
                    showsCloseButton: false,
                    onClose: {}
                )
            }
        }
    }
}

@MainActor
private func subagentsTranscriptDescendant(
    in root: NSView
) -> CodexTranscriptCollectionContainerView? {
    if let match = root as? CodexTranscriptCollectionContainerView { return match }
    for child in root.subviews {
        if let match = subagentsTranscriptDescendant(in: child) { return match }
    }
    return nil
}

@MainActor
private func subagentsTranscriptDescendants(
    in root: NSView
) -> [CodexTranscriptCollectionContainerView] {
    var matches: [CodexTranscriptCollectionContainerView] = []
    if let match = root as? CodexTranscriptCollectionContainerView {
        matches.append(match)
    }
    for child in root.subviews {
        matches.append(contentsOf: subagentsTranscriptDescendants(in: child))
    }
    return matches
}


@MainActor
private func eventually(
    attempts: Int = 300,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw SubagentsWorkspaceTestError.timedOut
}

private enum SubagentsWorkspaceTestError: Error {
    case timedOut
}
