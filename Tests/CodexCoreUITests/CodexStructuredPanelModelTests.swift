import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexStructuredPanelModelTests: XCTestCase {
    func testStatusPanelFormatsContextAndRateLimitWindows() throws {
        let model = CodexStatusPanelModel(
            context: CodexChatStatusSummaryContext(
                connectionLabel: "Connected",
                workspacePath: "/repo",
                currentThreadID: "thread-123",
                modelDisplayName: "GPT-5.5",
                reasoningDisplayName: "Medium",
                approvalDisplayName: "Full access",
                messageCount: 4,
                isSideChatOpen: false,
                activeSubagentCount: 0,
                subagentCount: 0,
                tokenUsageSummary: "12 / 100 tokens"
            ),
            rateLimits: CodexSchemaRateLimitSnapshot(
                primary: CodexSchemaRateLimitWindow(resetsAt: 1_801_234_567, usedPercent: 82, windowDurationMins: 300),
                secondary: CodexSchemaRateLimitWindow(usedPercent: 41, windowDurationMins: 10_080)
            )
        )

        XCTAssertEqual(model.sessionID, "thread-123")
        XCTAssertEqual(model.contextUsedLabel, "12 tokens used")
        XCTAssertEqual(model.contextLeftLabel, "88 tokens left")
        XCTAssertEqual(model.contextFraction, 0.12, accuracy: 0.001)
        XCTAssertEqual(model.rateLimitRows.map(\.title), ["5h limit", "7d limit"])
        XCTAssertEqual(model.rateLimitRows.map(\.usedLabel), ["82% used", "41% used"])
        XCTAssertEqual(model.rateLimitRows[0].resetLabel, "Resets at 1801234567")
        XCTAssertEqual(model.rateLimitRows[1].resetLabel, "Resets in 10080m window")
    }

    func testStatusPanelUsesFallbacksWhenContextAndRateLimitsAreMissing() {
        let model = CodexStatusPanelModel(
            context: CodexChatStatusSummaryContext(
                connectionLabel: "Disconnected",
                workspacePath: "/repo",
                currentThreadID: nil,
                modelDisplayName: "Default",
                reasoningDisplayName: "Medium",
                approvalDisplayName: "Ask",
                messageCount: 0,
                isSideChatOpen: false,
                activeSubagentCount: 0,
                subagentCount: 0
            ),
            rateLimits: nil
        )

        XCTAssertEqual(model.sessionID, "preparing")
        XCTAssertEqual(model.contextUsedLabel, "Context unavailable")
        XCTAssertEqual(model.contextLeftLabel, "Unknown left")
        XCTAssertEqual(model.contextFraction, 0)
        XCTAssertEqual(model.rateLimitRows.map(\.title), ["5h limit", "7d limit"])
        XCTAssertEqual(model.rateLimitRows.map(\.usedLabel), ["Usage unavailable", "Usage unavailable"])
    }

    func testMCPPanelFormatsEnabledAuthAndStartupLabels() throws {
        let model = CodexMCPStatusPanelModel(
            servers: [
                CodexMCPServerStatus(
                    name: "filesystem",
                    displayName: "Filesystem",
                    authStatus: "unsupported",
                    startupStatus: "ready",
                    tools: [.init(name: "read_file"), .init(name: "write_file")],
                    resources: [.init(name: "repo")]
                ),
                CodexMCPServerStatus(
                    name: "github",
                    displayName: "GitHub",
                    authStatus: "oAuth",
                    startupStatus: "disabled"
                )
            ],
            isLoading: false,
            errorMessage: nil
        )

        XCTAssertEqual(model.detail, "2 configured")
        XCTAssertEqual(model.rows[0].displayName, "Filesystem")
        XCTAssertEqual(model.rows[0].enabledLabel, "Enabled")
        XCTAssertEqual(model.rows[0].authLabel, "Auth unsupported")
        XCTAssertEqual(model.rows[0].startupLabel, "ready")
        XCTAssertEqual(model.rows[0].inventorySummary, "2 tools · 1 resource")
        XCTAssertEqual(model.rows[1].enabledLabel, "Disabled")
        XCTAssertEqual(model.rows[1].authLabel, "OAuth")
    }

    func testStructuredPanelNoticeRoundTripAndDismissalState() throws {
        let status = CodexStatusPanelModel(
            sessionID: "thread-123",
            connectionLabel: "Connected",
            contextUsedLabel: "10 tokens used",
            contextLeftLabel: "90 tokens left",
            contextFraction: 0.1,
            rateLimitRows: [CodexStatusPanelRateLimitRow(title: "5h limit", usedPercent: 10, resetLabel: "Resets soon")]
        )
        let parsedStatus = try XCTUnwrap(CodexStatusPanelModel(notice: status.notice()))
        XCTAssertEqual(parsedStatus, status)

        let mcp = CodexMCPStatusPanelModel(
            detail: "1 configured",
            rows: [CodexMCPStatusPanelServerRow(name: "filesystem", displayName: "Filesystem", enabledLabel: "Enabled", authLabel: "Auth unsupported", startupLabel: "ready", inventorySummary: "0 tools · 0 resources")]
        )
        let parsedMCP = try XCTUnwrap(CodexMCPStatusPanelModel(notice: mcp.notice()))
        XCTAssertEqual(parsedMCP, mcp)

        let messageID = UUID()
        var dismissal = CodexStructuredPanelDismissalState()
        XCTAssertTrue(dismissal.isVisible(messageID: messageID))
        dismissal.dismiss(messageID: messageID)
        XCTAssertFalse(dismissal.isVisible(messageID: messageID))
    }
}
