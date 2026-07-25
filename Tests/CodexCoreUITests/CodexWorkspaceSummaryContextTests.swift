@testable import CodexCoreUI
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
    }
}
