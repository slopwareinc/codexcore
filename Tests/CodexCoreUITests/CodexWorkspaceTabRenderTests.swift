import AppKit
import CodexCore
import SwiftUI
import Testing
@testable import CodexCoreUI

@MainActor
struct CodexWorkspaceTabRenderTests {
    @Test func bottomPanelMountsOnlyTheActiveTerminalDisplayWork() throws {
        let panel = CodexWorkspacePanelState(threadID: "thread-235")
        let firstID = panel.openTerminal(workspacePath: "/tmp", command: "swift test")
        let secondID = panel.openTerminal(workspacePath: "/tmp", command: "swift build")
        let firstTabID = try #require(panel.terminalTabID(for: firstID))
        let secondTabID = try #require(panel.terminalTabID(for: secondID))
        let first = try #require(panel.terminalSessions.first { $0.id == firstID })
        let second = try #require(panel.terminalSessions.first { $0.id == secondID })
        panel.workspaceTabs.activate(firstTabID)

        let hosting = NSHostingView(rootView: CodexAgentSidePanel(
            tabs: [],
            workspaceTabs: panel.workspaceTabs,
            showsCloseButton: false,
            onClose: {},
            placement: .bottom
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))

        #expect(first.isSurfaceVisible)
        #expect(!second.isSurfaceVisible)
        let firstHostIdentity = first.terminalHostIdentity
        let secondHostIdentity = second.terminalHostIdentity

        panel.workspaceTabs.activate(secondTabID)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))

        #expect(!first.isSurfaceVisible)
        #expect(second.isSurfaceVisible)
        #expect(first.terminalHostIdentity == firstHostIdentity)
        #expect(second.terminalHostIdentity == secondHostIdentity)
    }

    @Test func bottomTerminalPanelKeepsTranscriptAndPTYHostIdentities() throws {
        let model = WorkspaceTabRenderHarnessModel()
        let terminalID = model.panel.openTerminal(
            workspacePath: "/tmp",
            command: "swift test"
        )
        let terminal = try #require(model.panel.terminalSessions.first { $0.id == terminalID })
        let hostIdentity = terminal.terminalHostIdentity
        let hosting = NSHostingView(rootView: WorkspaceTabRenderHarness(model: model))
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let transcriptHost = try #require(transcriptDescendant(in: hosting))
        #expect(terminal.terminalHostIdentity == hostIdentity)

        let tabID = try #require(model.panel.terminalTabID(for: terminalID))
        model.panel.workspaceTabs.move(tabID, to: .right)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        model.panel.workspaceTabs.move(tabID, to: .bottom)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        #expect(transcriptDescendant(in: hosting) === transcriptHost)
        #expect(terminal.terminalHostIdentity == hostIdentity)
    }

    @Test func tabSwitchesKeepTheSameTranscriptHost() throws {
        let model = WorkspaceTabRenderHarnessModel()
        let hosting = NSHostingView(rootView: WorkspaceTabRenderHarness(model: model))
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let transcriptHost = try #require(transcriptDescendant(in: hosting))

        let planID = model.panel.workspaceTabs.open(
            CodexPlanWorkspaceTabAdapter(plan: model.plan),
            from: .summary
        )
        let reviewID = model.panel.workspaceTabs.open(
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp"),
                session: model.review
            ),
            from: .summary
        )
        for index in 0..<50 {
            model.panel.workspaceTabs.activate(index.isMultiple(of: 2) ? planID : reviewID)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            #expect(transcriptDescendant(in: hosting) === transcriptHost)
        }
    }

    @Test func tabReconciliationDoesNotIncrementCanonicalProjectionCount() async throws {
        let turn = CodexTurnV2(
            id: "turn",
            finalAnswer: .init(id: "answer", text: "Stable transcript", isStreaming: false),
            status: .done(durationMs: 1)
        )
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [turn])
        )
        let renderUpdate = CodexCanonicalTranscriptRenderUpdate(
            threadID: ThreadID("thread"),
            sourceRevision: StateRevision(1),
            requestSourceRevision: 0,
            turnOrder: [TurnID("turn")],
            upsertedTurns: [turn],
            removedTurnIDs: [],
            dirtyTurnIDs: [TurnID("turn")],
            pendingRequests: [],
            isFullRebuild: true
        )
        let tabs = CodexWorkspaceTabs()
        let hosting = NSHostingView(rootView: WorkspaceTabObservationHarness(
            tabs: tabs,
            store: CodexPresentationStore(),
            presentation: presentation,
            renderUpdate: renderUpdate
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: 1_260, height: 720)
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

        let plan = CodexPlanWorkspaceTabAdapter(plan: CodexPlanSummary(steps: []))
        let reviewSourceID = "canonical/thread/turn"
        let review = CodexReviewWorkspaceTabAdapter(
            workspaceURL: URL(fileURLWithPath: "/tmp"),
            session: CodexGitReviewSession(
                snapshot: CodexGitReviewSnapshot(
                    revision: .init(sourceID: reviewSourceID, value: 7),
                    branchName: "main"
                )
            )
        )
        let files = CodexFilesWorkspaceTabAdapter(workspaceURL: URL(fileURLWithPath: "/tmp"))
        let preview = CodexFilePreviewWorkspaceTabAdapter(
            fileURL: URL(fileURLWithPath: "/tmp/Workspace.swift")
        )
        let replacementPreview = CodexFilePreviewWorkspaceTabAdapter(
            fileURL: URL(fileURLWithPath: "/tmp/Replacement.swift")
        )
        var available: [any CodexWorkspaceTabAdapter] = [
            plan,
            review,
            files,
            preview,
            replacementPreview,
        ]
        let planID = tabs.open(plan, from: .summary)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        await Task.yield()
        let transcriptHost = try #require(transcriptDescendant(in: hosting))
        await transcriptHost.waitForProjectionForTesting?()
        let projectionCount = try #require(
            transcriptHost.readDiagnosticsForTesting?().render.projectionCount
        )

        // The panel is already open and width-stable. Files and preview tabs
        // join the same topology; opening, activation, pinning, replacement,
        // close, and adapter availability changes must remain transcript-neutral.
        let reviewID = tabs.open(review, from: .summary)
        let originalReview = try #require(tabs.snapshot.instance(id: reviewID))
        let filesID = tabs.open(files, from: .commandMenu)
        let previewID = tabs.open(preview, from: .transcript)
        let previewContentID = try #require(tabs.snapshot.instance(id: previewID)?.contentID)
        tabs.interact(previewID)
        let replacementID = tabs.open(replacementPreview, from: .transcript)
        tabs.close(replacementID)

        for index in 0..<100 {
            if index == 50 {
                let refreshedReview = CodexReviewWorkspaceTabAdapter(
                    workspaceURL: URL(fileURLWithPath: "/tmp"),
                    session: CodexGitReviewSession(
                        snapshot: CodexGitReviewSnapshot(
                            revision: .init(sourceID: reviewSourceID, value: 8),
                            branchName: "main"
                        )
                    )
                )
                available = [plan, refreshedReview, files, preview, replacementPreview]
            }
            tabs.register(index.isMultiple(of: 4) ? [] : available)
            tabs.move(reviewID, to: index.isMultiple(of: 2) ? .bottom : .right)
            let handles: [CodexWorkspaceTabID] = [planID, reviewID, filesID, previewID]
            tabs.activate(handles[index % handles.count])
            if index.isMultiple(of: 7) { tabs.interact(previewID) }
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(1))
            if index.isMultiple(of: 10) { await Task.yield() }
        }
        let reconciledHost = try #require(transcriptDescendant(in: hosting))
        await reconciledHost.waitForProjectionForTesting?()

        #expect(reconciledHost === transcriptHost)
        #expect(tabs.snapshot.instance(id: previewID)?.contentID == previewContentID)
        #expect(tabs.snapshot.instance(id: reviewID)?.contentID == originalReview.contentID)
        #expect(tabs.snapshot.instance(id: reviewID)?.durableRoute == originalReview.durableRoute)
        #expect(tabs.registeredContentRevision(for: reviewID) == 8)
        #expect(
            reconciledHost.readDiagnosticsForTesting?().render.projectionCount
                == projectionCount
        )
    }

    @Test func hiddenFilePreviewEditorsAreNotMountedOrParsed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-file-tab-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "let first = 1\n".write(
            to: root.appendingPathComponent("First.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "let second = 2\n".write(
            to: root.appendingPathComponent("Second.swift"),
            atomically: true,
            encoding: .utf8
        )

        let tabs = CodexWorkspaceTabs()
        let first = tabs.open(
            CodexFilePreviewWorkspaceTabAdapter(
                fileURL: root.appendingPathComponent("First.swift")
            ),
            from: .transcript
        )
        tabs.interact(first)
        let second = tabs.open(
            CodexFilePreviewWorkspaceTabAdapter(
                fileURL: root.appendingPathComponent("Second.swift")
            ),
            from: .transcript
        )

        let hosting = NSHostingView(rootView: CodexAgentSidePanel(
            tabs: [],
            workspaceTabs: tabs,
            showsCloseButton: false,
            onClose: {}
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        let initialEditorCount = await waitForTextViews(in: hosting, window: window)

        #expect(tabs.snapshot.topology.right.activeTabID == second)
        #expect(tabs.snapshot.instance(id: first)?.contentID != tabs.snapshot.instance(id: second)?.contentID)
        #expect(initialEditorCount == 1)

        tabs.activate(first)
        hosting.layoutSubtreeIfNeeded()
        #expect(await waitForTextViews(in: hosting, window: window) == 1)
    }
}

@MainActor
private final class WorkspaceTabRenderHarnessModel: ObservableObject {
    let panel = CodexWorkspacePanelState()
    let presentationStore = CodexPresentationStore()
    let plan = CodexPlanSummary(
        steps: [TurnPlanStep(step: "Inspect", status: .inProgress)]
    )
    let review = CodexGitReviewSession(
        snapshot: CodexGitReviewSnapshot(branchName: "main")
    )
}

private struct WorkspaceTabRenderHarness: View {
    @ObservedObject var model: WorkspaceTabRenderHarnessModel
    @State private var draft = ""

    var body: some View {
        CodexChatWorkspaceView(
            presentationStore: model.presentationStore,
            workspacePath: "/tmp",
            panel: model.panel,
            workspaceSummary: CodexWorkspaceSummaryContext(
                workspacePath: "/tmp",
                plan: model.plan
            ),
            gitReviewSession: model.review,
            draft: $draft,
            isSending: false,
            canSend: false,
            onSend: {},
            onInterrupt: {},
            onDisconnect: {}
        )
    }
}

private struct WorkspaceTabObservationHarness: View {
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
private func transcriptDescendant(
    in root: NSView
) -> CodexTranscriptCollectionContainerView? {
    if let match = root as? CodexTranscriptCollectionContainerView { return match }
    for child in root.subviews {
        if let match = transcriptDescendant(in: child) { return match }
    }
    return nil
}

@MainActor
private func countTextViews(in root: NSView) -> Int {
    let own = root is NSTextView ? 1 : 0
    return own + root.subviews.reduce(into: 0) { count, child in
        count += countTextViews(in: child)
    }
}

@MainActor
private func waitForTextViews(in root: NSView, window: NSWindow) async -> Int {
    for _ in 0..<100 {
        _ = window
        root.layoutSubtreeIfNeeded()
        let count = countTextViews(in: root)
        if count > 0 { return count }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return countTextViews(in: root)
}
