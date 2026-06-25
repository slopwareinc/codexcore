import XCTest
@testable import CodexCoreUI

final class CodexAutomationRouteTests: XCTestCase {
    func testCreateViaChatActionUsesCapturedAutomationPrompt() {
        let action = CodexAutomationRouteAction.createViaChat

        XCTAssertEqual(action.title, "Create via chat")
        XCTAssertEqual(action.draftPrompt, "I want to set up an automation. Briefly explain how automations work in Codex, then ask me a few questions to figure out what I'd like Codex to do and when it should run")
        XCTAssertEqual(action.draftRequest, CodexAutomationDraftRequest(
            prompt: "I want to set up an automation. Briefly explain how automations work in Codex, then ask me a few questions to figure out what I'd like Codex to do and when it should run",
            activityTitle: "Automation draft",
            activityDetail: "Prepared automation chat",
            startsNewChat: true
        ))
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

    func testRouteStateExposesCurrentAppEmptyTemplateSurface() {
        let state = CodexAutomationRouteState()

        XCTAssertEqual(state.headerTitle, "Automations")
        XCTAssertEqual(state.description, "Run chats on a schedule or whenever you need them.")
        XCTAssertEqual(state.learnMoreTitle, "Learn more")
        XCTAssertEqual(state.emptyTitle, "Create your first automation")
        XCTAssertEqual(state.newAutomationOptionsTitle, "New automation options")
        XCTAssertEqual(state.selectedModeTitle, "View templates")
        XCTAssertTrue(state.showsEmptyState)
        XCTAssertEqual(state.templates.map(\.title), ["Daily brief", "Weekly review", "Project monitor"])
    }

    func testRouteSessionTransitionsCreateViaChatToUnsentDraftRequest() {
        var session = CodexAutomationRouteSession()

        let request = session.perform(.createViaChat)

        XCTAssertEqual(session.state.mode, .createViaChat)
        XCTAssertEqual(request?.prompt, CodexAutomationRouteAction.createViaChatPrompt)
        XCTAssertEqual(request?.activityDetail, "Prepared automation chat")
        XCTAssertEqual(request?.startsNewChat, true)

        session.viewTemplates()

        XCTAssertEqual(session.state.mode, .viewTemplates)
        XCTAssertNil(session.lastDraftRequest)
    }

    func testTemplateDraftTransitionsOnlyForBackedTemplates() {
        var session = CodexAutomationRouteSession()

        let dailyBrief = session.perform(.template(.dailyBrief))
        let weeklyReview = session.perform(.template(.weeklyReview))

        XCTAssertEqual(dailyBrief?.prompt, "Set up an automation that gives me a morning brief each weekday; what's on my calendar, important unread emails, and anything that needs my attention today.")
        XCTAssertEqual(dailyBrief?.activityDetail, "Prepared Daily brief")
        XCTAssertEqual(dailyBrief?.startsNewChat, true)
        XCTAssertNil(weeklyReview)
        XCTAssertNil(session.lastDraftRequest)
    }

    func testAddAutomationChatActionUsesSameDraftFlowWithoutStartingNewChat() {
        let request = CodexAutomationRouteAction.addForChat(
            threadID: "thread-123",
            threadTitle: "Plan launch",
            workspacePath: "/tmp/CodexCore"
        ).draftRequest

        XCTAssertEqual(
            request?.prompt,
            "I want to set up an automation for the current chat \"Plan launch\" (thread-123) in /tmp/CodexCore. Ask me what should trigger it, what Codex should do, and how often it should run before changing any settings."
        )
        XCTAssertEqual(request?.activityDetail, "Prepared automation draft for Plan launch")
        XCTAssertEqual(request?.startsNewChat, false)
    }
}
