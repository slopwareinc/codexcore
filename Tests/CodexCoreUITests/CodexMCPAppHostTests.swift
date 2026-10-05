import AppKit
import WebKit
import XCTest
import CodexCore
@testable import CodexCoreUI

@MainActor final class CodexMCPAppHostTests: XCTestCase {
    func testCanonicalDescriptorRetainsPersistedModeAndAuthoritativeScope() throws {
        let item = CanonicalItem(key: .init(threadID: "thread", turnID: "turn", itemID: "call"), kind: .mcpToolCall, payload: [
            "server": .string("apps"), "tool": .string("show"), "arguments": .dictionary(["query": .string("one")]),
            "result": .dictionary(["content": .array([])]),
            "mcpAppUi": .dictionary(["resourceUri": .string("ui://app/widget"), "preferredModelDisplayMode": .string("fullscreen")]),
            "appContext": .dictionary(["connectorId": .string("connector"), "linkId": .string("account")]),
        ], lastChangedRevision: .init(8))
        let descriptor = try XCTUnwrap(CodexMCPAppDescriptor.project(item: item, appName: "Example"))
        XCTAssertEqual(descriptor.preferredDisplayMode, .fullscreen)
        XCTAssertEqual(descriptor.originCallID, "call")
        XCTAssertEqual(descriptor.revision, 8)
        guard case .mcpResourceRead(let params) = descriptor.resourceRequest() else { return XCTFail("Expected resource read") }
        XCTAssertEqual(params.threadID, "thread")
        XCTAssertEqual(params.originCallID, "call")
        XCTAssertEqual(params.server, "apps")
        XCTAssertEqual(params.target, .init(connectorID: "connector", linkID: "account"))
    }

    func testUnknownPersistedModeKeepsFallbackResource() throws {
        let item = CanonicalItem(key: .init(threadID: "thread", turnID: "turn", itemID: "call"), kind: .mcpToolCall, payload: [
            "server": .string("apps"), "mcpAppResourceUri": .string("ui://app/fallback"),
            "mcpAppUi": .dictionary(["preferredModelDisplayMode": .string("future")]),
        ])
        let descriptor = try XCTUnwrap(CodexMCPAppDescriptor.project(item: item, appName: "App"))
        XCTAssertEqual(descriptor.resourceURI, "ui://app/fallback")
        XCTAssertEqual(descriptor.preferredDisplayMode, .inline)
    }

    func testPersistedNoAuthAccountScopeEmitsExplicitLinkNull() throws {
        let descriptor = CodexMCPAppDescriptor(threadID: "thread", originCallID: "call", server: "apps", tool: "show", appName: "App",
                                               resourceURI: "ui://app/widget", connectorID: "public-app", linkID: nil, hasExplicitAccountScope: true)
        guard case .mcpResourceRead(let params) = descriptor.resourceRequest() else { return XCTFail("Expected read") }
        let value = try CodexJSONValue(encoding: params)
        XCTAssertEqual(value.objectValue?["target"]?.objectValue?["linkId"], .null)
        XCTAssertEqual(params.originCallID, "call")
        XCTAssertNil(params.connectorID)
    }

    func testUnknownAccountScopeRetainsDiscoveryRatherThanInferringNoAuth() {
        let descriptor = CodexMCPAppDescriptor(threadID: "thread", originCallID: "call", server: "apps", tool: "show", appName: "App",
                                               resourceURI: "ui://app/widget", connectorID: "unknown-account")
        guard case .mcpResourceRead(let params) = descriptor.resourceRequest() else { return XCTFail("Expected read") }
        XCTAssertNil(params.target)
        XCTAssertEqual(params.connectorID, "unknown-account")
    }

    func testOlderHistoryDiscoversOnlySameServerToolFromCatalog() throws {
        let server = try XCTUnwrap(CodexMCPServerStatus(raw: .dictionary([
            "name": .string("apps"), "authStatus": .string("unsupported"), "resources": .array([]), "resourceTemplates": .array([]),
            "tools": .dictionary(["show": .dictionary(["name": .string("show"), "inputSchema": .dictionary([:]),
                                                        "_meta": .dictionary(["ui": .dictionary(["resourceUri": .string("ui://app/widget")])])])]),
        ])))
        let catalog = CodexMCPAppCatalogResource.catalog(from: [server])
        let row = CodexMCPToolCallRowV2(id: "old-call", appName: "App", server: "apps", tool: "show", status: .completed,
                                      appContext: .dictionary(["connectorId": .string("public"), "linkId": .null]))
        let discovered = try XCTUnwrap(CodexMCPAppDescriptor.discover(row: row, threadID: "thread", catalog: catalog))
        XCTAssertEqual(discovered.resourceURI, "ui://app/widget")
        XCTAssertEqual(discovered.originCallID, "old-call")
        XCTAssertTrue(discovered.hasExplicitAccountScope)
        XCTAssertNil(CodexMCPAppDescriptor.discover(row: row, threadID: "thread", catalog: [.init(server: "other", tool: "show", resourceURI: "ui://evil")]))
    }

