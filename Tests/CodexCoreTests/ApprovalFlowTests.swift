import XCTest
@testable import CodexCore

/// Tests for the escalated server-request approval flow: policy-driven
/// auto-answers and the `.ask` suspend-until-resolved path.
final class ApprovalFlowTests: XCTestCase {

    private func makeClient(
        policy: CodexApprovalPolicy
    ) async throws -> (client: CodexClient, store: CodexCoreStore, transport: MockTransport) {
        let transport = MockTransport()
        let store = await CodexCoreStore()
        let client = CodexClient(transport: transport, store: store, approvalPolicy: policy)
        try await client.connect()
        return (client, store, transport)
    }

    private func injectCommandApproval(
        _ transport: MockTransport,
        requestId: Int = 99,
        method: String = "item/commandExecution/requestApproval"
    ) async {
        let request = """
        {
            "jsonrpc": "2.0",
            "id": \(requestId),
            "method": "\(method)",
            "params": {
                "threadId": "thread-mock",
                "turnId": "turn-mock",
                "itemId": "item-1",
                "command": "rm -rf /tmp/scratch",
                "cwd": "/tmp",
                "reason": "cleanup"
            }
        }
        """
        await transport.receiveMessage(request)
    }

    /// Finds the JSON-RPC reply sent for a server request id, if any.
    private func reply(in transport: MockTransport, requestId: Int) async -> [String: CodexJSONValue]? {
        let payloads = await transport.sentPayloads
        return payloads.first { payload in
            payload["result"] != nil && payload["id"] == .int(requestId)
        }
    }

    private func waitForReply(
        in transport: MockTransport,
        requestId: Int,
        timeout: TimeInterval = 2.0
    ) async -> [String: CodexJSONValue]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = await reply(in: transport, requestId: requestId) {
                return found
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func decision(of reply: [String: CodexJSONValue]?) -> String? {
        guard case .dictionary(let result)? = reply?["result"],
              case .string(let decision)? = result["decision"] else { return nil }
        return decision
    }

    // MARK: - Auto policies

    func testAutoApprovePolicyAcceptsImmediately() async throws {
        let (client, store, transport) = try await makeClient(policy: .autoApprove)
        await injectCommandApproval(transport)

        let reply = await waitForReply(in: transport, requestId: 99)
        XCTAssertEqual(decision(of: reply), "accept")

        let pending = await store.pendingApprovals
        XCTAssertTrue(pending.isEmpty, "auto policies must not publish pending approvals")
        await client.disconnect()
    }

    func testAutoDeclinePolicyDeclinesImmediately() async throws {
        let (client, _, transport) = try await makeClient(policy: .autoDecline)
        await injectCommandApproval(transport)

        let reply = await waitForReply(in: transport, requestId: 99)
        XCTAssertEqual(decision(of: reply), "decline")
        await client.disconnect()
    }

    // MARK: - `.ask` policy

    func testAskPolicySuspendsReplyUntilResolved() async throws {
        let (client, store, transport) = try await makeClient(policy: .ask)
        await injectCommandApproval(transport)

        // The request must surface in the store...
        let deadline = Date().addingTimeInterval(2.0)
        while await store.pendingApprovals.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let pending = await store.pendingApprovals
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.kind, .command)
        XCTAssertEqual(pending.first?.command, "rm -rf /tmp/scratch")

        // ...and no reply may be sent while the decision is outstanding.
        try? await Task.sleep(for: .milliseconds(100))
        let premature = await reply(in: transport, requestId: 99)
        XCTAssertNil(premature, "reply must suspend until the host resolves the approval")

        // Resolving sends the user's actual decision.
        let resolved = await client.resolveApproval(requestId: pending[0].id, decision: .acceptForSession)
        XCTAssertTrue(resolved)

        let reply = await waitForReply(in: transport, requestId: 99)
        XCTAssertEqual(decision(of: reply), "acceptForSession")

        let remaining = await store.pendingApprovals
        XCTAssertTrue(remaining.isEmpty, "resolved approvals must clear from the store")
    }

    func testAskPolicyUserInputRoundTrip() async throws {
        let (client, store, transport) = try await makeClient(policy: .ask)

        let request = """
        {
            "jsonrpc": "2.0",
            "id": 12,
            "method": "item/tool/requestUserInput",
            "params": {
                "threadId": "thread-mock",
                "turnId": "turn-mock",
                "itemId": "item-9",
                "questions": [
                    {"id": "q1", "question": "Proceed with migration?", "options": [{"label": "Yes"}, {"label": "No"}]}
                ]
            }
        }
        """
        await transport.receiveMessage(request)

        let deadline = Date().addingTimeInterval(2.0)
        while await store.pendingUserInput == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let pendingInput = await store.pendingUserInput
        XCTAssertEqual(pendingInput?.questions.first?.id, "q1")

        await client.resolveUserInput(requestId: pendingInput!.id, answers: ["q1": ["Yes"]])

        let reply = await waitForReply(in: transport, requestId: 12)
        guard case .dictionary(let result)? = reply?["result"],
              case .dictionary(let answers)? = result["answers"],
              case .dictionary(let q1)? = answers["q1"],
              case .array(let values)? = q1["answers"] else {
            return XCTFail("unexpected user input reply shape: \(String(describing: reply))")
        }
        XCTAssertEqual(values, [.string("Yes")])

        let cleared = await store.pendingUserInput
        XCTAssertNil(cleared)
    }

    func testCancelPendingServerRequestsResolvesCancel() async throws {
        let (client, store, transport) = try await makeClient(policy: .ask)
        await injectCommandApproval(transport, requestId: 42)

        let deadline = Date().addingTimeInterval(2.0)
        while await store.pendingApprovals.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        await client.cancelPendingServerRequests()

        let reply = await waitForReply(in: transport, requestId: 42)
        XCTAssertEqual(decision(of: reply), "cancel")
    }

    func testServerResolvedNotificationReleasesPendingApproval() async throws {
        let (client, store, transport) = try await makeClient(policy: .ask)
        await injectCommandApproval(transport, requestId: 55)

        let deadline = Date().addingTimeInterval(2.0)
        while await store.pendingApprovals.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        // The server resolved the request itself (e.g. turn interrupted).
        let resolved = """
        {
            "jsonrpc": "2.0",
            "method": "serverRequest/resolved",
            "params": {"threadId": "thread-mock", "requestId": 55}
        }
        """
        await transport.receiveMessage(resolved)

        let reply = await waitForReply(in: transport, requestId: 55)
        XCTAssertEqual(decision(of: reply), "cancel")

        let clearDeadline = Date().addingTimeInterval(2.0)
        while await !store.pendingApprovals.isEmpty, Date() < clearDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let remaining = await store.pendingApprovals
        XCTAssertTrue(remaining.isEmpty, "server-resolved approvals must clear from the store")
        await client.disconnect()
    }

    func testResolveUnknownApprovalReturnsFalse() async throws {
        let (client, _, _) = try await makeClient(policy: .ask)
        let resolved = await client.resolveApproval(requestId: "nope", decision: .accept)
        XCTAssertFalse(resolved)
    }
}
