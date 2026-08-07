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

    @Test func outputSummariesAreDerivedOnlyFromCanonicalTranscriptOutputs() {
        let turn = CodexTurnV2(
            id: "turn-1",
            narrative: [
                .workGroup(CodexWorkGroupV2(
                    id: "work-1",
                    rows: [
                        .fileChange(CodexFileChangeRowV2(
                            id: "change-1",
                            files: ["Sources/App.swift"],
                            status: .completed
                        )),
                        .command(CodexCommandRowV2(
                            id: "command-1",
                            command: "swift test",
                            label: "Ran swift test",
                            action: .run,
                            status: .completed,
                            output: "2 tests passed\nall good"
                        )),
                    ],
                    isLive: false
                ))
            ],
            generatedImages: [
                CodexGeneratedImageV2(id: "image-1", source: "/tmp/result.png")
            ],
            status: .done(durationMs: 100)
        )
        let presentation = CodexCanonicalTranscriptPresentation(
            threadID: "thread-1",
            sourceRevision: .init(3),
            turnOrder: ["turn-1"],
            turnsByID: ["turn-1": turn]
        )

        #expect(presentation.outputSummaries.map(\.kind) == [
            .fileChange,
            .commandOutput,
            .generatedImage,
        ])
        #expect(presentation.outputSummaries.map(\.title) == [
            "Edited Sources/App.swift",
            "Ran swift test",
            "Generated result.png",
        ])
        #expect(presentation.outputSummaries[1].detail == "2 tests passed")
    }

    @Test func outputSummariesDoNotInventRowsForActivityWithoutOutputPayload() {
        let turn = CodexTurnV2(
            id: "turn-1",
            narrative: [
                .workGroup(CodexWorkGroupV2(
                    id: "work-1",
                    rows: [
                        .command(CodexCommandRowV2(
                            id: "command-1",
                            command: "pwd",
                            label: "Ran pwd",
                            action: .run,
                            status: .completed
                        ))
                    ],
                    isLive: false
                ))
            ],
            status: .done(durationMs: 20)
        )
        let presentation = CodexCanonicalTranscriptPresentation(
            threadID: "thread-1",
            sourceRevision: .init(4),
            turnOrder: ["turn-1"],
            turnsByID: ["turn-1": turn]
        )

        #expect(presentation.outputSummaries.isEmpty)
    }
}
