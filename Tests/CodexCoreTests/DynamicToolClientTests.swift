import XCTest
@testable import CodexCore

final class DynamicToolClientTests: XCTestCase {
    @MainActor
    func testHighLevelThreadStartSendsDynamicTools() async throws {
        let transport = MockTransport()
        let store = CodexCoreStore()
        let codex = try await Codex(transport: transport, store: store)
        let tool = CodexDynamicToolSpec(
            name: "record_project_event",
            description: "Record project progress.",
            inputSchema: .dictionary(["type": .string("object")])
        )

        _ = try await codex.threadStart(
            cwd: "/tmp/walkable",
            dynamicTools: [tool],
            serviceName: "walkable"
        )

        let sentPayloads = await transport.sentPayloadsSnapshot()
        let threadStart = try XCTUnwrap(sentPayloads.last { payload in
            payload["method"] == .string(CodexAppServerClientMethod.threadStart.rawValue)
        })
        guard case .dictionary(let params)? = threadStart["params"] else {
            XCTFail("thread/start did not send object params")
            return
        }

        XCTAssertEqual(params["serviceName"], .string("walkable"))
        XCTAssertEqual(params["dynamicTools"], .array([
            .dictionary([
                "description": .string("Record project progress."),
                "inputSchema": .dictionary(["type": .string("object")]),
                "name": .string("record_project_event")
            ])
        ]))
    }

    @MainActor
    func testCustomServerRequestHandlerCanAnswerDynamicToolCall() async throws {
        let transport = MockTransport()
        let store = CodexCoreStore()
        let codex = try await Codex(
            transport: transport,
            store: store,
            serverRequestHandler: { request in
                guard let call = request.dynamicToolCall else { return nil }
                return CodexDynamicToolResponse.success(text: "handled \(call.tool)").jsonValue
            }
        )

        _ = try await codex.threadStart(cwd: "/tmp")
        await transport.receiveMessage("""
        {
            "jsonrpc": "2.0",
            "id": 9,
            "method": "item/tool/call",
            "params": {
                "threadId": "thread-mock",
                "turnId": "turn-mock",
                "itemId": "item-tool",
                "tool": "record_project_event",
                "arguments": { "title": "Started" }
            }
        }
        """)

        try await Task.sleep(for: .milliseconds(50))
        let sentPayloads = await transport.sentPayloadsSnapshot()
        let reply = try XCTUnwrap(sentPayloads.last { payload in
            payload["id"] == .int(9)
        })
        XCTAssertEqual(reply["result"], .dictionary([
            "success": .bool(true),
            "contentItems": .array([
                .dictionary([
                    "type": .string("inputText"),
                    "text": .string("handled record_project_event")
                ])
            ])
        ]))
    }

    @MainActor
    func testMCPToolAndResourceHelpersUseAppServerMethods() async throws {
        let transport = MockTransport()
        let store = CodexCoreStore()
        let codex = try await Codex(transport: transport, store: store)

        let toolResult = try await codex.mcpServerToolCall(
            threadId: "thread-mock",
            server: "filesystem",
            tool: "read_file",
            arguments: .dictionary(["path": .string("/tmp/readme.md")])
        )
        let resource = try await codex.mcpServerResourceRead(
            threadId: "thread-mock",
            server: "filesystem",
            uri: "file:///tmp/readme.md"
        )
        let sentPayloads = await transport.sentPayloadsSnapshot()

        XCTAssertEqual(toolResult.content.first, .dictionary(["type": .string("text"), "text": .string("MCP_OK")]))
        guard let firstResourceContent = resource.contents.first,
              case .dictionary(let resourceContent) = firstResourceContent.rawValue else {
            XCTFail("Expected resource content object")
            return
        }
        XCTAssertEqual(resourceContent["uri"], CodexJSONValue.string("file:///tmp/readme.md"))
        XCTAssertTrue(sentPayloads.contains { $0["method"] == .string(CodexAppServerClientMethod.mcpServerToolCall.rawValue) })
        XCTAssertTrue(sentPayloads.contains { $0["method"] == .string(CodexAppServerClientMethod.mcpServerResourceRead.rawValue) })
    }
}
