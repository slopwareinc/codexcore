import XCTest
import SwiftUI
@testable import CodexCore
@testable import CodexCoreUI

final class CodexAgentUITests: XCTestCase {
    func testAgentPanelStateBuildsSideChatAndSubagentTabs() {
        let fixture = AgentUIFixture.make()
        let panel = CodexAgentPanelState(
            isOpen: true,
            selectedTabID: fixture.subagents[0].id,
            sideChat: fixture.sideChat,
            subagents: fixture.subagents
        )

        XCTAssertTrue(panel.isOpen)
        XCTAssertEqual(panel.tabs.map(\.title), ["Side chat", "Chandrasekhar", "Copernicus"])
        XCTAssertEqual(panel.tabs[1].messages.last?.text, "Chat/composer findings")
        XCTAssertEqual(panel.tabs[2].messages.last?.text, "Side-panel findings")
    }

    func testLifecycleFixtureModelsClosedSubagentsWithoutRuntimeDemoCode() {
        let fixture = AgentUIFixture.make()

        XCTAssertEqual(fixture.lifecycleEvents.count, 2)
        XCTAssertEqual(fixture.lifecycleEvents[0].status, .spawning)
        XCTAssertEqual(fixture.lifecycleEvents[0].agentNames, ["Chandrasekhar", "Copernicus"])
        XCTAssertEqual(fixture.lifecycleEvents[1].status, .closed)
    }

    @MainActor
    func testThemePresetsExposeUserSelectableThemes() {
        XCTAssertEqual(CodexAgentThemePreset.allCases.map(\.displayName), [
            "Official Dark",
            "Native Light",
            "Midnight",
            "Warm Minimal",
            "High Contrast"
        ])

        for preset in CodexAgentThemePreset.allCases {
            let view = CodexChatWorkspaceView(
                messages: [],
                lifecycleEvents: [],
                sideChat: nil,
                subagents: [],
                activities: [],
                connectionState: .disconnected,
                workspacePath: "/tmp",
                draft: .constant(""),
                isSending: false,
                canSend: false,
                onSend: {},
                onInterrupt: {},
                onDisconnect: {}
            )
            .codexAgentTheme(preset.theme)

            withExtendedLifetime(view) {}
        }
    }

    func testOfficialDarkThemeTracksObservedCodexAppDesignInvariants() {
        let theme = CodexAgentTheme.officialDark

        XCTAssertEqual(theme.spacing.transcriptMaxWidth, 736)
        XCTAssertEqual(theme.spacing.composerMaxWidth, 736)
        XCTAssertEqual(theme.spacing.sidePanelWidth, 320)
        XCTAssertEqual(theme.spacing.summaryPanelWidth, 300)
        XCTAssertEqual(theme.spacing.toolbarHeight, 46)
        XCTAssertEqual(theme.radii.composer, 25)
        XCTAssertEqual(theme.radii.panel, 25)
        XCTAssertTrue(theme.effects.usesLiquidGlass)
        XCTAssertEqual(theme.effects.surfaceOpacity, 0.94)
    }

    func testChatUtilitySessionFormatsTranscriptWithCommandFallback() {
        let messages = [
            CodexChatMessage(role: .user, text: "  Build it  "),
            CodexChatMessage(
                role: .terminal,
                text: "   ",
                commandRun: .init(
                    itemID: "cmd-1",
                    command: "swift test",
                    output: "",
                    status: "completed",
                    isStreaming: false
                )
            )
        ]

        XCTAssertEqual(
            CodexChatUtilitySession.transcriptText(messages: messages),
            """
            You: Build it

            Terminal: swift test
            """
        )
    }

    func testChatUtilitySessionFormatsCopyActivityDetail() {
        XCTAssertEqual(CodexChatUtilitySession.copiedTranscriptActivityDetail(messageCount: 0), "No transcript text yet")
        XCTAssertEqual(CodexChatUtilitySession.copiedTranscriptActivityDetail(messageCount: 2), "2 messages copied")
    }

    func testChatUtilitySessionFormatsStatusSummary() {
        let summary = CodexChatUtilitySession.statusSummary(
            CodexChatStatusSummaryContext(
                connectionLabel: "Connected",
                workspacePath: "/tmp/project",
                currentThreadID: "thread-123",
                modelDisplayName: "GPT-5.1 Codex Max",
                reasoningDisplayName: "High",
                approvalDisplayName: "Ask for approval",
                messageCount: 7,
                isSideChatOpen: true,
                activeSubagentCount: 2,
                subagentCount: 3
            )
        )

        XCTAssertEqual(
            summary,
            """
            Connection: Connected
            Project: /tmp/project
            Chat: thread-123
            Model: GPT-5.1 Codex Max High
            Approval: Ask for approval
            Messages: 7
            Side chat: open
            Subagents: 2 active / 3 total
            """
        )
    }

    func testComposerSelectionsMapToTurnParameters() throws {
        XCTAssertEqual(CodexApprovalSelection.readOnly.displayName, "Read only")
        XCTAssertEqual(CodexApprovalSelection.readOnly.approvalMode, .denyAll)
        XCTAssertEqual(CodexApprovalSelection.readOnly.sandbox, .readOnly)
        XCTAssertEqual(CodexApprovalSelection.fullAccess.displayName, "Full access")
        XCTAssertEqual(CodexApprovalSelection.fullAccess.approvalMode, .autoReview)
        XCTAssertEqual(CodexApprovalSelection.fullAccess.sandbox, .fullAccess)
        XCTAssertEqual(CodexApprovalSelection.defaultOptions, [.askForApproval, .approveForMe, .fullAccess, .custom])
        XCTAssertEqual(CodexApprovalSelection.askForApproval.turnParameterOverrides, [
            "approvalPolicy": .string(AskForApproval.onRequest.rawValue),
            "approvalsReviewer": .string(ApprovalsReviewer.user.rawValue)
        ])

        XCTAssertNil(CodexModelSelection.appServerDefault.modelIdentifier)
        XCTAssertEqual(CodexModelSelection.defaultOptions, [.appServerDefault])
        XCTAssertEqual(CodexReasoningSelection.none.effort, .none)
        XCTAssertEqual(CodexReasoningSelection.minimal.effort, .minimal)
        XCTAssertEqual(CodexReasoningSelection.medium.effort, .medium)
        XCTAssertEqual(CodexReasoningSelection.extraHigh.effort, .xhigh)

        let response = try CodexJSONValue.dictionary([
            "data": .array([
                .dictionary([
                    "id": .string("gpt-5.1-codex-max"),
                    "model": .string("gpt-5.1-codex-max"),
                    "displayName": .string("GPT-5.1 Codex Max"),
                    "description": .string("Most capable Codex model"),
                    "isDefault": .bool(true),
                    "defaultReasoningEffort": .string("high"),
                    "supportedReasoningEfforts": .array([
                        .dictionary([
                            "reasoningEffort": .string("medium"),
                            "description": .string("Balanced reasoning")
                        ]),
                        .dictionary([
                            "reasoningEffort": .string("high"),
                            "description": .string("Deeper reasoning")
                        ]),
                        .dictionary([
                            "reasoningEffort": .string("xhigh"),
                            "description": .string("Max reasoning")
                        ])
                    ])
                ]),
                .dictionary([
                    "id": .string("speed"),
                    "model": .string("speed"),
                    "displayName": .string("Speed"),
                    "description": .string("Fast preset"),
                    "isDefault": .bool(false),
                    "defaultReasoningEffort": .string("minimal"),
                    "supportedReasoningEfforts": .array([
                        .dictionary([
                            "reasoningEffort": .string("none"),
                            "description": .string("No reasoning")
                        ]),
                        .dictionary([
                            "reasoningEffort": .string("minimal"),
                            "description": .string("Small reasoning budget")
                        ])
                    ])
                ])
            ])
        ]).decode(ModelListResponse.self)
        let options = CodexModelSelection.options(from: response)

        XCTAssertEqual(options.map(\.displayName), ["GPT-5.1 Codex Max", "Speed"])
        XCTAssertEqual(options.first?.modelIdentifier, "gpt-5.1-codex-max")
        XCTAssertEqual(options.first?.detail, "Most capable Codex model")
        XCTAssertTrue(options.first?.isDefault == true)
        XCTAssertEqual(options.first?.defaultReasoning, .high)
        XCTAssertEqual(options.first?.supportedReasoning, [.medium, .high, .extraHigh])
        XCTAssertEqual(options.last?.defaultReasoning, .minimal)
        XCTAssertEqual(options.last?.supportedReasoning, [.none, .minimal])
    }

