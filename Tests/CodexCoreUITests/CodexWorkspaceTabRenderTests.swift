import AppKit
import CodexCore
import SwiftUI
import Testing
@testable import CodexCoreUI

@MainActor
struct CodexWorkspaceTabRenderTests {
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
        let store = CodexPresentationStore()
        let container = CodexTranscriptCollectionContainerView(
            frame: NSRect(x: 0, y: 0, width: 860, height: 600)
        )
        let coordinator = CodexTranscriptListHost.Coordinator()
        coordinator.attach(to: container)
        defer { coordinator.detach() }

        func reconcile() {
            coordinator.update(
                presentation: presentation,
                renderUpdate: renderUpdate,
                presentationStore: store,
                bottomContentInset: 170,
                contentHorizontalOffset: 0,
                swiftUITheme: .officialDark,
                colorScheme: .dark,
                clipboardService: CodexNoopClipboardService(),
                productToolRenderer: nil,
                onOpenSubagent: { _ in },
                onEditUserMessage: { _ in },
                onForkChat: nil
            )
        }

        reconcile()
        await coordinator.waitForProjectionForTesting()
        let projectionCount = coordinator.diagnostics.render.projectionCount
        let tabs = CodexWorkspaceTabs()
        let planID = tabs.open(
            CodexPlanWorkspaceTabAdapter(plan: CodexPlanSummary(steps: [])),
            from: .summary
        )
        let reviewID = tabs.open(
            CodexReviewWorkspaceTabAdapter(
                workspaceURL: URL(fileURLWithPath: "/tmp"),
                session: CodexGitReviewSession(
                    snapshot: CodexGitReviewSnapshot(branchName: "main")
                )
            ),
            from: .summary
        )

        for index in 0..<100 {
            tabs.activate(index.isMultiple(of: 2) ? planID : reviewID)
            reconcile()
        }
        await coordinator.waitForProjectionForTesting()

        #expect(coordinator.diagnostics.render.projectionCount == projectionCount)
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
