import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexChatConfigurationSessionTests: XCTestCase {
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

}