    func testTurnLaunchConfigurationOwnsSharedTurnParameters() {
        let configuration = CodexTurnLaunchConfiguration(
            approvalMode: .autoReview,
            cwd: "/tmp/project",
            effort: .high,
            modelIdentifier: "gpt-5.1-codex-max",
            sandbox: .workspaceWrite,
            parameters: [
                "approvalPolicy": .string("on-request"),
                "collaborationMode": .string("plan")
            ]
        )

        XCTAssertEqual(configuration.approvalMode, ApprovalMode.autoReview)
        XCTAssertEqual(configuration.cwd, "/tmp/project")
        XCTAssertEqual(configuration.effort, ReasoningEffort.high)
        XCTAssertEqual(configuration.modelIdentifier, "gpt-5.1-codex-max")
        XCTAssertEqual(configuration.sandbox, Sandbox.workspaceWrite)
        XCTAssertEqual(configuration.parameters["approvalPolicy"], CodexJSONValue.string("on-request"))
        XCTAssertEqual(configuration.parameters["collaborationMode"], CodexJSONValue.string("plan"))
    }

    func testTurnSubmissionSessionOwnsDraftRoutingPolicy() throws {
        var turnComposer = CodexComposerStateSession(draft: "  Build it  ")
        XCTAssertEqual(
            CodexTurnSubmissionSession.consumeDraft(
                composerSession: &turnComposer,
                canSendFollowUp: false,
                isGoalPursuitEnabled: false
            ),
            .turn(CodexComposerSubmission(prompt: "Build it"))
        )
        XCTAssertEqual(turnComposer.draft, "")

        var goalComposer = CodexComposerStateSession(draft: "  Keep going overnight  ")
        XCTAssertEqual(
            CodexTurnSubmissionSession.consumeDraft(
                composerSession: &goalComposer,
                canSendFollowUp: false,
                isGoalPursuitEnabled: true
            ),
            .goal(CodexComposerSubmission(prompt: "Keep going overnight"))
        )
        XCTAssertEqual(goalComposer.draft, "")

        var followUpComposer = CodexComposerStateSession(draft: "  Actually inspect Store.swift  ")
        XCTAssertEqual(
            CodexTurnSubmissionSession.consumeDraft(
                composerSession: &followUpComposer,
                canSendFollowUp: true,
                isGoalPursuitEnabled: true
            ),
            .followUp("Actually inspect Store.swift")
        )
        XCTAssertEqual(followUpComposer.draft, "")

        var emptyComposer = CodexComposerStateSession(draft: "   ")
        XCTAssertEqual(
            CodexTurnSubmissionSession.consumeDraft(
                composerSession: &emptyComposer,
                canSendFollowUp: true,
                isGoalPursuitEnabled: true
            ),
            .none
        )
    }

    func testTurnSubmissionSessionOwnsFollowUpQueueAndSteerPolicy() {
        var queueComposer = CodexComposerStateSession()
        var queueChat = CodexMainChatSession()
        let queued = CodexTurnSubmissionSession.prepareFollowUp(
            prompt: "Inspect Store.swift",
            composerSession: &queueComposer,
            mainChatSession: &queueChat,
            followUpBehavior: .queue,
            canSteer: true
        )

        guard case .queued(let queuedPrompt, let queuedActivity) = queued else {
            return XCTFail("Expected queued follow-up")
        }
        XCTAssertEqual(queuedPrompt, "Inspect Store.swift")
        XCTAssertEqual(queuedActivity.kind, .turn)
        XCTAssertEqual(queuedActivity.title, "Follow-up queued")
        XCTAssertEqual(queuedActivity.detail, "Inspect Store.swift")
        XCTAssertEqual(queueComposer.queuedFollowUps, ["Inspect Store.swift"])
        XCTAssertEqual(queueChat.messages.last?.detail, "Queued")

        var steerComposer = CodexComposerStateSession()
        var steerChat = CodexMainChatSession()
        let steered = CodexTurnSubmissionSession.prepareFollowUp(
            prompt: "Use the new projection",
            composerSession: &steerComposer,
            mainChatSession: &steerChat,
            followUpBehavior: .steer,
            canSteer: true
        )

        guard case .steer(let steeredPrompt, let steeredActivity) = steered else {
            return XCTFail("Expected steered follow-up")
        }
        XCTAssertEqual(steeredPrompt, "Use the new projection")
        XCTAssertEqual(steeredActivity.kind, .turn)
        XCTAssertEqual(steeredActivity.title, "Steering turn")
        XCTAssertEqual(steeredActivity.detail, "Use the new projection")
        XCTAssertEqual(steerComposer.queuedFollowUps, [])
        XCTAssertEqual(steerChat.messages.last?.detail, "Steered")

        let failed = CodexTurnSubmissionSession.failSteeredFollowUp(
            prompt: "Use the new projection",
            message: "turn already completed",
            composerSession: &steerComposer
        )
        XCTAssertEqual(failed.kind, .turn)
        XCTAssertEqual(failed.title, "Steer failed — queued instead")
        XCTAssertEqual(failed.detail, "turn already completed")
        XCTAssertEqual(steerComposer.queuedFollowUps, ["Use the new projection"])
    }

    func testTurnSubmissionSessionOwnsQueuedFollowUpReplayPolicy() throws {
        var composer = CodexComposerStateSession()
        composer.enqueueFollowUp("first")
        composer.enqueueFollowUp("second")
        var chat = CodexMainChatSession()

        XCTAssertNil(CodexTurnSubmissionSession.dequeueQueuedFollowUp(
            composerSession: &composer,
            mainChatSession: &chat,
            isSending: true
        ))
        XCTAssertEqual(composer.queuedFollowUps, ["first", "second"])

        let submission = try XCTUnwrap(CodexTurnSubmissionSession.dequeueQueuedFollowUp(
            composerSession: &composer,
            mainChatSession: &chat,
            isSending: false
        ))

        XCTAssertEqual(submission.prompt, "first")
        XCTAssertEqual(submission.input, [.text("first")])
        XCTAssertEqual(submission.activity.kind, .turn)
        XCTAssertEqual(submission.activity.title, "Sending queued follow-up")
        XCTAssertEqual(submission.activity.detail, "first")
        XCTAssertEqual(composer.queuedFollowUps, ["second"])
        XCTAssertTrue(chat.isSending)

        let failed = CodexTurnSubmissionSession.failQueuedFollowUp(
            submission,
            message: "offline",
            composerSession: &composer,
            mainChatSession: &chat
        )

        XCTAssertEqual(failed.kind, .turn)
        XCTAssertEqual(failed.title, "Queued follow-up failed to start")
        XCTAssertEqual(failed.detail, "offline")
        XCTAssertEqual(composer.queuedFollowUps, ["first", "second"])
        XCTAssertFalse(chat.isSending)
    }

