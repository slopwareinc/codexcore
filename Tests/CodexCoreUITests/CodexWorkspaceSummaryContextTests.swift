@testable import CodexCoreUI
import CodexCore
import Testing

struct CodexWorkspaceSummaryContextTests {
    @Test func summaryContextCarriesRecentSourcesForTheOverview() {
        let source = CodexReferencedFile(
            path: "/tmp/reference.png",
            displayName: "Reference"
        )
        let context = CodexWorkspaceSummaryContext(
            workspacePath: "/tmp/Project",
            gitBranch: "codex/sidebar",
            sourceFiles: [source]
        )

        #expect(context.workspaceLine == "Project · codex/sidebar")
        #expect(context.sourceFiles == [source])
    }

    @Test func summaryContextRecognizesCodexWorktreePaths() {
        let context = CodexWorkspaceSummaryContext(
            workspacePath: "/Users/person/.codex/worktrees/abc/Project"
        )

        #expect(context.environmentModeTitle == "Worktree")
        #expect(
            CodexProjectSidebarEnvironmentLabel.title(
                workspacePath: "/Users/person/Project-worktrees/ab12/feature/packages/web"
            ) == "Worktree"
        )
    }

    @Test func planSummaryReportsProgressWithoutOwningDiffState() {
        let plan = CodexPlanSummary(
            steps: [
                TurnPlanStep(step: "Inspect", status: .completed),
                TurnPlanStep(step: "Implement", status: .inProgress),
            ],
            explanation: "Review workbench"
        )

        let context = CodexWorkspaceSummaryContext(
            workspacePath: "/tmp/Project",
            turnDiff: "diff --git a/A b/A\n+change",
            plan: plan
        )

        #expect(context.plan?.progressLabel == "1/2")
        #expect(context.diffStatsLine == "+1 -0 across 1 file(s)")
    }

    @Test func summaryContextCarriesServerOwnedBackgroundTerminals() {
        let state = CanonicalBackgroundTerminalState(
            threadID: "thread-1",
            terminals: [CanonicalBackgroundTerminal(
                processID: "process-1",
                command: "/bin/zsh -lc 'swift test'",
                cwd: .string("/tmp/Project"),
                itemID: "item-1"
            )],
            nextCursor: "next"
        )
        let context = CodexWorkspaceSummaryContext(
            workspacePath: "/tmp/Project",
            backgroundTerminals: state
        )

        #expect(context.backgroundTerminals?.terminals.map(\.processID) == ["process-1"])
        #expect(context.backgroundTerminals?.nextCursor == "next")
    }

    @Test func diffStatsLineCountsChangesAcrossMultipleFilesWithoutHeaders() {
        let context = CodexWorkspaceSummaryContext(
            workspacePath: "/tmp/Project",
            turnDiff: """
            diff --git a/A.swift b/A.swift
            --- a/A.swift
            +++ b/A.swift
            @@ -1 +1,2 @@
            +added
            -removed

            diff --git a/B.swift b/B.swift
            --- a/B.swift
            +++ b/B.swift
            @@ -1 +1 @@
             unchanged
            """
        )

        #expect(context.diffStatsLine == "+1 -1 across 2 file(s)")
    }
}
