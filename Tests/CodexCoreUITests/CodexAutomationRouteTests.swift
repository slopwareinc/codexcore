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

    func testTemplatesUsePrefilledChatPrompts() {
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
        XCTAssertTrue(CodexAutomationTemplate.weeklyReview.isDraftBacked)
        XCTAssertTrue(CodexAutomationTemplate.projectMonitor.isDraftBacked)
    }

    func testRouteStateExposesCurrentAppEmptyTemplateSurface() {
        let state = CodexAutomationRouteState()

        XCTAssertEqual(state.headerTitle, "Automations")
        XCTAssertEqual(state.description, "Run chats on a schedule or whenever you need them.")
        XCTAssertEqual(state.learnMoreTitle, "Learn more")
        XCTAssertEqual(state.emptyTitle, "Create your first automation")
        XCTAssertEqual(state.newAutomationOptionsTitle, "New automation")
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

    func testEveryTemplateTransitionsToAnUnsentDraft() {
        var session = CodexAutomationRouteSession()

        let dailyBrief = session.perform(.template(.dailyBrief))
        let weeklyReview = session.perform(.template(.weeklyReview))

        XCTAssertEqual(dailyBrief?.prompt, "Set up an automation that gives me a morning brief each weekday; what's on my calendar, important unread emails, and anything that needs my attention today.")
        XCTAssertEqual(dailyBrief?.activityDetail, "Prepared Daily brief")
        XCTAssertEqual(dailyBrief?.startsNewChat, true)
        XCTAssertTrue(weeklyReview?.prompt.contains("weekly review automation") == true)
        XCTAssertEqual(session.lastDraftRequest, weeklyReview)
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

    func testLifecycleEnablesRunsAndAdvancesSchedule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var automation = CodexAutomation(
            id: "morning",
            name: "Morning brief",
            prompt: "Summarize priorities",
            schedule: CodexAutomationSchedule(frequency: .daily, hour: 9),
            createdAt: now
        )
        automation.nextRunAt = now
        var lifecycle = CodexAutomationLifecycle(automations: [automation])

        XCTAssertEqual(lifecycle.due(at: now).map(\.id), ["morning"])
        XCTAssertEqual(lifecycle.beginRun(id: "morning", now: now)?.status, .running)
        XCTAssertTrue(lifecycle.due(at: now).isEmpty)

        lifecycle.finishRun(id: "morning", threadID: "thread-1", error: nil, now: now)
        XCTAssertEqual(lifecycle.automations[0].status, .enabled)
        XCTAssertEqual(lifecycle.automations[0].targetThreadID, "thread-1")
        XCTAssertNotNil(lifecycle.automations[0].nextRunAt)
    }

    func testWeekdayScheduleCanRunLaterTheSameBusinessDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let mondayAtEight = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2027, month: 1, day: 4, hour: 8
        )))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2027, month: 1, day: 4, hour: 9
        )))

        let next = CodexAutomationSchedule(frequency: .weekdays, hour: 9)
            .nextDate(after: mondayAtEight, calendar: calendar)

        XCTAssertEqual(next, expected)
    }

    func testToggleAndEditLifecyclePreserveIdentity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let automation = CodexAutomation(id: "weekly", name: "Review", prompt: "Review work", createdAt: now)
        var lifecycle = CodexAutomationLifecycle(automations: [automation])

        XCTAssertEqual(lifecycle.toggle(id: "weekly", now: now)?.status, .disabled)
        XCTAssertNil(lifecycle.automations[0].nextRunAt)
        XCTAssertEqual(lifecycle.toggle(id: "weekly", now: now)?.status, .enabled)

        var edited = lifecycle.automations[0]
        edited.name = "Friday review"
        lifecycle.save(edited, now: now)
        XCTAssertEqual(lifecycle.automations.map(\.id), ["weekly"])
        XCTAssertEqual(lifecycle.automations[0].name, "Friday review")
    }

    func testLifecycleRecoversInterruptedRunAfterRelaunch() {
        let automation = CodexAutomation(
            id: "interrupted",
            name: "Interrupted",
            prompt: "Continue",
            status: .running
        )

        let lifecycle = CodexAutomationLifecycle(automations: [automation])

        XCTAssertEqual(lifecycle.automations[0].status, .enabled)
        XCTAssertNotNil(lifecycle.automations[0].nextRunAt)
    }

    func testLifecycleInitializationPreservesDuplicateIDsAndChronologicalOrder() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        let laterDuplicate = CodexAutomation(
            id: "duplicate",
            name: "Later duplicate",
            prompt: "Run later",
            status: .running,
            createdAt: newer
        )
        let earlierDuplicate = CodexAutomation(
            id: "duplicate",
            name: "Earlier duplicate",
            prompt: "Run earlier",
            createdAt: older
        )

        let lifecycle = CodexAutomationLifecycle(automations: [laterDuplicate, earlierDuplicate])

        XCTAssertEqual(lifecycle.automations.map(\.id), ["duplicate", "duplicate"])
        XCTAssertEqual(lifecycle.automations.map(\.name), ["Earlier duplicate", "Later duplicate"])
        XCTAssertEqual(lifecycle.automations.map(\.status), [.enabled, .enabled])
        XCTAssertEqual(lifecycle.automations.map(\.createdAt), [older, newer])
    }

    func testFileStoreRoundTripsOfficialAutomationFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexAutomationFileStore(directoryURL: directory)
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let automation = CodexAutomation(
            id: "daily-brief",
            name: "Daily brief",
            prompt: "Summarize \"important\" work\nand blockers",
            schedule: CodexAutomationSchedule(frequency: .weekdays, hour: 8, minute: 30),
            targetThreadID: "thread-123",
            createdAt: createdAt
        )

        try store.save(automation)

        XCTAssertEqual(store.load(), [automation])
        let toml = try String(
            contentsOf: directory.appendingPathComponent("daily-brief/automation.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(toml.contains("kind = \"heartbeat\""))
        XCTAssertTrue(toml.contains("status = \"ACTIVE\""))
        let timestampLines = toml.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("created_at = ") || $0.hasPrefix("updated_at = ") }
        XCTAssertEqual(timestampLines.count, 2)
        XCTAssertTrue(timestampLines.allSatisfy { line in
            guard let value = line.split(separator: "=", maxSplits: 1).last else { return false }
            return Int(value.trimmingCharacters(in: .whitespaces)) != nil
        })
        XCTAssertFalse(toml.contains("last_run_at"))
        XCTAssertFalse(toml.contains("next_run_at"))
        XCTAssertFalse(toml.contains("last_error"))
        XCTAssertTrue(toml.contains("rrule = \"FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=8;BYMINUTE=30\""))
        XCTAssertTrue(toml.contains("target_thread_id = \"thread-123\""))
    }
}
