import XCTest
@testable import CodexCoreUI

final class CodexAutomationRouteTests: XCTestCase {
    func testCreateViaChatActionUsesCapturedAutomationPrompt() {
        let action = CodexAutomationRouteAction.createViaChat

        XCTAssertEqual(action.title, "Create via chat")
        XCTAssertEqual(action.draftPrompt, "I want to set up an automation. Briefly explain how automations work in Codex, then ask me a few questions to figure out what I'd like Codex to do and when it should run")
    }

    func testDailyBriefTemplateUsesCapturedPromptAndUnknownTemplatesStayUnbacked() {
        XCTAssertEqual(CodexAutomationTemplate.allCases.map(\.title), [
            "Daily brief",
            "Weekly review",
            "Project monitor"
        ])

        XCTAssertEqual(
            CodexAutomationRouteAction.template(.dailyBrief).draftPrompt,
            "Set up an automation that gives me a morning brief each weekday; what's on my calendar, important unread emails, and anything that needs my attention today."
        )
        XCTAssertTrue(CodexAutomationTemplate.dailyBrief.isDraftBacked)
        XCTAssertFalse(CodexAutomationTemplate.weeklyReview.isDraftBacked)
        XCTAssertFalse(CodexAutomationTemplate.projectMonitor.isDraftBacked)
    }
}
