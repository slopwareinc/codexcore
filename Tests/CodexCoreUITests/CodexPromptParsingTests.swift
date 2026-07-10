import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexPromptParsingTests: XCTestCase {
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

    func testParsesCurrentOpenAIFormAndDeclinesUnsupportedFields() throws {
        let form = JSONRPCServerRequest(
            id: .int(7),
            method: CodexAppServerServerRequestMethod.mcpServerElicitationRequest.rawValue,
            params: [
                "serverName": .string("calendar"),
                "threadId": .string("thread-1"),
                "mode": .string("openai/form"),
                "message": .string("Choose event details"),
                "requestedSchema": .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "title": .dictionary(["type": .string("string"), "title": .string("Title")]),
                        "private": .dictionary(["type": .string("boolean"), "title": .string("Private")])
                    ]),
                    "required": .array([.string("title")])
                ])
            ]
        )
        let prompt = try XCTUnwrap(CodexInteractivePrompt(serverRequest: form))
        XCTAssertTrue(prompt.requiresElicitationForm)
        XCTAssertTrue(prompt.canAcceptElicitation)
        XCTAssertEqual(prompt.questions.map(\.id), ["private", "title"])
        XCTAssertFalse(prompt.isElicitationSubmissionValid(answers: ["private": "true"]))
        XCTAssertTrue(prompt.isElicitationSubmissionValid(answers: ["private": "true", "title": "Demo"]))
        XCTAssertEqual(prompt.elicitationResponse(answers: ["private": "true", "title": "Demo"]), .dictionary([
            "action": .string("accept"),
            "content": .dictionary(["private": .bool(true), "title": .string("Demo")]),
            "_meta": .null
        ]))

        let unsupported = try XCTUnwrap(CodexInteractivePrompt(serverRequest: JSONRPCServerRequest(
            id: .int(8),
            method: form.method,
            params: [
                "serverName": .string("calendar"),
                "threadId": .string("thread-1"),
                "mode": .string("openai/form"),
                "message": .string("Upload data"),
                "requestedSchema": .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "payload": .dictionary(["type": .string("object")])
                    ])
                ])
            ]
        )))
        XCTAssertFalse(unsupported.canAcceptElicitation)
        XCTAssertFalse(unsupported.requiresElicitationForm)
        XCTAssertTrue(unsupported.detail.contains("can only be declined"))

        let urlPrompt = try XCTUnwrap(CodexInteractivePrompt(serverRequest: JSONRPCServerRequest(
            id: .int(9),
            method: form.method,
            params: [
                "serverName": .string("calendar"),
                "threadId": .string("thread-1"),
                "mode": .string("url"),
                "message": .string("Open authorization page"),
                "url": .string("https://example.com/authorize"),
                "elicitationId": .string("elicit-1")
            ]
        )))
        XCTAssertFalse(urlPrompt.canAcceptElicitation)
        XCTAssertTrue(urlPrompt.detail.contains("can only be declined"))
    }
}