    func testChatConfigurationSessionOwnsSelectionFallbacksAndCommandState() throws {
        let profiles: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary(["id": .string(":workspace"), "description": .null])
            ])
        ])
        let modes: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "name": .string("Plan"),
                    "mode": .string("plan"),
                    "reasoning_effort": .string("low")
                ]),
                .dictionary([
                    "name": .string("Default"),
                    "mode": .string("default")
                ])
            ])
        ])
        let modelResponse = try CodexJSONValue.dictionary([
            "data": .array([
                .dictionary([
                    "id": .string("gpt-5.1-codex-max"),
                    "model": .string("gpt-5.1-codex-max"),
                    "displayName": .string("GPT-5.1 Codex Max"),
                    "isDefault": .bool(true),
                    "defaultReasoningEffort": .string("high"),
                    "supportedReasoningEfforts": .array([
                        .dictionary(["reasoningEffort": .string("medium")]),
                        .dictionary(["reasoningEffort": .string("high")]),
                        .dictionary(["reasoningEffort": .string("xhigh")])
                    ])
                ]),
                .dictionary([
                    "id": .string("speed"),
                    "model": .string("speed"),
                    "displayName": .string("Speed"),
                    "defaultReasoningEffort": .string("minimal"),
                    "supportedReasoningEfforts": .array([
                        .dictionary(["reasoningEffort": .string("none")]),
                        .dictionary(["reasoningEffort": .string("minimal")])
                    ])
                ])
            ])
        ]).decode(ModelListResponse.self)
        let skills: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "skills": .array([
                        .dictionary([
                            "name": .string("resume-from-opencode"),
                            "interface": .dictionary([
                                "displayName": .string("Resume OpenCode"),
                                "shortDescription": .string("Continue the last OpenCode run")
                            ]),
                            "path": .string("/tmp/skills/resume-from-opencode/SKILL.md"),
                            "scope": .string("user"),
                            "enabled": .bool(true)
                        ])
                    ])
                ])
            ])
        ])

        var session = CodexChatConfigurationSession()

        let profileActivity = session.applyPermissionProfileResponse(profiles)
        XCTAssertEqual(profileActivity, CodexChatConfigurationActivity(title: "Loaded access profiles", detail: "1 app-server profiles"))
        XCTAssertEqual(session.approvalOptions, [.askForApproval, .approveForMe, .custom])
        XCTAssertEqual(session.approvalSelection, .askForApproval)

        session.setPlanModeEnabled(true)
        XCTAssertEqual(session.reasoningSelection, .medium)

        let modeActivity = session.applyCollaborationModeResponse(modes)
        XCTAssertEqual(modeActivity.detail, "2 app-server modes")
        XCTAssertTrue(session.isPlanModeEnabled)
        XCTAssertEqual(session.reasoningSelection, .low)
        XCTAssertEqual(session.turnParameterOverrides["collaborationMode"], .string("plan"))
        XCTAssertEqual(session.turnParameterOverrides["approvalPolicy"], .string(AskForApproval.onRequest.rawValue))

        let modelActivity = session.applyModelResponse(modelResponse)
        XCTAssertEqual(modelActivity.detail, "2 app-server models")
        XCTAssertEqual(session.modelSelection.displayName, "GPT-5.1 Codex Max")
        XCTAssertEqual(session.reasoningSelection, .high)

        let fastActivity = session.applyFastCommand()
        XCTAssertEqual(fastActivity, CodexChatConfigurationActivity(title: "Fast mode", detail: "Speed Minimal"))
        XCTAssertEqual(session.modelSelection.displayName, "Speed")
        XCTAssertEqual(session.reasoningSelection, .minimal)

        let reasoningActivity = try XCTUnwrap(session.cycleReasoning())
        XCTAssertEqual(reasoningActivity, CodexChatConfigurationActivity(title: "Reasoning", detail: "None"))
        XCTAssertEqual(session.reasoningSelection, .none)

        let skillsActivity = session.applySlashCommandResponse(skills)
        XCTAssertEqual(skillsActivity, CodexChatConfigurationActivity(title: "Loaded skills", detail: "1 app-server skills"))
        XCTAssertTrue(session.slashCommands.contains { $0.title == "Resume OpenCode" })

        let failureActivity = session.failSlashCommandRefresh(message: "skills unavailable")
        XCTAssertEqual(failureActivity, CodexChatConfigurationActivity(title: "Skill list unavailable", detail: "skills unavailable"))
        XCTAssertEqual(session.slashCommands, CodexSlashCommand.observedCommands)
    }

    func testAuthSessionOwnsConnectionAuthenticationAndDeviceCodeState() {
        var session = CodexAuthSession()

        XCTAssertTrue(session.beginConnecting())
        XCTAssertFalse(session.beginConnecting())
        session.connected(server: "Codex")
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

        var session = CodexComposerStateSession(draft: "  Inspect @Store.swift  ")
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
        XCTAssertEqual(session.attachedSkills, [])
        XCTAssertEqual(session.mentionResults, [])

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
        XCTAssertEqual(mcpRoute.hostActions, [.presentMCPStatus, .refreshMCPServers])

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

    @MainActor
    func testChatStreamSessionOwnsTurnAndGlobalNotificationStreams() async {
        let session = CodexChatStreamSession()
        var mainContinuation: AsyncStream<CodexNotification>.Continuation!
        let mainStream = AsyncStream<CodexNotification> { continuation in
            mainContinuation = continuation
        }
        var globalContinuation: AsyncStream<CodexNotification>.Continuation!
        let globalStream = AsyncStream<CodexNotification> { continuation in
            globalContinuation = continuation
        }
        var receivedMainTurnIDs: [String] = []
        var finishedMainTurnIDs: [String] = []
        var receivedGlobalMethods: [String] = []
        let mainReceived = expectation(description: "main stream delivered notification")
        let mainFinished = expectation(description: "main stream finished")
        let globalReceived = expectation(description: "global stream delivered notification")

        session.consumeMainTurnStream(
            id: "turn-main",
            notifications: mainStream,
            onNotification: { notification in
                receivedMainTurnIDs.append(CodexNotificationMetadata.turnID(from: notification) ?? "")
                mainReceived.fulfill()
            },
            onFinish: { turnID in
                finishedMainTurnIDs.append(turnID)
                mainFinished.fulfill()
            }
        )
        session.consumeGlobalNotificationStream(globalStream) { notification in
            receivedGlobalMethods.append(notification.method)
            globalReceived.fulfill()
        }

        mainContinuation.yield(transcriptNotification(.turnStarted(TurnStartedNotification(
            threadId: "thread-1",
            turn: AppServerTurn(id: "turn-main", status: .inProgress)
        ))))
        mainContinuation.finish()
        globalContinuation.yield(transcriptNotification(.known(method: .skillsChanged, params: [:])))

        await fulfillment(of: [mainReceived, mainFinished, globalReceived], timeout: 1.0)
        XCTAssertEqual(receivedMainTurnIDs, ["turn-main"])
        XCTAssertEqual(finishedMainTurnIDs, ["turn-main"])
        XCTAssertEqual(receivedGlobalMethods, [CodexAppServerNotificationMethod.skillsChanged.rawValue])
    }

    @MainActor
    func testChatStreamSessionAppliesRuntimeResultsAndSideChatUpdates() async {
        let session = CodexChatStreamSession()
        var mainContinuation: AsyncStream<CodexNotification>.Continuation!
        let mainStream = AsyncStream<CodexNotification> { continuation in
            mainContinuation = continuation
        }
        var sideContinuation: AsyncStream<CodexNotification>.Continuation!
        let sideStream = AsyncStream<CodexNotification> { continuation in
            sideContinuation = continuation
        }
        var mainActivities: [String] = []
        var sideActivities: [String] = []
        let mainNotificationApplied = expectation(description: "main notification result applied")
        let mainFinishApplied = expectation(description: "main finish result applied")
        let sideNotificationApplied = expectation(description: "side notification update applied")
        let sideFinishApplied = expectation(description: "side finish update applied")

        session.consumeMainTurnResultStream(
            id: "turn-main",
            notifications: mainStream,
            routeNotification: { notification in
                CodexChatNotificationPipelineResult(activities: [
                    CodexActivity(kind: .notice, title: "main", detail: notification.method)
                ])
            },
            finishTurn: { turnID in
                CodexChatNotificationPipelineResult(activities: [
                    CodexActivity(kind: .turn, title: "finished", detail: turnID)
                ])
            },
            applyResult: { result in
                mainActivities.append(contentsOf: result.activities.map(\.detail))
                if result.activities.contains(where: { $0.title == "main" }) {
                    mainNotificationApplied.fulfill()
                }
                if result.activities.contains(where: { $0.title == "finished" }) {
                    mainFinishApplied.fulfill()
                }
            }
        )

        session.consumeSideChatTurnUpdateStream(
            id: "turn-side",
            notifications: sideStream,
            routeNotification: { notification in
                CodexSideChatSessionUpdate(activity: CodexActivity(kind: .notice, title: "side", detail: notification.method))
            },
            finishTurn: { turnID in
                CodexSideChatSessionUpdate(activity: CodexActivity(kind: .turn, title: "side finished", detail: turnID))
            },
            applyUpdate: { update in
                guard let activity = update.activity else { return }
                sideActivities.append(activity.detail)
                if activity.title == "side" {
                    sideNotificationApplied.fulfill()
                }
                if activity.title == "side finished" {
                    sideFinishApplied.fulfill()
                }
            }
        )

        mainContinuation.yield(transcriptNotification(.known(method: .skillsChanged, params: [:])))
        sideContinuation.yield(transcriptNotification(.known(method: .warning, params: [:])))
        mainContinuation.finish()
        sideContinuation.finish()

        await fulfillment(
            of: [mainNotificationApplied, mainFinishApplied, sideNotificationApplied, sideFinishApplied],
            timeout: 1.0
        )
        XCTAssertEqual(mainActivities, [CodexAppServerNotificationMethod.skillsChanged.rawValue, "turn-main"])
        XCTAssertEqual(sideActivities, [CodexAppServerNotificationMethod.warning.rawValue, "turn-side"])
    }

    @MainActor
    func testChatRuntimeSessionOwnsStoreBackedStreamBinding() async {
        let session = CodexChatRuntimeSession()
        var globalContinuation: AsyncStream<CodexNotification>.Continuation!
        let globalStream = AsyncStream<CodexNotification> { continuation in
            globalContinuation = continuation
        }
        var sideContinuation: AsyncStream<CodexNotification>.Continuation!
        let sideStream = AsyncStream<CodexNotification> { continuation in
            sideContinuation = continuation
        }
        var globalActions: [CodexChatNotificationPipelineAction] = []
        var sideActivities: [String] = []
        let globalApplied = expectation(description: "global runtime stream applied")
        let sideApplied = expectation(description: "side runtime stream applied")

        _ = session.openSideChat()
        session.consumeGlobalNotificationStream(
            globalStream,
            store: nil,
            currentThreadID: { "thread-1" },
            applyResult: { result in
                globalActions.append(contentsOf: result.actions)
                globalApplied.fulfill()
            }
        )
        session.consumeSideChatTurnStream(
            id: "side-turn-1",
            notifications: sideStream,
            currentThreadID: { "thread-1" },
            store: { nil },
            applyUpdate: { update in
                guard let activity = update.activity else { return }
                sideActivities.append(activity.title)
                if activity.title == "Side chat warning" {
                    sideApplied.fulfill()
                }
            }
        )

        globalContinuation.yield(transcriptNotification(.known(method: .skillsChanged, params: [:])))
        sideContinuation.yield(transcriptNotification(.known(method: .warning, params: [
            "message": .string("side note"),
            "turnId": .string("side-turn-1")
        ])))
        sideContinuation.finish()

        await fulfillment(of: [globalApplied, sideApplied], timeout: 1.0)
        XCTAssertEqual(globalActions, [.refreshSlashCommands(forceReload: true)])
        XCTAssertEqual(sideActivities, ["Side chat warning"])
    }

    @MainActor
    func testChatRuntimeSessionOwnsSubmissionLifecycleActivities() async {
        let session = CodexChatRuntimeSession()
        let submission = CodexComposerSubmission(prompt: "Ship it")
        var mainActivities: [CodexActivity] = []
        var goalActivities: [CodexActivity] = []
        var sideActivities: [CodexActivity] = []

        let didStartMain = await session.submitMainTurn(
            submission,
            start: { throw NSError(domain: "CodexRuntimeSessionTests", code: 1) },
            currentThreadID: { "thread-1" },
            store: { nil },
            applyResult: { _ in },
            onActivity: { mainActivities.append($0) },
            errorMessage: { _ in "offline" }
        )
        XCTAssertFalse(didStartMain)
        XCTAssertEqual(mainActivities.map(\.title), ["You asked Codex", "Turn failed to start"])
        XCTAssertFalse(session.isSending)

        let goal = ThreadGoal(
            threadId: "thread-1",
            objective: "Ship it",
            status: .active,
            tokensUsed: 5,
            timeUsedSeconds: 1,
            createdAt: 1,
            updatedAt: 2
        )
        let didStartGoal = await session.submitGoal(
            submission,
            start: { goal },
            onActivity: { goalActivities.append($0) },
            errorMessage: { _ in "goal offline" }
        )
        XCTAssertTrue(didStartGoal)
        XCTAssertEqual(goalActivities.map(\.title), ["Pursuing goal", "Goal started"])
        XCTAssertEqual(session.activeGoal, goal)

        let didStartSideChat = await session.submitSideChat(
            prompt: "side quest",
            start: { throw NSError(domain: "CodexRuntimeSessionTests", code: 2) },
            currentThreadID: { "thread-1" },
            store: { nil },
            applyUpdate: { _ in },
            onActivity: { sideActivities.append($0) },
            errorMessage: { _ in "side offline" }
        )
        XCTAssertFalse(didStartSideChat)
        XCTAssertEqual(sideActivities.map(\.title), [
            "Opened side chat",
            "Side chat asked",
            "Side chat failed to start"
        ])
        XCTAssertFalse(session.isSideChatSending)
    }

    @MainActor
    func testChatStreamSessionCancelsReplacedTurnStreamsWithoutFinishingThem() async {
        let session = CodexChatStreamSession()
        var firstContinuation: AsyncStream<CodexNotification>.Continuation!
        let firstStream = AsyncStream<CodexNotification> { continuation in
            firstContinuation = continuation
        }
        var secondContinuation: AsyncStream<CodexNotification>.Continuation!
        let secondStream = AsyncStream<CodexNotification> { continuation in
            secondContinuation = continuation
        }
        var finishedTurnIDs: [String] = []
        let secondFinished = expectation(description: "second stream finished")

        session.consumeMainTurnStream(
            id: "turn-old",
            notifications: firstStream,
            onNotification: { _ in },
            onFinish: { turnID in
                finishedTurnIDs.append(turnID)
            }
        )
        session.consumeMainTurnStream(
            id: "turn-new",
            notifications: secondStream,
            onNotification: { _ in },
            onFinish: { turnID in
                finishedTurnIDs.append(turnID)
                secondFinished.fulfill()
            }
        )

        firstContinuation.finish()
        secondContinuation.finish()

        await fulfillment(of: [secondFinished], timeout: 1.0)
        XCTAssertEqual(finishedTurnIDs, ["turn-new"])
    }

    @MainActor
    func testMentionSearchSessionOwnsDebouncedSearchAndClearLifecycle() async {
        let session = CodexMentionSearchSession()
        let result = FuzzyFileSearchResult(
            fileName: "Store.swift",
            matchType: .file,
            path: "Sources/CodexCore/Store/Store.swift",
            root: "/repo",
            score: 0.9
        )
        var receivedQueries: [String] = []
        var receivedResults: [[FuzzyFileSearchResult]] = []
        var clearCount = 0
        let searched = expectation(description: "mention search completed")

        session.updateQuery(
            "Sto",
            debounceNanoseconds: 0,
            search: { query in
                receivedQueries.append(query)
                return [result]
            },
            onResults: { files in
                receivedResults.append(files)
                searched.fulfill()
            },
            onClear: {
                clearCount += 1
            }
        )

        await fulfillment(of: [searched], timeout: 1.0)
        XCTAssertEqual(receivedQueries, ["Sto"])
        XCTAssertEqual(receivedResults, [[result]])

        session.updateQuery(
            nil,
            debounceNanoseconds: 0,
            search: { _ in [] },
            onResults: { _ in },
            onClear: {
                clearCount += 1
            }
        )
        XCTAssertEqual(clearCount, 1)
    }

    func testPermissionProfilesParseAppServerAccessOptions() throws {
        let raw = CodexJSONValue.dictionary([
            "data": .array([
                .dictionary(["id": .string(":read-only"), "description": .null]),
                .dictionary(["id": .string(":workspace"), "description": .null]),
                .dictionary(["id": .string(":danger-full-access"), "description": .null])
            ]),
            "nextCursor": .null
        ])

        let profiles = CodexPermissionProfileSummary.profiles(from: raw)
        XCTAssertEqual(profiles.map(\.id), [":read-only", ":workspace", ":danger-full-access"])
        XCTAssertEqual(profiles.map(\.displayName), ["Read only", "Workspace", "Full access"])
        XCTAssertEqual(
            CodexApprovalSelection.options(from: profiles),
            [.readOnly, .askForApproval, .approveForMe, .fullAccess, .custom]
        )
        XCTAssertEqual(CodexApprovalSelection.options(from: []), CodexApprovalSelection.defaultOptions)
    }

    func testCollaborationModesParseAppServerPlanModeOptions() throws {
        let raw = CodexJSONValue.dictionary([
            "data": .array([
                .dictionary([
                    "name": .string("Plan"),
                    "mode": .string("plan"),
                    "model": .null,
                    "reasoning_effort": .string("medium")
                ]),
                .dictionary([
                    "name": .string("Default"),
                    "mode": .string("default"),
                    "model": .null,
                    "reasoning_effort": .null
                ])
            ])
        ])

        let modes = CodexCollaborationModeOption.options(from: raw)
        XCTAssertEqual(modes.map(\.name), ["Plan", "Default"])
        XCTAssertEqual(modes.map(\.mode), ["plan", "default"])
        XCTAssertEqual(modes.first?.reasoning, .medium)
        XCTAssertTrue(modes.first?.isPlanMode == true)
        XCTAssertFalse(modes.last?.isPlanMode == true)
    }

    func testApprovalPromptsParseAppServerApprovalRequests() {
        let commandRequest = JSONRPCServerRequest(
            id: .string("approval-1"),
            method: CodexAppServerServerRequestMethod.itemCommandExecutionRequestApproval.rawValue,
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "command": .array([.string("git"), .string("status"), .string("--short")]),
                "cwd": .string("/tmp/project"),
                "reason": .string("Inspect the worktree")
            ]
        )

        let commandPrompt = CodexApprovalPrompt(serverRequest: commandRequest)
        XCTAssertEqual(commandPrompt?.kind, .command)
        XCTAssertEqual(commandPrompt?.title, "Approve command?")
        XCTAssertEqual(commandPrompt?.primaryValue, "git status --short")
        XCTAssertEqual(commandPrompt?.secondaryValue, "/tmp/project")
        XCTAssertEqual(commandPrompt?.response(approved: true), CodexJSONValue.dictionary(["decision": .string("accept")]))
        XCTAssertEqual(commandPrompt?.response(approved: false), CodexJSONValue.dictionary(["decision": .string("decline")]))

        let permissionsRequest = JSONRPCServerRequest(
            id: .int(2),
            method: CodexAppServerServerRequestMethod.itemPermissionsRequestApproval.rawValue,
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-2"),
                "permissions": .dictionary([
                    "network": .bool(true),
                    "filesystem": .string("workspace")
                ])
            ]
        )

        let permissionsPrompt = CodexApprovalPrompt(serverRequest: permissionsRequest)
        XCTAssertEqual(permissionsPrompt?.kind, .permissions)
        XCTAssertEqual(permissionsPrompt?.primaryValue, "filesystem, network")
        XCTAssertEqual(permissionsPrompt?.response(approved: true), CodexJSONValue.dictionary([
            "permissions": .dictionary([
                "network": .bool(true),
                "filesystem": .string("workspace")
            ]),
            "scope": .string("turn")
        ]))
        XCTAssertEqual(permissionsPrompt?.response(approved: false), CodexJSONValue.dictionary([
            "permissions": .dictionary([:]),
            "scope": .string("turn")
        ]))

        let patchRequest = JSONRPCServerRequest(
            id: .int(3),
            method: CodexAppServerServerRequestMethod.applyPatchApproval.rawValue,
            params: [
                "conversationId": .string("thread-1"),
                "callId": .string("call-patch"),
                "fileChanges": .dictionary([
                    "Sources/App.swift": .dictionary([:]),
                    "Tests/AppTests.swift": .dictionary([:])
                ])
            ]
        )

        let patchPrompt = CodexApprovalPrompt(serverRequest: patchRequest)
        XCTAssertEqual(patchPrompt?.kind, .applyPatch)
        XCTAssertEqual(patchPrompt?.primaryValue, "Sources/App.swift, Tests/AppTests.swift")
        XCTAssertEqual(patchPrompt?.response(approved: true), CodexJSONValue.dictionary(["decision": .string("approved")]))
        XCTAssertEqual(patchPrompt?.response(approved: false), CodexJSONValue.dictionary(["decision": .string("denied")]))
    }

    func testInteractivePromptsParseAppServerServerRequests() throws {
        let userInputRequest = JSONRPCServerRequest(
            id: .int(42),
            method: CodexAppServerServerRequestMethod.itemToolRequestUserInput.rawValue,
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("input-1"),
                "questions": .array([
                    .dictionary([
                        "id": .string("question-1"),
                        "header": .string("Choice"),
                        "question": .string("Which project should Codex inspect?"),
                        "isSecret": .bool(true),
                        "isOther": .bool(true),
                        "options": .array([
                            .dictionary([
                                "label": .string("CodexCore"),
                                "description": .string("Current Swift package")
                            ])
                        ])
                    ])
                ])
            ]
        )

        let userInputPrompt = try XCTUnwrap(CodexInteractivePrompt(serverRequest: userInputRequest))
        XCTAssertEqual(userInputPrompt.kind, .userInput)
        XCTAssertEqual(userInputPrompt.title, "Input needed")
        XCTAssertEqual(userInputPrompt.detail, "Which project should Codex inspect?")
        XCTAssertEqual(userInputPrompt.questions.first?.id, "question-1")
        XCTAssertEqual(userInputPrompt.questions.first?.header, "Choice")
        XCTAssertEqual(userInputPrompt.questions.first?.isSecret, true)
        XCTAssertEqual(userInputPrompt.questions.first?.isOtherAllowed, true)
        XCTAssertEqual(userInputPrompt.questions.first?.options.first?.label, "CodexCore")
        XCTAssertEqual(userInputPrompt.userInputResponse(answers: ["question-1": "CodexCore"]), CodexJSONValue.dictionary([
            "answers": .dictionary(["question-1": .string("CodexCore")])
        ]))
        XCTAssertEqual(userInputPrompt.declineResponse(), CodexJSONValue.dictionary([
            "answers": .dictionary([:])
        ]))

        let elicitationRequest = JSONRPCServerRequest(
            id: .string("mcp-request-1"),
            method: CodexAppServerServerRequestMethod.mcpServerElicitationRequest.rawValue,
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "serverName": .string("gmail"),
                "request": .dictionary([
                    "message": .string("Allow Gmail connector access?"),
                    "requested_schema": .dictionary([
                        "type": .string("object"),
                        "properties": .dictionary([:]),
                        "required": .array([])
                    ]),
                    "_meta": .dictionary(["persist": .string("always")])
                ])
            ]
        )

        let elicitationPrompt = try XCTUnwrap(CodexInteractivePrompt(serverRequest: elicitationRequest))
        XCTAssertEqual(elicitationPrompt.kind, .mcpElicitation)
        XCTAssertEqual(elicitationPrompt.title, "gmail request")
        XCTAssertEqual(elicitationPrompt.detail, "Allow Gmail connector access?")
        XCTAssertEqual(elicitationPrompt.serverName, "gmail")
        XCTAssertEqual(elicitationPrompt.acceptElicitationResponse(), CodexJSONValue.dictionary([
            "action": .string("accept"),
            "content": .dictionary(["confirmed": .bool(true)]),
            "_meta": .null
        ]))
        XCTAssertEqual(elicitationPrompt.declineResponse(), CodexJSONValue.dictionary([
            "action": .string("decline"),
            "content": .null,
            "_meta": .null
        ]))
    }

    func testFileChangeParsesPatchUpdatedNotificationShape() throws {
        let change = try XCTUnwrap(CodexChatMessage.fileChange(itemID: "patch-1", raw: [
            "changes": .array([
                .dictionary([
                    "path": .string("Sources/App.swift"),
                    "kind": .dictionary(["type": .string("update")]),
                    "diff": .string("""
                    --- a/Sources/App.swift
                    +++ b/Sources/App.swift
                    @@ -1 +1 @@
                    -old
                    +new
                    """)
                ])
            ]),
            "status": .string("running")
        ]))

        XCTAssertEqual(change.itemID, "patch-1")
        XCTAssertEqual(change.path, "Sources/App.swift")
        XCTAssertEqual(change.kind, "update")
        XCTAssertEqual(change.addedLineCount, 1)
        XCTAssertEqual(change.removedLineCount, 1)
        XCTAssertTrue(change.isStreaming)
    }

    func testFileChangeCountsChangedFilesInMultiFileDiff() throws {
        let change = CodexChatMessage.fileChange(
            itemID: "patch-2",
            path: nil,
            diff: """
            diff --git a/Sources/App.swift b/Sources/App.swift
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1 +1 @@
            -old
            +new
            diff --git a/Tests/AppTests.swift b/Tests/AppTests.swift
            --- a/Tests/AppTests.swift
            +++ b/Tests/AppTests.swift
            @@ -2 +2 @@
            -before
            +after
            """,
            status: "completed",
            isStreaming: false
        )

        XCTAssertEqual(change.changedFileCount, 2)
        XCTAssertEqual(change.addedLineCount, 2)
        XCTAssertEqual(change.removedLineCount, 2)
    }

    func testFileChangeUndoSessionOwnsGitCommandPolicy() throws {
        let modified = CodexChatMessage.fileChange(
            itemID: "patch-1",
            path: "/repo/Sources/App.swift",
            diff: "+new",
            kind: "update",
            status: "completed"
        )
        let added = CodexChatMessage.fileChange(
            itemID: "patch-2",
            path: "/repo/Sources/New.swift",
            diff: "+new",
            kind: "add",
            status: "completed"
        )

        let modifiedPlan = try XCTUnwrap(CodexFileChangeUndoSession.plan(for: modified, workspacePath: "/repo"))
        XCTAssertEqual(modifiedPlan.command, ["git", "checkout", "--", "Sources/App.swift"])
        XCTAssertEqual(modifiedPlan.cwd, "/repo")
        XCTAssertEqual(modifiedPlan.relativePath, "Sources/App.swift")

        let addedPlan = try XCTUnwrap(CodexFileChangeUndoSession.plan(for: added, workspacePath: "/repo/"))
        XCTAssertEqual(addedPlan.command, ["git", "clean", "-f", "--", "Sources/New.swift"])

        let unavailable = CodexChatMessage.fileChange(itemID: "patch-3", path: nil, diff: "+new", status: "completed")
        XCTAssertNil(CodexFileChangeUndoSession.plan(for: unavailable, workspacePath: "/repo"))
        XCTAssertEqual(CodexFileChangeUndoSession.unavailableActivity.title, "Undo unavailable")
        XCTAssertEqual(CodexFileChangeUndoSession.successActivity(relativePath: "Sources/App.swift").detail, "Sources/App.swift")
        XCTAssertEqual(CodexFileChangeUndoSession.failureActivity(message: "nope").detail, "nope")
    }

    func testPlanUpdateParsesTurnPlanUpdatedNotificationShape() throws {
        let plan = try XCTUnwrap(CodexChatMessage.planUpdate(itemID: "turn-plan-1", raw: [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "explanation": .string("I will inspect, edit, and verify."),
            "plan": .array([
                .dictionary([
                    "step": .string("Inspect current transcript mapping"),
                    "status": .string("completed")
                ]),
                .dictionary([
                    "step": .string("Wire plan updates into the UI"),
                    "status": .string("inProgress")
                ]),
                .dictionary([
                    "step": .string("Run tests"),
                    "status": .string("pending")
                ])
            ])
        ]))

        XCTAssertEqual(plan.itemID, "turn-plan-1")
        XCTAssertEqual(plan.explanation, "I will inspect, edit, and verify.")
        XCTAssertEqual(plan.steps.map(\.step), [
            "Inspect current transcript mapping",
            "Wire plan updates into the UI",
            "Run tests"
        ])
        XCTAssertEqual(plan.completedStepCount, 1)
        XCTAssertEqual(plan.activeStepCount, 1)
        XCTAssertEqual(plan.summary, "1/3 complete")
        XCTAssertTrue(plan.copyText.contains("[inProgress] Wire plan updates into the UI"))
    }

    func testToolCallParsesMCPThreadItemShape() throws {
        let toolCall = try XCTUnwrap(CodexChatMessage.toolCall(itemID: "mcp-1", raw: [
            "type": .string("mcpToolCall"),
            "server": .string("filesystem"),
            "tool": .string("read_file"),
            "arguments": .dictionary(["path": .string("Package.swift")]),
            "status": .string("completed"),
            "durationMs": .int(42),
            "result": .dictionary([
                "content": .array([
                    .dictionary([
                        "type": .string("text"),
                        "text": .string("package contents")
                    ])
                ])
            ])
        ]))

        XCTAssertEqual(toolCall.displayName, "filesystem.read_file")
        XCTAssertEqual(toolCall.arguments, #"{"path":"Package.swift"}"#)
        XCTAssertEqual(toolCall.result, "package contents")
        XCTAssertEqual(toolCall.durationMilliseconds, 42)
        XCTAssertFalse(toolCall.isStreaming)
        XCTAssertTrue(toolCall.copyText.contains("Arguments:"))
    }

    func testNoticeParsesModelWarningAndAutoReviewNotificationShapes() throws {
        let reroute = try XCTUnwrap(CodexChatMessage.notice(
            itemID: "reroute-1",
            method: .modelRerouted,
            raw: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "fromModel": .string("gpt-5.1-codex-max"),
                "toModel": .string("gpt-5.1-codex"),
                "reason": .string("highRiskCyberActivity")
            ]
        ))
        XCTAssertEqual(reroute.title, "Model rerouted")
        XCTAssertEqual(reroute.detail, "gpt-5.1-codex-max -> gpt-5.1-codex")
        XCTAssertEqual(reroute.metadata, ["Reason: high risk cyber activity"])
        XCTAssertEqual(reroute.severity, .warning)

        let configWarning = try XCTUnwrap(CodexChatMessage.notice(
            itemID: "config-1",
            method: .configWarning,
            raw: [
                "summary": .string("Invalid sandbox value"),
                "details": .string("Use workspace-write or read-only."),
                "path": .string("/tmp/config.toml"),
                "range": .dictionary([
                    "start": .dictionary(["line": .int(7), "column": .int(4)]),
                    "end": .dictionary(["line": .int(7), "column": .int(18)])
                ])
            ]
        ))
        XCTAssertEqual(configWarning.title, "Config warning")
        XCTAssertEqual(configWarning.detail, "Invalid sandbox value")
        XCTAssertTrue(configWarning.metadata.contains("Location: 7:4"))

        let reviewStarted = try XCTUnwrap(CodexChatMessage.notice(
            itemID: "review-auto-1",
            method: .itemAutoApprovalReviewStarted,
            raw: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "reviewId": .string("auto-1"),
                "startedAtMs": .int(1_000),
                "targetItemId": .string("cmd-1"),
                "action": .dictionary([
                    "type": .string("command"),
                    "command": .string("swift test"),
                    "cwd": .string("/tmp/CodexCore"),
                    "source": .string("agent")
                ]),
                "review": .dictionary([
                    "status": .string("inProgress"),
                    "riskLevel": .string("low"),
                    "rationale": .string("Tests are safe to run.")
                ])
            ],
            isStreaming: true
        ))
        XCTAssertEqual(reviewStarted.title, "Auto review")
        XCTAssertEqual(reviewStarted.detail, "swift test")
        XCTAssertEqual(reviewStarted.status, "inProgress")
        XCTAssertTrue(reviewStarted.isStreaming)
        XCTAssertEqual(reviewStarted.severity, .info)

        let reviewCompleted = try XCTUnwrap(CodexChatMessage.notice(
            itemID: "review-auto-1",
            method: .itemAutoApprovalReviewCompleted,
            raw: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "reviewId": .string("auto-1"),
                "startedAtMs": .int(1_000),
                "completedAtMs": .int(2_250),
                "decisionSource": .string("agent"),
                "targetItemId": .string("cmd-1"),
                "action": .dictionary([
                    "type": .string("command"),
                    "command": .string("swift test"),
                    "cwd": .string("/tmp/CodexCore"),
                    "source": .string("agent")
                ]),
                "review": .dictionary([
                    "status": .string("approved"),
                    "riskLevel": .string("low"),
                    "rationale": .string("No risky behavior found.")
                ])
            ]
        ))
        XCTAssertEqual(reviewCompleted.title, "Auto review approved")
        XCTAssertEqual(reviewCompleted.severity, .success)
        XCTAssertFalse(reviewCompleted.isStreaming)
        XCTAssertTrue(reviewCompleted.metadata.contains("Duration: 1.2s"))
    }

    func testChatActionHandlersExposeHostWiredActions() {
        var didOpenSideChat = false
        var didCopyChat = false
        let actions = CodexChatActionHandlers(
            openSideChat: { didOpenSideChat = true },
            copyChat: { didCopyChat = true }
        )

        XCTAssertNil(CodexChatActionHandlers().openSideChat)
        XCTAssertNil(CodexChatActionHandlers().copyChat)

        actions.openSideChat?()
        actions.copyChat?()

        XCTAssertTrue(didOpenSideChat)
        XCTAssertTrue(didCopyChat)
        XCTAssertEqual(CodexSideChatState.defaultID, "side-chat")
        XCTAssertEqual(CodexSideChatState().id, CodexSideChatState.defaultID)
    }

    func testSlashCommandsMatchObservedCodexPaletteAndFilter() throws {
        XCTAssertEqual(CodexSlashCommand.observedCommands.map(\.title), [
            "Code review",
            "Compact",
            "Fast",
            "Feedback",
            "Fork",
            "Goal",
            "MCP",
            "Model",
            "Personality",
            "Pet",
            "Plan mode",
            "Reasoning",
            "Side",
            "Status"
        ])
        let compact = try XCTUnwrap(CodexSlashCommand.observedCommands.first { $0.id == "compact" })
        XCTAssertNil(compact.draftText)
        let mcp = try XCTUnwrap(CodexSlashCommand.observedCommands.first { $0.id == "mcp" })
        XCTAssertNil(mcp.draftText)

        XCTAssertEqual(CodexSlashCommand.query(from: "/sta"), "sta")
        XCTAssertEqual(CodexSlashCommand.query(from: "  /side please"), "side")
        XCTAssertNil(CodexSlashCommand.query(from: "Ask about /status"))

        XCTAssertEqual(
            CodexSlashCommand.filteredCommands(matching: "/sta").map(\.title),
            ["Status"]
        )
        XCTAssertEqual(
            CodexSlashCommand.filteredCommands(matching: "/rea").map(\.title),
            ["Reasoning"]
        )
        XCTAssertEqual(
            CodexSlashCommand.filteredCommands(matching: "/").map(\.title),
            CodexSlashCommand.observedCommands.map(\.title)
        )

        let personalSkill = CodexSlashCommand(
            id: "resume-from-opencode",
            title: "resume-from-opencode",
            detail: "Resume an OpenCode session",
            systemImage: "hammer",
            section: "Skills",
            scopeBadge: "Personal"
        )
        let filtered = CodexSlashCommand.filteredCommands(
            from: CodexSlashCommand.observedCommands + [personalSkill],
            matching: "/resume"
        )

        XCTAssertEqual(filtered, [personalSkill])
        XCTAssertEqual(filtered.first?.section, "Skills")
        XCTAssertEqual(filtered.first?.scopeBadge, "Personal")
    }

    func testSlashCommandsParseAppServerSkillsListResponse() {
        let response: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "cwd": .string("/tmp/CodexCore"),
                    "skills": .array([
                        .dictionary([
                            "name": .string("resume-from-opencode"),
                            "description": .string("Resume an OpenCode session from Codex."),
                            "shortDescription": .string("Resume OpenCode"),
                            "interface": .dictionary([
                                "displayName": .string("Resume OpenCode"),
                                "shortDescription": .string("Continue the last OpenCode run"),
                                "defaultPrompt": .string("Resume the last OpenCode session.")
                            ]),
                            "path": .string("/tmp/skills/resume-from-opencode/SKILL.md"),
                            "scope": .string("user"),
                            "enabled": .bool(true)
                        ]),
                        .dictionary([
                            "name": .string("disabled-skill"),
                            "description": .string("Should not show"),
                            "path": .string("/tmp/skills/disabled/SKILL.md"),
                            "scope": .string("repo"),
                            "enabled": .bool(false)
                        ])
                    ]),
                    "errors": .array([])
                ])
            ])
        ])

        let commands = CodexSlashCommand.skillCommands(from: response)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.id, "skill:resume-from-opencode")
        XCTAssertEqual(commands.first?.title, "Resume OpenCode")
        XCTAssertEqual(commands.first?.detail, "Continue the last OpenCode run")
        XCTAssertEqual(commands.first?.section, "Skills")
        XCTAssertEqual(commands.first?.scopeBadge, "Personal")
        XCTAssertEqual(commands.first?.draftText, "Resume the last OpenCode session.")
        XCTAssertEqual(commands.first?.skillName, "resume-from-opencode")
        XCTAssertEqual(commands.first?.skillPath, "/tmp/skills/resume-from-opencode/SKILL.md")
    }

    func testMCPServerStatusesParseAppServerResponse() {
        let response: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "name": .string("filesystem"),
                    "authStatus": .string("unsupported"),
                    "serverInfo": .dictionary([
                        "name": .string("filesystem"),
                        "title": .string("Filesystem"),
                        "version": .string("1.0.0"),
                        "description": .string("Local file access")
                    ]),
                    "tools": .dictionary([
                        "read_file": .dictionary([
                            "name": .string("read_file"),
                            "title": .string("Read file"),
                            "description": .string("Read a file")
                        ]),
                        "list_directory": .dictionary([
                            "name": .string("list_directory"),
                            "title": .string("List files"),
                            "description": .string("List files")
                        ])
                    ]),
                    "resources": .array([
                        .dictionary([
                            "name": .string("workspace"),
                            "title": .string("Workspace"),
                            "uri": .string("file:///tmp/CodexCore")
                        ])
                    ]),
                    "resourceTemplates": .array([
                        .dictionary([
                            "name": .string("repo-file"),
                            "uriTemplate": .string("file:///{path}")
                        ])
                    ])
                ])
            ]),
            "nextCursor": .null
        ])

        let servers = CodexMCPServerStatus.statuses(from: response)

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].name, "filesystem")
        XCTAssertEqual(servers[0].displayName, "Filesystem")
        XCTAssertEqual(servers[0].version, "1.0.0")
        XCTAssertEqual(servers[0].detail, "Local file access")
        XCTAssertEqual(servers[0].authStatusLabel, "Auth unsupported")
        XCTAssertEqual(servers[0].tools.map(\.displayName), ["List files", "Read file"])
        XCTAssertEqual(servers[0].resources.map(\.displayName), ["Workspace"])
        XCTAssertEqual(servers[0].resourceTemplates.map(\.name), ["repo-file"])
        XCTAssertEqual(servers[0].inventorySummary, "2 tools · 2 resources")

        let updated = servers[0].applyingStartupStatus("failed", error: "node missing")
        XCTAssertEqual(updated.startupStatus, "failed")
        XCTAssertEqual(updated.error, "node missing")
    }

    func testPluginSummariesParseAppServerPluginListResponse() {
        let response: CodexJSONValue = .dictionary([
            "marketplaces": .array([
                .dictionary([
                    "name": .string("local"),
                    "interface": .dictionary([
                        "displayName": .string("Local marketplace")
                    ]),
                    "path": .string("/tmp/marketplace.json"),
                    "plugins": .array([
                        .dictionary([
                            "authPolicy": .string("ON_USE"),
                            "enabled": .bool(true),
                            "id": .string("resume-from-opencode"),
                            "installPolicy": .string("INSTALLED_BY_DEFAULT"),
                            "installed": .bool(true),
                            "name": .string("resume-from-opencode"),
                            "source": .dictionary([
                                "type": .string("local"),
                                "path": .string("/tmp/plugins/resume-from-opencode")
                            ]),
                            "availability": .string("AVAILABLE"),
                            "interface": .dictionary([
                                "displayName": .string("Resume OpenCode"),
                                "shortDescription": .string("Resume a previous OpenCode session"),
                                "longDescription": .string("Resume long running agent work."),
                                "developerName": .string("OpenAI"),
                                "category": .string("Agents"),
                                "capabilities": .array([.string("skills"), .string("prompts")]),
                                "screenshots": .array([]),
                                "screenshotUrls": .array([])
                            ]),
                            "keywords": .array([.string("agents")]),
                            "localVersion": .string("1.0.0")
                        ]),
                        .dictionary([
                            "authPolicy": .string("ON_INSTALL"),
                            "enabled": .bool(false),
                            "id": .string("example-remote"),
                            "installPolicy": .string("AVAILABLE"),
                            "installed": .bool(false),
                            "name": .string("example-remote"),
                            "source": .dictionary([
                                "type": .string("remote")
                            ]),
                            "availability": .string("AVAILABLE"),
                            "interface": .dictionary([
                                "displayName": .string("Example Remote"),
                                "shortDescription": .string("Remote plugin"),
                                "capabilities": .array([]),
                                "screenshots": .array([]),
                                "screenshotUrls": .array([])
                            ])
                        ])
                    ])
                ])
            ]),
            "marketplaceLoadErrors": .array([
                .dictionary([
                    "marketplacePath": .string("/tmp/bad-marketplace.json"),
                    "message": .string("invalid manifest")
                ])
            ]),
            "featuredPluginIds": .array([])
        ])

        let plugins = CodexPluginSummary.plugins(from: response)

        XCTAssertEqual(plugins.count, 2)
        XCTAssertEqual(plugins[0].name, "resume-from-opencode")
        XCTAssertEqual(plugins[0].displayName, "Resume OpenCode")
        XCTAssertEqual(plugins[0].statusLabel, "Installed")
        XCTAssertEqual(plugins[0].sourceLabel, "Local")
        XCTAssertEqual(plugins[0].sourceDetail, "/tmp/plugins/resume-from-opencode")
        XCTAssertEqual(plugins[0].marketplaceDisplayName, "Local marketplace")
        XCTAssertEqual(plugins[0].capabilities, ["skills", "prompts"])
        XCTAssertEqual(plugins[0].detail, "Resume a previous OpenCode session")
        XCTAssertEqual(plugins[1].statusLabel, "Available")
        XCTAssertEqual(plugins[1].sourceLabel, "Remote")
        XCTAssertEqual(
            CodexPluginSummary.loadErrorMessages(from: response),
            ["/tmp/bad-marketplace.json: invalid manifest"]
        )
    }

    func testIntegrationCatalogSessionOwnsMCPAndPluginLoadingState() {
        let mcpResponse: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "name": .string("filesystem"),
                    "authStatus": .string("unsupported"),
                    "serverInfo": .dictionary([
                        "title": .string("Filesystem")
                    ]),
                    "tools": .dictionary([
                        "read_file": .dictionary([
                            "name": .string("read_file"),
                            "title": .string("Read file")
                        ])
                    ])
                ])
            ])
        ])
        let pluginResponse: CodexJSONValue = .dictionary([
            "marketplaces": .array([
                .dictionary([
                    "name": .string("local"),
                    "plugins": .array([
                        .dictionary([
                            "enabled": .bool(true),
                            "id": .string("resume-from-opencode"),
                            "installed": .bool(true),
                            "name": .string("resume-from-opencode"),
                            "interface": .dictionary([
                                "displayName": .string("Resume OpenCode"),
                                "shortDescription": .string("Resume a previous OpenCode session")
                            ])
                        ])
                    ])
                ])
            ]),
            "marketplaceLoadErrors": .array([
                .dictionary([
                    "marketplacePath": .string("/tmp/bad-marketplace.json"),
                    "message": .string("invalid manifest")
                ])
            ])
        ])

        var session = CodexIntegrationCatalogSession()

        session.requireMCPConnection(message: "Connect first")
        XCTAssertEqual(session.mcpErrorMessage, "Connect first")
        XCTAssertFalse(session.isLoadingMCPServers)

        session.beginMCPRefresh()
        XCTAssertTrue(session.isLoadingMCPServers)
        XCTAssertNil(session.mcpErrorMessage)

        let mcpActivity = session.applyMCPResponse(mcpResponse)
        XCTAssertEqual(mcpActivity, CodexIntegrationCatalogActivity(title: "Loaded MCP servers", detail: "1 configured"))
        XCTAssertEqual(session.mcpServers.map(\.displayName), ["Filesystem"])
        XCTAssertFalse(session.isLoadingMCPServers)

        session.applyMCPStartupStatus(CodexMCPServerStartupStatus(name: "filesystem", status: "ready", error: nil))
        XCTAssertEqual(session.mcpServers[0].startupStatus, "ready")
        session.applyMCPStartupStatus(CodexMCPServerStartupStatus(name: "github", status: "failed", error: "missing token"))
        XCTAssertEqual(session.mcpServers.map(\.name), ["filesystem", "github"])
        XCTAssertEqual(session.mcpServers[1].error, "missing token")

        let failedMCP = session.failMCPRefresh(message: "server unavailable")
        XCTAssertEqual(failedMCP.title, "MCP status unavailable")
        XCTAssertEqual(session.mcpServers, [])
        XCTAssertEqual(session.mcpErrorMessage, "server unavailable")

        session.requirePluginConnection(message: "Connect first")
        XCTAssertEqual(session.pluginErrorMessage, "Connect first")
        XCTAssertEqual(session.pluginLoadErrors, [])
        XCTAssertFalse(session.isLoadingPlugins)

        session.beginPluginRefresh()
        XCTAssertTrue(session.isLoadingPlugins)
        XCTAssertNil(session.pluginErrorMessage)

        let pluginActivity = session.applyPluginResponse(pluginResponse)
        XCTAssertEqual(pluginActivity, CodexIntegrationCatalogActivity(title: "Loaded plugins", detail: "1 available"))
        XCTAssertEqual(session.plugins.map(\.displayName), ["Resume OpenCode"])
        XCTAssertEqual(session.pluginLoadErrors, ["/tmp/bad-marketplace.json: invalid manifest"])
        XCTAssertFalse(session.isLoadingPlugins)

        let failedPlugins = session.failPluginRefresh(message: "bad marketplace")
        XCTAssertEqual(failedPlugins.title, "Plugin list unavailable")
        XCTAssertEqual(session.plugins, [])
        XCTAssertEqual(session.pluginLoadErrors, [])
        XCTAssertEqual(session.pluginErrorMessage, "bad marketplace")
    }

    @MainActor
    func testEmptyTranscriptDefaultPromptsMatchObservedCodexBlankState() {
        XCTAssertEqual(CodexEmptyTranscriptView.defaultPrompts.map(\.prompt), [
            "Connect messaging",
            "Connect email",
            "Connect files"
        ])
        XCTAssertEqual(CodexEmptyTranscriptView.defaultPrompts.map(\.detail), [
            "get context from team discussions",
            "summarize stakeholder asks",
            "review results, research, and plans"
        ])
    }

    func testSubagentRunSummaryCompletionWinsOverHistoricalRunningEvents() {
        let now = Date(timeIntervalSince1970: 2_000)
        let events = [
            CodexAgentLifecycleEvent(status: .spawning, title: "Spawning agent", createdAt: now),
            CodexAgentLifecycleEvent(status: .running, title: "Spawned Agent 1", agentNames: ["Agent 1"], createdAt: now.addingTimeInterval(1)),
            CodexAgentLifecycleEvent(status: .spawning, title: "Spawning agent", createdAt: now.addingTimeInterval(2)),
            CodexAgentLifecycleEvent(status: .running, title: "Spawned Agent 2", agentNames: ["Agent 2"], createdAt: now.addingTimeInterval(3)),
            CodexAgentLifecycleEvent(status: .running, title: "Waiting for Agent 2", agentNames: ["Agent 2"], createdAt: now.addingTimeInterval(4)),
            CodexAgentLifecycleEvent(status: .completed, title: "Finished waiting", agentNames: ["Agent 2"], createdAt: now.addingTimeInterval(5)),
            CodexAgentLifecycleEvent(status: .closed, title: "Closed Agent 1", agentNames: ["Agent 1"], createdAt: now.addingTimeInterval(6)),
            CodexAgentLifecycleEvent(status: .closed, title: "Closed Agent 2", agentNames: ["Agent 2"], createdAt: now.addingTimeInterval(7))
        ]

        let summary = CodexSubagentRunSummary(events: events)

        XCTAssertEqual(summary.status, .completed)
        XCTAssertEqual(summary.title, "Subagent run complete")
        XCTAssertEqual(summary.agentCountLabel, "2 agents")
        XCTAssertTrue(summary.detail.contains("finished"))
        XCTAssertFalse(summary.detail.contains("active"))
        XCTAssertEqual(summary.milestones.map(\.title), ["Spawned 2 agents", "Received agent output"])
    }

    func testSubagentRunSummaryInfersAgentCountFromWaitingTitle() {
        let summary = CodexSubagentRunSummary(events: [
            CodexAgentLifecycleEvent(status: .running, title: "Waiting for 2 agents")
        ])

        XCTAssertEqual(summary.status, .running)
        XCTAssertEqual(summary.title, "Subagents running")
        XCTAssertEqual(summary.agentCountLabel, "2 agents")
        XCTAssertEqual(summary.milestones.map(\.title), ["Waiting for 2 agents"])
    }

    func testFloatingSummarySubagentRowsMatchObservedCodexLifecycle() {
        let running = CodexSubagentState(
            name: "Halley",
            title: "Slow repo cartographer",
            prompt: "Run read-only tools",
            status: .running
        )
        let completed = CodexSubagentState(
            name: "Newton",
            title: "Slow renderer",
            prompt: "Inspect UI",
            status: .completed
        )
        let closed = CodexSubagentState(
            name: "Parfit",
            title: "Slow runtime observer",
            prompt: "Check runtimes",
            status: .closed
        )

        XCTAssertTrue(running.isVisibleInFloatingSummary)
        XCTAssertEqual(running.floatingSummaryTitle, "Halley is working")
        XCTAssertTrue(completed.isVisibleInFloatingSummary)
        XCTAssertEqual(completed.floatingSummaryTitle, "Newton")
        XCTAssertFalse(closed.isVisibleInFloatingSummary)
    }
}