    func testResourceRequiresMatchingUIURIAndMIMEAndBounds() throws {
        XCTAssertThrowsError(try CodexMCPAppResource(response: resource(), uri: "https://example.com"))
        XCTAssertThrowsError(try CodexMCPAppResource(response: resource(uri: "ui://other"), uri: "ui://app/widget"))
        XCTAssertThrowsError(try CodexMCPAppResource(response: resource(mime: "text/html"), uri: "ui://app/widget"))
        XCTAssertThrowsError(try CodexMCPAppResource(response: resource(html: String(repeating: "a", count: CodexMCPAppResource.maximumBytes + 1)), uri: "ui://app/widget"))
        let decoded = try CodexMCPAppResource(response: .dictionary(["contents": .array([.dictionary([
            "uri": .string("ui://app/widget"), "mimeType": .string("text/html;profile=mcp-app"),
            "blob": .string(Data("<html>decoded</html>".utf8).base64EncodedString()),
        ])])]), uri: "ui://app/widget")
        XCTAssertEqual(decoded.html, "<html>decoded</html>")
    }

    func testCSPRejectsDirectiveInjectionWildcardAndUnsafeSchemes() throws {
        for origin in ["https://example.com; script-src *", "https://*.example.com", "http://example.com", "file:///etc", "https://example.com/path", "https://user:secret@example.com"] {
            XCTAssertThrowsError(try CodexMCPAppCSP(metadata: csp(["connectDomains": .array([.string(origin)])])))
        }
        let policy = try CodexMCPAppCSP(metadata: csp(["connectDomains": .array([.string("https://api.example.com"), .string("wss://api.example.com")]),
                                                     "resourceDomains": .array([.string("https://cdn.example.com")])]))
        XCTAssertTrue(policy.policy.contains("connect-src https://api.example.com wss://api.example.com"))
        XCTAssertTrue(policy.policy.contains("frame-src 'none'"))
        let restrictive = try CodexMCPAppCSP(metadata: nil)
        XCTAssertTrue(restrictive.policy.contains("connect-src 'none'"))
        XCTAssertTrue(restrictive.policy.contains("base-uri 'none'"))
        let html = try CodexMCPAppResource(response: resource(html: "<script>parent.evil=1</script>"), uri: "ui://app/widget").wrapperHTML()
        XCTAssertTrue(html.contains("sandbox=\"allow-scripts\""))
        XCTAssertFalse(html.contains("allow-same-origin"))
        XCTAssertFalse(html.contains("parent.evil"))
    }

    func testHandshakeWaitsForInitializedBeforeSendingInputAndResult() async throws {
        let bridge = makeBridge()
        await bridge.load()
        let early = await bridge.handle(rpc("tools/call", params: ["name": .string("show")]))
        XCTAssertNotNil(early.first?.objectValue?["error"])
        let response = await bridge.handle(initializeRequest())
        XCTAssertEqual(response.count, 1)
        XCTAssertEqual(response.first?.objectValue?["result"]?.objectValue?["protocolVersion"], .string("2026-01-26"))
        let notifications = await bridge.handle(.dictionary(["jsonrpc": .string("2.0"), "method": .string("ui/notifications/initialized")]))
        XCTAssertEqual(notifications.map { $0.objectValue?["method"] }, [.string("ui/notifications/tool-input"), .string("ui/notifications/tool-result")])
        let repeated = await bridge.handle(.dictionary(["jsonrpc": .string("2.0"), "method": .string("ui/notifications/initialized")]))
        XCTAssertTrue(repeated.isEmpty)
    }

