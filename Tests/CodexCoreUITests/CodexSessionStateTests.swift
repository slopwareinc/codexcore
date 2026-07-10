import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexSessionStateTests: XCTestCase {
    func testAccountMenuSummaryPrefersTokenDisplayName() {
        let summary = CodexAccountMenuSummary(
            account: Account(type: "chatgpt", email: "pranjal.paliwal@example.com", planType: "pro"),
            displayName: "Pranjal Paliwal",
            serverName: "Codex"
        )

        XCTAssertEqual(summary.displayName, "Pranjal Paliwal")
        XCTAssertEqual(summary.detail, "Pro")
        XCTAssertEqual(summary.initials, "PP")
    }

    func testAccountMenuSummaryFallsBackToEmailWhenTokenNameIsMissing() {
        let summary = CodexAccountMenuSummary(
            account: Account(type: "chatgpt", email: "pranjal.paliwal@example.com", planType: "pro"),
            serverName: "Codex"
        )

        XCTAssertEqual(summary.displayName, "Pranjal Paliwal")
        XCTAssertEqual(summary.detail, "Pro")
        XCTAssertEqual(summary.initials, "PP")
    }

    func testAccountMenuSummaryFormatsUnavailableAccount() {
        let fallback = CodexAccountMenuSummary(account: nil, serverName: "Codex")
        XCTAssertEqual(fallback.displayName, "Codex")
        XCTAssertEqual(fallback.detail, "Available")
    }

    func testAccountDetailLogPrintsServerAccountResponseJSON() {
        let json = CodexAccountDetailLog.json(from: GetAccountResponse(
            account: Account(type: "chatgpt", email: "pranjal.paliwal@example.com", planType: "plus"),
            requiresOpenAIAuth: false
        ))

        XCTAssertEqual(
            json,
            #"{"account":{"email":"pranjal.paliwal@example.com","planType":"plus","type":"chatgpt"},"requiresOpenaiAuth":false}"#
        )
    }

    func testAuthSessionOwnsConnectionAuthenticationAndDeviceCodeState() {
        var session = CodexAuthSession()

        XCTAssertTrue(session.beginConnecting())
        XCTAssertFalse(session.beginConnecting())
        session.connectedAfterHandshake(server: "Codex")
        XCTAssertTrue(session.isConnected)
        XCTAssertEqual(session.serverName, "Codex")

        let signedIn = session.applyAccount(GetAccountResponse(
            account: Account(type: "chatgpt", email: "dev@example.com", planType: nil),
            requiresOpenAIAuth: true
        ))
        XCTAssertTrue(signedIn.shouldContinue)
        XCTAssertEqual(signedIn.activity?.title, "Signed in")
        XCTAssertEqual(session.authLabel, "chatgpt · dev@example.com")
        XCTAssertTrue(session.isAuthenticated)

        let required = session.applyAccount(GetAccountResponse(account: nil, requiresOpenAIAuth: true))
        XCTAssertFalse(required.shouldContinue)
        XCTAssertEqual(required.activity?.title, "Authentication required")
        XCTAssertEqual(session.authLabel, "Sign-in required")
        XCTAssertFalse(session.isAuthenticated)

        let skipped = session.accountCheckSkipped(message: "offline")
        XCTAssertEqual(skipped.title, "Account check skipped")
        XCTAssertEqual(session.authLabel, "Account check skipped")

        let apiKey = session.apiKeyAccepted()
        XCTAssertEqual(apiKey.title, "API key accepted")
        XCTAssertEqual(session.authLabel, "OpenAI API key")
        XCTAssertTrue(session.isAuthenticated)

        let started = session.deviceCodeStarted(url: "https://example.com/device", code: "ABCD-EFGH")
        XCTAssertEqual(started.detail, "Code ABCD-EFGH")
        XCTAssertEqual(session.deviceCodeURL, "https://example.com/device")
        XCTAssertEqual(session.deviceCode, "ABCD-EFGH")

        let completed = session.deviceCodeCompleted()
        XCTAssertEqual(completed.title, "Signed in with ChatGPT")
        XCTAssertEqual(session.authLabel, "ChatGPT")
        XCTAssertNil(session.deviceCodeURL)
        XCTAssertNil(session.deviceCode)

        let failed = session.connectionFailed(message: "no server")
        XCTAssertEqual(failed.title, "Connection failed")
        XCTAssertEqual(session.connectionErrorMessage, "no server")

        session.resetAuthentication()
        XCTAssertEqual(session.authLabel, "Checking auth")
        XCTAssertTrue(session.isAuthenticated)
    }

    func testComposerStateSessionScopesDraftByActiveThread() throws {
        var session = CodexComposerStateSession()

        session.setActiveThreadID("thread-a")
        session.draft = "Draft A"

        session.setActiveThreadID("thread-b")
        XCTAssertEqual(session.draft, "")
        session.draft = "Draft B"

        XCTAssertEqual(session.draft(for: "thread-a"), "Draft A")
        XCTAssertEqual(session.draft(for: "thread-b"), "Draft B")

        let submission = try XCTUnwrap(session.consumeDraftForTurn())
        XCTAssertEqual(submission.prompt, "Draft B")
        XCTAssertEqual(session.draft(for: "thread-b"), "")
        XCTAssertEqual(session.draft(for: "thread-a"), "Draft A")

        session.setActiveThreadID("thread-a")
        XCTAssertEqual(session.draft, "Draft A")
        session.clearDraft()
        XCTAssertEqual(session.draft(for: "thread-a"), "")
    }

    func testComposerStateSessionOwnsDraftSkillsMentionsAndFollowUps() throws {
        let skill = CodexSlashCommand(
            id: "skill:thermo",
            title: "Thermo Review",
            detail: "Strict review",
            systemImage: "hammer",
            section: "Skills",
            draftText: "Review this",
            skillName: "thermo-nuclear-code-quality-review",
            skillPath: "/skills/thermo/SKILL.md"
        )
        let mention = FuzzyFileSearchResult(
            fileName: "Store.swift",
            matchType: .file,
            path: "Sources/CodexCore/Store/Store.swift",
            root: "/repo",
            score: 0.9
        )

        var session = CodexComposerStateSession(draft: "  Inspect @Store.swift  ", sideChatDraft: "  side branch  ")
        session.attachSkill(skill)
        session.attachSkill(skill)
        XCTAssertEqual(session.attachedSkills, [skill])
        XCTAssertEqual(session.draft, "Review this")

        session.draft = "  Inspect @Store.swift  "
        session.setMentionResults([mention])
        session.selectMention(mention)

        let submission = try XCTUnwrap(session.consumeDraftForTurn())
        XCTAssertEqual(submission.prompt, "Inspect @Store.swift")
        XCTAssertEqual(submission.skills, [skill])
        XCTAssertEqual(submission.mentions, [.mention(name: "Store.swift", path: "/repo/Sources/CodexCore/Store/Store.swift")])
        XCTAssertEqual(submission.turnInput, [
            .skill(name: "thermo-nuclear-code-quality-review", path: "/skills/thermo/SKILL.md"),
            .mention(name: "Store.swift", path: "/repo/Sources/CodexCore/Store/Store.swift"),
            .text("Inspect @Store.swift")
        ])
        XCTAssertEqual(session.draft, "")
        XCTAssertEqual(session.sideChatDraft, "  side branch  ")
        XCTAssertEqual(session.attachedSkills, [])
        XCTAssertEqual(session.mentionResults, [])

        XCTAssertEqual(session.trimmedSideChatDraft, "side branch")
        session.clearSideChatDraft()
        XCTAssertEqual(session.sideChatDraft, "")

        session.restore(submission)
        XCTAssertEqual(session.draft, "Inspect @Store.swift")
        XCTAssertEqual(session.attachedSkills, [skill])

        session.enqueueFollowUp("first")
        session.enqueueFollowUp("second")
        XCTAssertEqual(session.followUpHint(isSending: false, canSendFollowUp: false), "2 queued")
        XCTAssertNil(session.dequeueQueuedFollowUp(isSending: true))
        XCTAssertEqual(session.dequeueQueuedFollowUp(isSending: false), "first")
        session.requeueFollowUp("retry")
        XCTAssertEqual(session.dequeueQueuedFollowUp(isSending: false), "retry")

        let skillRoute = session.routeSlashCommand(skill)
        XCTAssertEqual(skillRoute.activities.map(\.title), ["Skill attached"])
        XCTAssertEqual(skillRoute.activities.map(\.detail), ["Thermo Review"])
        XCTAssertEqual(skillRoute.hostActions, [])
        XCTAssertEqual(session.attachedSkills, [skill])
        XCTAssertEqual(session.draft, "Review this")

        let sideRoute = session.routeSlashCommand(CodexSlashCommand(
            id: "side",
            title: "Side Chat",
            detail: "Open a side chat",
            systemImage: "sidebar.right"
        ))
        XCTAssertEqual(sideRoute.hostActions, [.openSideChat])
        XCTAssertEqual(session.draft, "")

        let mcpRoute = session.routeSlashCommand(CodexSlashCommand(
            id: "mcp",
            title: "MCP",
            detail: "Inspect configured MCP servers",
            systemImage: "server.rack"
        ))
        XCTAssertEqual(mcpRoute.hostActions, [.refreshMCPServers])

        session.draft = "/model"
        let modelRoute = session.routeSlashCommand(CodexSlashCommand(
            id: "model",
            title: "Model",
            detail: "Change model",
            systemImage: "sparkles"
        ))
        XCTAssertEqual(modelRoute.hostActions, [.openModelSelector])
        XCTAssertEqual(session.draft, "")

        session.draft = "/reasoning"
        let reasoningRoute = session.routeSlashCommand(CodexSlashCommand(
            id: "reasoning",
            title: "Reasoning",
            detail: "Change reasoning effort",
            systemImage: "brain"
        ))
        XCTAssertEqual(reasoningRoute.hostActions, [.openReasoningSelector])
        XCTAssertEqual(session.draft, "")

        let draftRoute = session.routeSlashCommand(CodexSlashCommand(
            id: "feedback",
            title: "Feedback",
            detail: "Send feedback",
            systemImage: "bubble.left",
            draftText: "I have feedback: "
        ))
        XCTAssertEqual(draftRoute.activities.map(\.detail), ["Prepared Feedback"])
        XCTAssertEqual(session.draft, "I have feedback: ")
    }

    func testActivityLogSessionOwnsClippingOrderingAndCapacity() {
        var log = CodexActivityLogSession(limit: 2, detailLimit: 12)

        log.append(.notice, title: "First", detail: "  short\nline  ")
        log.append(.turn, title: "Second", detail: "123456789012345")
        log.append(CodexActivity(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            kind: .tool,
            title: "Third",
            detail: "kept",
            createdAt: Date(timeIntervalSince1970: 3)
        ))

        XCTAssertEqual(log.activities.map(\.title), ["Third", "Second"])
        XCTAssertEqual(log.activities.map(\.detail), ["kept", "123456789012…"])
        XCTAssertEqual(log.clippedDetail("  one\ntwo  "), "one two")
    }

}