@discardableResult
func routeTranscriptNotification(
    _ payload: CodexNotificationPayload,
    to transcript: inout CodexChatTranscriptState,
    context: CodexChatTranscriptRouteContext = CodexChatTranscriptRouteContext()
) -> CodexChatTranscriptRouteResult? {
    CodexChatTranscriptNotificationRouter.apply(
        transcriptNotification(payload),
        to: &transcript,
        context: context
    )
}

func transcriptNotification(_ payload: CodexNotificationPayload) -> CodexNotification {
    CodexNotification(
        method: payload.knownMethod?.rawValue ?? "unknown",
        payload: payload,
        rawParams: payload.rawParams
    )
}

func transcriptThreadItem(_ raw: [String: CodexJSONValue]) throws -> ThreadItem {
    try CodexJSONValue.dictionary(raw).decode(ThreadItem.self)
}

private extension CodexNotificationPayload {
    var rawParams: [String: CodexJSONValue] {
        switch self {
        case .itemStarted(let payload), .itemCompleted(let payload):
            return [
                "threadId": .string(payload.threadId),
                "turnId": .string(payload.turnId),
                "item": .dictionary(payload.item.raw)
            ]
        case .agentMessageDelta(let payload):
            return [
                "threadId": .string(payload.threadId),
                "turnId": .string(payload.turnId),
                "itemId": .string(payload.itemId),
                "delta": .string(payload.delta)
            ]
        case .turnPlanUpdated(let payload):
            return [
                "threadId": .string(payload.threadId),
                "turnId": .string(payload.turnId),
                "explanation": payload.explanation.map(CodexJSONValue.string) ?? .null,
                "plan": .array(payload.plan.map { step in
                    .dictionary([
                        "step": .string(step.step),
                        "status": .string(step.status.rawValue)
                    ])
                })
            ]
        case .turnDiffUpdated(let payload):
            return [
                "threadId": .string(payload.threadId),
                "turnId": .string(payload.turnId),
                "diff": .string(payload.diff)
            ]
        case .known(_, let params), .unknown(_, let params):
            return params
        case .threadTokenUsageUpdated(let payload):
            var raw: [String: CodexJSONValue] = [
                "threadId": .string(payload.threadId),
                "tokenUsage": .dictionary(payload.tokenUsage.raw)
            ]
            if let turnId = payload.turnId { raw["turnId"] = .string(turnId) }
            return raw
        case .threadGoalUpdated(let payload):
            var raw: [String: CodexJSONValue] = [
                "threadId": .string(payload.threadId)
            ]
            if let turnId = payload.turnId { raw["turnId"] = .string(turnId) }
            return raw
        case .threadGoalCleared(let payload):
            return ["threadId": .string(payload.threadId)]
        case .turnStarted, .turnCompleted, .accountLoginCompleted:
            return [:]
        }
    }
}

