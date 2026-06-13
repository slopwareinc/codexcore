import XCTest
import SwiftUI
import CodexCore
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

    func testThreadSummariesParseRawAppServerThreadList() {
        let response: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "id": .string("thread-main"),
                    "name": .string("Plan the release"),
                    "preview": .string("Ship the Swift example"),
                    "cwd": .string("/tmp/CodexCore"),
                    "status": .dictionary(["type": .string("idle")]),
                    "modelProvider": .string("openai"),
                    "parentThreadId": .null,
                    "ephemeral": .bool(false),
                    "createdAt": .int(1_000),
                    "updatedAt": .int(2_000)
                ]),
                .dictionary([
                    "id": .string("thread-side"),
                    "name": .null,
                    "preview": .string("Side investigation"),
                    "cwd": .string("/tmp/CodexCore"),
                    "status": .string("active"),
                    "parentThreadId": .string("thread-main"),
                    "ephemeral": .bool(true),
                    "createdAt": .int(1_100),
                    "updatedAt": .int(1_200)
                ])
            ])
        ])

        let summaries = CodexThreadSummary.summaries(from: response)

        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries[0].title, "Plan the release")
        XCTAssertEqual(summaries[0].detail, "Ship the Swift example")
        XCTAssertEqual(summaries[0].status, "idle")
        XCTAssertEqual(summaries[0].workspacePath, "/tmp/CodexCore")
        XCTAssertEqual(summaries[0].updatedAt, 2_000)
        XCTAssertEqual(summaries[1].title, "Side investigation")
        XCTAssertEqual(summaries[1].status, "active")
        XCTAssertEqual(summaries[1].parentThreadID, "thread-main")
        XCTAssertTrue(summaries[1].isEphemeral)
    }

    func testThreadSearchResultsParseRawAppServerResponse() {
        let response: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "thread": .dictionary([
                        "id": .string("thread-search-hit"),
                        "name": .string("Searchable planning chat"),
                        "preview": .string("Release checklist"),
                        "cwd": .string("/tmp/CodexCore"),
                        "status": .dictionary(["type": .string("idle")]),
                        "parentThreadId": .null,
                        "ephemeral": .bool(false),
                        "createdAt": .int(1_000),
                        "updatedAt": .int(2_000)
                    ]),
                    "snippet": .string("Found NEEDLE in the transcript")
                ])
            ]),
            "nextCursor": .null,
            "backwardsCursor": .null
        ])

        let results = CodexThreadSearchResult.results(from: response)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "thread-search-hit")
        XCTAssertEqual(results[0].thread.title, "Searchable planning chat")
        XCTAssertEqual(results[0].thread.workspacePath, "/tmp/CodexCore")
        XCTAssertEqual(results[0].thread.status, "idle")
        XCTAssertEqual(results[0].snippet, "Found NEEDLE in the transcript")
    }

    func testProjectSummariesGroupVisibleThreadsByWorkspace() {
        let summaries = [
            CodexThreadSummary(
                id: "thread-a",
                title: "Current project chat",
                workspacePath: "/tmp/CodexCore",
                updatedAt: 2_000
            ),
            CodexThreadSummary(
                id: "thread-b",
                title: "Other project newest",
                workspacePath: "/tmp/Other",
                updatedAt: 3_000
            ),
            CodexThreadSummary(
                id: "thread-c",
                title: "Other project older",
                workspacePath: "/tmp/Other",
                updatedAt: 1_000
            )
        ]

        let projects = CodexProjectSummary.projects(from: summaries, currentWorkspacePath: "/tmp/CodexCore")

        XCTAssertEqual(projects.map(\.workspacePath), ["/tmp/CodexCore", "/tmp/Other"])
        XCTAssertEqual(projects[0].displayName, "CodexCore")
        XCTAssertEqual(projects[0].chatCount, 1)
        XCTAssertEqual(projects[1].chatCount, 2)
        XCTAssertEqual(projects[1].updatedAt, 3_000)

        let noHistory = CodexProjectSummary.projects(from: [], currentWorkspacePath: "/tmp/NewProject")
        XCTAssertEqual(noHistory.map(\.workspacePath), ["/tmp/NewProject"])
        XCTAssertEqual(noHistory.first?.chatCount, 0)
    }

    func testThreadHistorySnapshotRestoresMessagesFromRawThreadRead() {
        let response: CodexJSONValue = .dictionary([
            "thread": .dictionary([
                "id": .string("thread-main"),
                "turns": .array([
                    .dictionary([
                        "id": .string("turn-1"),
                        "startedAt": .int(1_000),
                        "items": .array([
                            .dictionary([
                                "id": .string("user-1"),
                                "type": .string("userMessage"),
                                "content": .array([
                                    .dictionary([
                                        "type": .string("text"),
                                        "text": .string("Inspect the Swift app")
                                    ])
                                ])
                            ]),
                            .dictionary([
                                "id": .string("assistant-1"),
                                "type": .string("agentMessage"),
                                "text": .string("I checked the app-server surface."),
                                "phase": .string("commentary")
                            ]),
                            .dictionary([
                                "id": .string("command-1"),
                                "type": .string("commandExecution"),
                                "command": .array([.string("swift"), .string("test")]),
                                "aggregatedOutput": .string("All tests passed"),
                                "status": .string("completed"),
                                "exitCode": .int(0),
                                "cwd": .string("/tmp/CodexCore")
                            ]),
                            .dictionary([
                                "id": .string("patch-1"),
                                "type": .string("fileChange"),
                                "status": .string("completed"),
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
                                ])
                            ]),
                            .dictionary([
                                "id": .string("plan-1"),
                                "type": .string("plan"),
                                "explanation": .string("Verify parity in small slices."),
                                "plan": .array([
                                    .dictionary([
                                        "step": .string("Inspect schema"),
                                        "status": .string("completed")
                                    ]),
                                    .dictionary([
                                        "step": .string("Render plan card"),
                                        "status": .string("inProgress")
                                    ])
                                ])
                            ]),
                            .dictionary([
                                "id": .string("mcp-1"),
                                "type": .string("mcpToolCall"),
                                "server": .string("filesystem"),
                                "tool": .string("read_file"),
                                "arguments": .dictionary(["path": .string("Package.swift")]),
                                "status": .string("completed"),
                                "result": .dictionary([
                                    "content": .array([
                                        .dictionary([
                                            "type": .string("text"),
                                            "text": .string("package contents")
                                        ])
                                    ])
                                ])
                            ])
                        ])
                    ]),
                    .dictionary([
                        "id": .string("turn-2"),
                        "startedAt": .int(2_000),
                        "items": .array([
                            .dictionary([
                                "id": .string("assistant-2"),
                                "type": .string("assistantMessage"),
                                "text": .string("Done."),
                                "phase": .string("final_answer")
                            ])
                        ])
                    ])
                ])
            ])
        ])

        let snapshot = CodexThreadHistorySnapshot(raw: response)

        XCTAssertEqual(snapshot.messages.map(\.role), [.user, .assistant, .terminal, .fileChange, .plan, .tool, .assistant])
        XCTAssertEqual(snapshot.messages[0].text, "Inspect the Swift app")
        XCTAssertEqual(snapshot.messages[1].text, "I checked the app-server surface.")
        XCTAssertEqual(snapshot.messages[1].detail, "commentary")
        XCTAssertEqual(snapshot.messages[2].commandRun?.command, "swift test")
        XCTAssertEqual(snapshot.messages[2].commandRun?.output, "All tests passed")
        XCTAssertEqual(snapshot.messages[2].commandRun?.exitCode, 0)
        XCTAssertEqual(snapshot.messages[2].commandRun?.cwd, "/tmp/CodexCore")
        XCTAssertEqual(snapshot.messages[3].fileChange?.path, "Sources/App.swift")
        XCTAssertEqual(snapshot.messages[3].fileChange?.addedLineCount, 1)
        XCTAssertEqual(snapshot.messages[3].fileChange?.removedLineCount, 1)
        XCTAssertEqual(snapshot.messages[4].planUpdate?.explanation, "Verify parity in small slices.")
        XCTAssertEqual(snapshot.messages[4].planUpdate?.steps.map(\.status), ["completed", "inProgress"])
        XCTAssertEqual(snapshot.messages[5].toolCall?.displayName, "filesystem.read_file")
        XCTAssertEqual(snapshot.messages[5].toolCall?.result, "package contents")
        XCTAssertEqual(snapshot.messages[6].detail, "final_answer")
    }

    func testThreadHistorySnapshotRestoresChildSubagentThreadHistory() throws {
        let parent: CodexJSONValue = .dictionary([
            "thread": .dictionary([
                "id": .string("thread-parent"),
                "turns": .array([
                    .dictionary([
                        "id": .string("turn-parent"),
                        "startedAt": .int(1_000),
                        "items": .array([
                            .dictionary([
                                "id": .string("spawn-1"),
                                "type": .string("collabAgentToolCall"),
                                "tool": .string("spawnAgent"),
                                "prompt": .string("Run child script"),
                                "receiverThreadIds": .array([.string("thread-child")]),
                                "agentsStates": .dictionary([
                                    "thread-child": .dictionary([
                                        "status": .string("running"),
                                        "agentNickname": .string("Ada"),
                                        "agentRole": .string("coder")
                                    ])
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])
        let child: CodexJSONValue = .dictionary([
            "thread": .dictionary([
                "id": .string("thread-child"),
                "agentNickname": .string("Ada"),
                "agentRole": .string("coder"),
                "turns": .array([
                    .dictionary([
                        "id": .string("turn-child"),
                        "status": .string("completed"),
                        "startedAt": .int(1_010),
                        "completedAt": .int(1_020),
                        "items": .array([
                            .dictionary([
                                "id": .string("child-user"),
                                "type": .string("userMessage"),
                                "content": .array([
                                    .dictionary([
                                        "type": .string("text"),
                                        "text": .string("Run child script")
                                    ])
                                ])
                            ]),
                            .dictionary([
                                "id": .string("child-command"),
                                "type": .string("commandExecution"),
                                "command": .array([.string("printf"), .string("42")]),
                                "aggregatedOutput": .string("42"),
                                "status": .string("completed"),
                                "exitCode": .int(0)
                            ]),
                            .dictionary([
                                "id": .string("child-answer"),
                                "type": .string("agentMessage"),
                                "text": .string("The script printed 42.")
                            ])
                        ])
                    ])
                ])
            ])
        ])

        var snapshot = CodexThreadHistorySnapshot(raw: parent)
        XCTAssertEqual(snapshot.subagentThreadIDs, ["thread-child"])

        XCTAssertTrue(snapshot.applyChildThread(raw: child))

        let subagent = try XCTUnwrap(snapshot.subagents.first)
        XCTAssertEqual(subagent.id, "thread-child")
        XCTAssertEqual(subagent.name, "Ada [coder]")
        XCTAssertEqual(subagent.status, .completed)
        XCTAssertEqual(subagent.messages.map(\.role), [.user, .terminal, .assistant])
        XCTAssertEqual(subagent.messages[0].text, "Run child script")
        XCTAssertEqual(subagent.messages[1].commandRun?.command, "printf 42")
        XCTAssertEqual(subagent.messages[1].commandRun?.output, "42")
        XCTAssertEqual(subagent.messages[2].text, "The script printed 42.")
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
