import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexPromptStateSessionTests: XCTestCase {
    func testSyncDiffsApprovalAndUserInputPromptsFromStoreRequests() {
        var session = CodexPromptStateSession()
        let approval = approvalRequest(id: "approval-1", command: "git status")
        let userInput = userInputRequest(id: "input-1", question: "Which branch?")

        let firstActivities = session.sync(approvalRequests: [approval], userInput: userInput)

        XCTAssertEqual(session.approvalPrompts.map(\.id), ["approval-1"])
        XCTAssertEqual(session.approvalPrompts.first?.primaryValue, "git status")
        XCTAssertEqual(session.interactivePrompts.map(\.id), ["input-1"])
        XCTAssertEqual(firstActivities, [
            CodexPromptStateActivity(title: "Approval requested", detail: "git status"),
            CodexPromptStateActivity(title: "Input requested", detail: "Which branch?")
        ])

        XCTAssertEqual(session.sync(approvalRequests: [approval], userInput: userInput), [])

        let secondInput = userInputRequest(id: "input-2", question: "Ship it?")
        let secondActivities = session.sync(approvalRequests: [approval], userInput: secondInput)

        XCTAssertEqual(session.interactivePrompts.map(\.id), ["input-2"])
        XCTAssertEqual(secondActivities, [
            CodexPromptStateActivity(title: "Input requested", detail: "Ship it?")
        ])
    }

    func testAppliesBridgeEventsAndExplicitResolutions() throws {
        var session = CodexPromptStateSession(
            approvalPrompts: [CodexApprovalPrompt(request: approvalRequest(id: "approval-1", command: "swift test"))]
        )
        let prompt = try XCTUnwrap(CodexInteractivePrompt(serverRequest: userInputServerRequest()))

        XCTAssertEqual(session.apply(.added(prompt)), CodexPromptStateActivity(
            title: "Input requested",
            detail: "Continue?"
        ))
        XCTAssertEqual(session.interactivePromptKind(id: prompt.id), .userInput)
        XCTAssertEqual(session.responseTarget(forInteractivePromptID: prompt.id), .userInput)

        let approvalActivity = session.resolveApproval(id: "approval-1")
        XCTAssertEqual(approvalActivity, CodexPromptStateActivity(title: "Approval resolved", detail: "approval-1"))
        XCTAssertTrue(session.approvalPrompts.isEmpty)

        XCTAssertEqual(session.apply(.resolved(prompt.id)), CodexPromptStateActivity(
            title: "Input resolved",
            detail: prompt.id
        ))
        XCTAssertTrue(session.interactivePrompts.isEmpty)
    }

    func testInteractivePromptResponseTargetSeparatesStoreInputFromBridgeElicitation() throws {
        var session = CodexPromptStateSession()
        let userInputPrompt = try XCTUnwrap(CodexInteractivePrompt(serverRequest: userInputServerRequest()))
        let elicitationPrompt = try XCTUnwrap(CodexInteractivePrompt(serverRequest: elicitationServerRequest()))

        session.apply(.added(userInputPrompt))
        session.apply(.added(elicitationPrompt))

        XCTAssertEqual(session.responseTarget(forInteractivePromptID: userInputPrompt.id), .userInput)
        XCTAssertEqual(session.responseTarget(forInteractivePromptID: elicitationPrompt.id), .bridge)
        XCTAssertNil(session.responseTarget(forInteractivePromptID: "missing"))
    }

    func testInteractivePromptBridgePublishesAndResolvesServerRequests() async throws {
        let bridge = CodexInteractivePromptBridge()
        let request = userInputServerRequest()
        let expectedPrompt = try XCTUnwrap(CodexInteractivePrompt(serverRequest: request))
        let events = await bridge.events()
        let eventTask = Task {
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }
        let responseTask = Task {
            await bridge.handle(request)
        }

        let event = await eventTask.value
        guard case .added(let prompt)? = event else {
            return XCTFail("Expected added prompt event")
        }
        XCTAssertEqual(prompt.id, expectedPrompt.id)
        XCTAssertEqual(prompt.kind, expectedPrompt.kind)
        XCTAssertEqual(prompt.detail, expectedPrompt.detail)
        XCTAssertEqual(prompt.questions, expectedPrompt.questions)

        await bridge.resolveUserInput(id: expectedPrompt.id, answers: ["confirm": "yes"])
        let response = await responseTask.value
        XCTAssertEqual(response, .dictionary(["answers": .dictionary(["confirm": .string("yes")])]))
    }

    func testInteractivePromptBridgeSecondEventsCallFinishesPreviousStream() async throws {
        let bridge = CodexInteractivePromptBridge()
        let request = userInputServerRequest()
        let expectedPrompt = try XCTUnwrap(CodexInteractivePrompt(serverRequest: request))

        let firstEvents = await bridge.events()
        let firstFinished = expectation(description: "first stream finished")
        let firstTask = Task {
            var iterator = firstEvents.makeAsyncIterator()
            let event = await iterator.next()
            XCTAssertNil(event)
            firstFinished.fulfill()
        }

        let secondEvents = await bridge.events()
        await fulfillment(of: [firstFinished], timeout: 1)
        await firstTask.value

        let secondEventTask = Task {
            var iterator = secondEvents.makeAsyncIterator()
            return await iterator.next()
        }
        let responseTask = Task {
            await bridge.handle(request)
        }

        let event = await secondEventTask.value
        guard case .added(let prompt)? = event else {
            return XCTFail("Expected added prompt event on second stream")
        }
        XCTAssertEqual(prompt.id, expectedPrompt.id)

        await bridge.resolveUserInput(id: expectedPrompt.id, answers: ["confirm": "yes"])
        _ = await responseTask.value
    }

    func testInteractivePromptBridgeClearsContinuationOnTermination() async throws {
        let bridge = CodexInteractivePromptBridge()
        let request = userInputServerRequest()
        let expectedPrompt = try XCTUnwrap(CodexInteractivePrompt(serverRequest: request))

        do {
            let firstEvents = await bridge.events()
            let firstEventTask = Task {
                var iterator = firstEvents.makeAsyncIterator()
                return await iterator.next()
            }
            let firstResponseTask = Task {
                await bridge.handle(request)
            }

            let firstEvent = await firstEventTask.value
            guard case .added(let prompt)? = firstEvent else {
                return XCTFail("Expected added prompt event")
            }
            XCTAssertEqual(prompt.id, expectedPrompt.id)

            await bridge.resolveUserInput(id: expectedPrompt.id, answers: ["confirm": "yes"])
            _ = await firstResponseTask.value
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        let secondEvents = await bridge.events()
        let secondEventTask = Task {
            var iterator = secondEvents.makeAsyncIterator()
            return await iterator.next()
        }
        let secondResponseTask = Task {
            await bridge.handle(request)
        }

        let secondEvent = await secondEventTask.value
        guard case .added(let replayedPrompt)? = secondEvent else {
            return XCTFail("Expected prompt event after stream termination")
        }
        XCTAssertEqual(replayedPrompt.id, expectedPrompt.id)

        await bridge.resolveUserInput(id: expectedPrompt.id, answers: ["confirm": "yes"])
        _ = await secondResponseTask.value
    }

    @MainActor
    func testPromptEventSessionOwnsPollingAndBridgeEventTasks() async {
        let session = CodexPromptEventSession()
        var syncCount = 0
        let syncExpectation = expectation(description: "approval snapshot synced")
        session.startApprovalSnapshotMirror(
            intervalNanoseconds: 10_000_000,
            snapshot: {
                (
                    approvalRequests: [approvalRequest(id: "approval-1", command: "swift test")],
                    userInput: nil
                )
            },
            onSync: { approvals, userInput in
                XCTAssertEqual(approvals.map(\.requestId), [.string("approval-1")])
                XCTAssertNil(userInput)
                if syncCount == 0 {
                    syncExpectation.fulfill()
                }
                syncCount += 1
            }
        )
        await fulfillment(of: [syncExpectation], timeout: 1)

        var continuation: AsyncStream<CodexInteractivePromptEvent>.Continuation?
        let events = AsyncStream<CodexInteractivePromptEvent> { continuation = $0 }
        var receivedEvents: [CodexInteractivePromptEvent] = []
        let eventExpectation = expectation(description: "interactive prompt event delivered")
        session.consumeInteractivePromptEvents(events) { event in
            receivedEvents.append(event)
            eventExpectation.fulfill()
        }

        continuation?.yield(.resolved("prompt-1"))
        await fulfillment(of: [eventExpectation], timeout: 1)
        XCTAssertEqual(receivedEvents, [.resolved("prompt-1")])

        session.reset()
    }

    @MainActor
    func testPromptRuntimeSessionOwnsBridgePromptStateAndResolution() async throws {
        let runtime = CodexPromptRuntimeSession()
        let request = elicitationServerRequest()
        let expectedPrompt = try XCTUnwrap(CodexInteractivePrompt(serverRequest: request))
        var activities: [CodexPromptStateActivity] = []
        let addedExpectation = expectation(description: "bridge prompt added")
        let resolvedExpectation = expectation(description: "bridge prompt resolved")

        let ignoredResponse = await runtime.handleMCPServerElicitationRequest(userInputServerRequest())
        XCTAssertNil(ignoredResponse)
        let responseTask = Task {
            await runtime.handleMCPServerElicitationRequest(request)
        }

        runtime.startInteractivePromptEventListener { activity in
            activities.append(activity)
            switch activity.title {
            case "Input requested":
                addedExpectation.fulfill()
            case "Input resolved":
                resolvedExpectation.fulfill()
            default:
                break
            }
        }

        await fulfillment(of: [addedExpectation], timeout: 1)
        XCTAssertEqual(runtime.interactivePrompts.map(\.id), [expectedPrompt.id])
        XCTAssertEqual(activities.first, CodexPromptStateActivity(
            title: "Input requested",
            detail: "Allow Gmail connector access?"
        ))

        let submitActivity = await runtime.submitInteractivePrompt(
            id: expectedPrompt.id,
            answers: ["confirm": "yes"],
            using: nil
        )
        XCTAssertNil(submitActivity)

        await fulfillment(of: [resolvedExpectation], timeout: 1)
        XCTAssertTrue(runtime.interactivePrompts.isEmpty)
        let response = await responseTask.value
        XCTAssertEqual(response, .dictionary(["answers": .dictionary(["confirm": .string("yes")])]))

        runtime.reset()
        await runtime.cancelAllPrompts()
    }
}

private func approvalRequest(id: String, command: String) -> CodexApprovalRequest {
    CodexApprovalRequest(
        requestId: .string(id),
        kind: .command,
        threadId: "thread-1",
        turnId: "turn-1",
        itemId: "item-1",
        command: command,
        cwd: "/tmp/project",
        reason: "Inspect workspace"
    )
}

private func userInputRequest(id: String, question: String) -> CodexUserInputRequest {
    CodexUserInputRequest(
        requestId: .string(id),
        threadId: "thread-1",
        turnId: "turn-1",
        itemId: "item-1",
        questions: [
            CodexUserInputQuestion(id: "confirm", question: question)
        ]
    )
}

private func userInputServerRequest() -> JSONRPCServerRequest {
    JSONRPCServerRequest(
        id: .string("input-server-1"),
        method: CodexAppServerServerRequestMethod.itemToolRequestUserInput.rawValue,
        params: [
            "questions": .array([
                .dictionary([
                    "id": .string("confirm"),
                    "question": .string("Continue?")
                ])
            ])
        ]
    )
}

private func elicitationServerRequest() -> JSONRPCServerRequest {
    JSONRPCServerRequest(
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
                ])
            ])
        ]
    )
}