private struct AgentUIFixture {
    var sideChat: CodexSideChatState
    var subagents: [CodexSubagentState]
    var lifecycleEvents: [CodexAgentLifecycleEvent]

    static func make() -> AgentUIFixture {
        let now = Date(timeIntervalSince1970: 1_000)
        let sideChat = CodexSideChatState(
            messages: [
                CodexChatMessage(role: .user, text: "Open a focused branch", createdAt: now),
                CodexChatMessage(role: .assistant, text: "Branch ready", createdAt: now.addingTimeInterval(1))
            ],
            createdAt: now
        )

        let subagents = [
            CodexSubagentState(
                name: "Chandrasekhar",
                title: "Chat and composer inspection",
                prompt: "Inspect chat/composer UX",
                status: .closed,
                messages: [CodexChatMessage(role: .assistant, text: "Chat/composer findings", createdAt: now.addingTimeInterval(2))],
                createdAt: now,
                completedAt: now.addingTimeInterval(2)
            ),
            CodexSubagentState(
                name: "Copernicus",
                title: "Side panel inspection",
                prompt: "Inspect side panel UX",
                status: .closed,
                messages: [CodexChatMessage(role: .assistant, text: "Side-panel findings", createdAt: now.addingTimeInterval(3))],
                createdAt: now,
                completedAt: now.addingTimeInterval(3)
            )
        ]

        let lifecycleEvents = [
            CodexAgentLifecycleEvent(
                status: .spawning,
                title: "Spawned 2 agents",
                agentNames: subagents.map(\.name),
                createdAt: now.addingTimeInterval(1)
            ),
            CodexAgentLifecycleEvent(
                status: .closed,
                title: "Closed 2 agents",
                agentNames: subagents.map(\.name),
                createdAt: now.addingTimeInterval(4)
            )
        ]

        return AgentUIFixture(sideChat: sideChat, subagents: subagents, lifecycleEvents: lifecycleEvents)
    }
}
