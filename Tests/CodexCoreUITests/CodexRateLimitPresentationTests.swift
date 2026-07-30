@testable import CodexCoreUI
import CodexCore
import Foundation
import Testing

struct CodexRateLimitPresentationTests {
    @Test func weeklyWindowUsesReadableHonestFallbackCopy() {
        let snapshot = CodexSchemaRateLimitSnapshot(
            primary: .init(
                usedPercent: 85,
                windowDurationMins: 10_080
            )
        )

        #expect(
            CodexRateLimitPresentation.bannerMessage(for: snapshot)
                == "Rate limit 85% used · 7-day window"
        )
    }

    @Test func resetTimestampTakesPriorityOverWindowLength() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = CodexSchemaRateLimitSnapshot(
            primary: .init(
                resetsAt: Int(now.timeIntervalSince1970 + 3_600),
                usedPercent: 92,
                windowDurationMins: 10_080
            )
        )

        let message = CodexRateLimitPresentation.bannerMessage(
            for: snapshot,
            now: now
        )

        #expect(message?.contains("resets at ") == true)
        #expect(message?.contains("10080m") == false)
        #expect(message?.contains("7-day window") == false)
    }

    @Test func commonWindowDurationsUseNaturalUnits() {
        #expect(CodexRateLimitWindowText.durationLabel(minutes: 300) == "5-hour window")
        #expect(CodexRateLimitWindowText.durationLabel(minutes: 1_440) == "1-day window")
        #expect(CodexRateLimitWindowText.durationLabel(minutes: 90) == "90-minute window")
    }

    @Test func statusPanelUsesTheSameReadableWindowCopy() {
        let context = CodexChatStatusSummaryContext(
            connectionLabel: "Connected",
            workspacePath: "/tmp/project",
            currentThreadID: "thread",
            modelDisplayName: "Codex",
            reasoningDisplayName: "Medium",
            approvalDisplayName: "Ask",
            messageCount: 0,
            isSideChatOpen: false,
            activeSubagentCount: 0,
            subagentCount: 0
        )
        let snapshot = CodexSchemaRateLimitSnapshot(
            primary: .init(
                usedPercent: 85,
                windowDurationMins: 10_080
            )
        )

        let model = CodexStatusPanelModel(context: context, rateLimits: snapshot)

        #expect(model.rateLimitRows.first?.resetLabel == "7-day window")
    }
}
