import AppKit
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexTranscriptAppKitPerformanceTests {
    @Test func longThreadStreamingHarnessReportsFineGrainedWork() async throws {
        let turnCount = 217
        let date = Date(timeIntervalSince1970: 100)
        let turns = (0..<turnCount).map { index in
            CodexTurnV2(
                id: "turn-\(index)",
                userMessage: .init(id: "user-\(index)", text: "Question \(index)"),
                narrative: [.prose(.init(
                    id: "commentary-\(index)",
                    text: "Checked the implementation for turn \(index).",
                    isStreaming: false
                ))],
                finalAnswer: .init(
                    id: "final-\(index)",
                    text: "Answer \(index) with **stable Markdown**.",
                    isStreaming: index == turnCount - 1
                ),
                status: .done(durationMs: 100)
            )
        }
        var presentation = CodexThreadUIPresentation(
            threadID: "performance-thread",
            transcript: .init(turns: turns),
            rawScrollOffset: 12_000,
            isPinnedToBottom: false,
            presentedAtByTurnID: Dictionary(uniqueKeysWithValues: turns.map { ($0.id, date) })
        )
        let projector = CodexTranscriptRenderProjector()
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let initial = try await projector.project(presentation: presentation, availableWidth: 1_000, theme: theme)

        #expect(initial.orderedItemIDs.count == 1_085)
        #expect(initial.diagnostics.heightCacheMissCount == 1_085)

        var totalProjectionMilliseconds = 0.0
        var maximumProjectionMilliseconds = 0.0
        var totalChangedItems = 0
        var totalHeightMisses = 0
        var totalPreparedTextMisses = 0
        for _ in 0..<120 {
            presentation.transcript.turns[turnCount - 1].finalAnswer?.text.append("x")
            let snapshot = try await projector.project(
                presentation: presentation,
                availableWidth: 1_000,
                theme: theme
            )
            totalProjectionMilliseconds += snapshot.diagnostics.projectionDurationMilliseconds
            maximumProjectionMilliseconds = max(
                maximumProjectionMilliseconds,
                snapshot.diagnostics.projectionDurationMilliseconds
            )
            totalChangedItems += snapshot.changedItemIDs.count
            totalHeightMisses += snapshot.diagnostics.heightCacheMissCount
            totalPreparedTextMisses += snapshot.diagnostics.preparedTextCacheMissCount
            #expect(snapshot.orderedItemIDs.count == 1_085)
            #expect(snapshot.changedItemIDs.count == 1)
        }

        let average = totalProjectionMilliseconds / 120
        let averageLabel = String(format: "%.3f", average)
        let maximumLabel = String(format: "%.3f", maximumProjectionMilliseconds)
        print(
            "APPKIT_TRANSCRIPT_PERF items=1085 frames=120 changed=\(totalChangedItems) "
                + "height_misses=\(totalHeightMisses) prepared_misses=\(totalPreparedTextMisses) "
                + "avg_ms=\(averageLabel) max_ms=\(maximumLabel)"
        )
        #expect(totalChangedItems == 120)
        #expect(totalHeightMisses == 120)
        #expect(totalPreparedTextMisses == 120)
    }
}