    func testScopeOverrideAndModelOnlyToolAreRejectedWithoutExecution() async throws {
        let recorder = MCPAppRecorder()
        let provider = MCPAppProvider { request in
            await recorder.append(request)
            if case .mcpStatusList = request { return try selfInventory(visibility: [.string("model")]) }
            return resource()
        }
        let bridge = makeBridge(provider: provider)
        await prepare(bridge)
        let override = await bridge.handle(rpc("resources/read", params: ["uri": .string("secret"), "server": .string("other")]))
        XCTAssertNotNil(override.first?.objectValue?["error"])
        let modelOnly = await bridge.handle(rpc("tools/call", params: ["name": .string("show")]))
        XCTAssertNotNil(modelOnly.first?.objectValue?["error"])
        let calls = await recorder.requests
        XCTAssertEqual(calls.map(\.operationID), ["mcpServer/resource/read", "mcpServerStatus/list"])
        XCTAssertNil(bridge.confirmation)
    }

    func testConfirmedAppToolCallUsesOriginalServerAndThread() async throws {
        let recorder = MCPAppRecorder()
        let provider = MCPAppProvider { request in
            await recorder.append(request)
            switch request {
            case .mcpStatusList: return try selfInventory(visibility: [.string("app")])
            case .mcpToolCall: return .dictionary(["content": .array([]), "structuredContent": .dictionary(["ok": .bool(true)])])
            default: return resource()
            }
        }
        let bridge = makeBridge(provider: provider)
        await prepare(bridge)
        let pending = Task { await bridge.handle(rpc("tools/call", params: ["name": .string("show"), "arguments": .dictionary(["value": .int(1)])])) }
        try await waitForConfirmation(bridge)
        bridge.resolveConfirmation(true)
        let response = await pending.value
        XCTAssertNotNil(response.first?.objectValue?["result"])
        let requests = await recorder.requests
        guard case .mcpToolCall(let params) = requests.last else { return XCTFail("Tool was not called") }
        XCTAssertEqual(params.server, "apps")
        XCTAssertEqual(params.threadID, "thread")
        XCTAssertEqual(params.tool, "show")
        XCTAssertEqual(params.arguments, .dictionary(["value": .int(1)]))
    }

    func testCancellingPendingApprovalDoesNotExecuteOrLeakContinuation() async throws {
        let recorder = MCPAppRecorder()
        let bridge = makeBridge(provider: MCPAppProvider { request in await recorder.append(request); return resource() })
        await prepare(bridge)
        let pending = Task { await bridge.handle(rpc("resources/read", params: ["uri": .string("resource://extra")])) }
        try await waitForConfirmation(bridge)
        pending.cancel()
        _ = await pending.value
        XCTAssertNil(bridge.confirmation)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testContextUpdateIsScopedValidatedAndBounded() async throws {
        var updates: [(CodexMCPAppDescriptor, CodexJSONValue)] = []
        let bridge = makeBridge(onContext: { updates.append(($0, $1)) })
        await prepare(bridge)
        let content: CodexJSONValue = .array([.dictionary(["type": .string("text"), "text": .string("Selected filter")])])
        let response = await bridge.handle(rpc("ui/update-model-context", params: ["content": content, "structuredContent": .dictionary(["filter": .string("one")])]))
        XCTAssertNotNil(response.first?.objectValue?["result"])
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.0.threadID, "thread")
        XCTAssertEqual(updates.first?.1.objectValue?["content"], content)
        let invalid = await bridge.handle(rpc("ui/update-model-context", params: ["content": .string("invalid")]))
        XCTAssertNotNil(invalid.first?.objectValue?["error"])
        let oversized = await bridge.handle(rpc("ui/update-model-context", params: ["structuredContent": .dictionary(["huge": .string(String(repeating: "a", count: 17_000))])]))
        XCTAssertNotNil(oversized.first?.objectValue?["error"])
        XCTAssertEqual(updates.count, 1)
    }

    func testDisplayModeChecksDeclaredAppCapabilities() async {
        var opened = 0
        let bridge = makeBridge(onFullscreen: { _ in opened += 1 })
        await prepare(bridge)
        let changed = await bridge.handle(rpc("ui/request-display-mode", params: ["mode": .string("fullscreen")]))
        XCTAssertEqual(changed.first?.objectValue?["result"]?.objectValue?["mode"], .string("fullscreen"))
        XCTAssertEqual(opened, 1)
        let unsupported = await bridge.handle(rpc("ui/request-display-mode", params: ["mode": .string("pip")]))
        XCTAssertEqual(unsupported.first?.objectValue?["result"]?.objectValue?["mode"], .string("inline"))
    }

    func testSandboxedWebViewRunsActualMCPHandshake() async throws {
        let document = """
        <!doctype html><html><body><script>
        window.addEventListener('message',e=>{
          if(e.data.id===1&&e.data.result)parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/initialized'},'*');
          if(e.data.method==='ui/notifications/tool-input')parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/size-changed',params:{width:400,height:277}},'*');
        });
        parent.postMessage({jsonrpc:'2.0',id:1,method:'ui/initialize',params:{protocolVersion:'2026-01-26',appCapabilities:{}}},'*');
        </script></body></html>
        """
        let bridge = makeBridge(provider: MCPAppProvider { _ in resource(html: document) })
        await bridge.load()
        let content = try XCTUnwrap(bridge.resource)
        let coordinator = CodexMCPAppWebView.Coordinator(bridge: bridge, theme: "dark")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, name: "codexMCPApp")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 320), configuration: configuration)
        coordinator.webView = webView
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.loadHTMLString(content.wrapperHTML(), baseURL: nil)
        defer { coordinator.stop(); configuration.userContentController.removeScriptMessageHandler(forName: "codexMCPApp"); webView.stopLoading() }
        for _ in 0..<500 where bridge.preferredHeight != 277 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(bridge.preferredHeight, 277, "The isolated document must finish real initialization and receive tool input.")
    }

    private func makeBridge(provider: any CodexIntegrationControlPlaneProvider = MCPAppProvider { _ in resource() },
                            onFullscreen: (@MainActor (CodexMCPAppDescriptor) -> Void)? = nil,
                            onContext: (@MainActor (CodexMCPAppDescriptor, CodexJSONValue) -> Void)? = nil) -> CodexMCPAppBridge {
        .init(descriptor: .init(threadID: "thread", originCallID: "call", server: "apps", tool: "show", appName: "Example",
                               resourceURI: "ui://app/widget", arguments: .dictionary(["value": .int(1)]), result: .dictionary(["content": .array([])])),
              provider: provider, displayMode: .inline, onFullscreen: onFullscreen, onUpdateContext: onContext)
    }

    private func prepare(_ bridge: CodexMCPAppBridge) async {
        await bridge.load()
        _ = await bridge.handle(initializeRequest())
        _ = await bridge.handle(.dictionary(["jsonrpc": .string("2.0"), "method": .string("ui/notifications/initialized")]))
    }
    private func waitForConfirmation(_ bridge: CodexMCPAppBridge) async throws {
        for _ in 0..<100 where bridge.confirmation == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(bridge.confirmation)
    }
}

private func rpc(_ method: String, params: [String: CodexJSONValue] = [:]) -> CodexJSONValue {
    .dictionary(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string(method), "params": .dictionary(params)])
}
private func initializeRequest() -> CodexJSONValue {
    rpc("ui/initialize", params: ["protocolVersion": .string("2026-01-26"),
                                  "appCapabilities": .dictionary(["availableDisplayModes": .array([.string("inline"), .string("fullscreen")])])])
}
private func csp(_ fields: [String: CodexJSONValue]) -> CodexJSONValue { .dictionary(["ui": .dictionary(["csp": .dictionary(fields)])]) }
private func resource(uri: String = "ui://app/widget", mime: String = "text/html;profile=mcp-app", html: String = "<html>Widget</html>") -> CodexJSONValue {
    .dictionary(["contents": .array([.dictionary(["uri": .string(uri), "mimeType": .string(mime), "text": .string(html)])])])
}
private func selfInventory(visibility: [CodexJSONValue]) throws -> CodexJSONValue {
    try CodexJSONValue(encoding: CodexSchemaListMCPServerStatusResponse(data: [.init(authStatus: .unsupported, name: "apps", resourceTemplates: [], resources: [],
                                                                               tools: ["show": .init(meta: .dictionary(["ui": .dictionary(["visibility": .array(visibility)])]), inputSchema: .dictionary([:]), name: "show")])]))
}
private struct MCPAppProvider: CodexIntegrationControlPlaneProvider {
    let action: @Sendable (CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue
    init(_ action: @escaping @Sendable (CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue) { self.action = action }
    func perform(_ request: CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue { try await action(request) }
}
private actor MCPAppRecorder {
    var requests: [CodexIntegrationControlPlaneRequest] = []
    func append(_ request: CodexIntegrationControlPlaneRequest) { requests.append(request) }
}
