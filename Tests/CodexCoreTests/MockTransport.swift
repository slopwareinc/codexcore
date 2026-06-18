import Foundation
@testable import CodexCore

// MARK: - Mock Transport for Testing

actor MockTransport: CodexTransport {
    var isConnected = false
    var onMessage: (@Sendable (String) -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    var sentPayloads: [[String: CodexJSONValue]] = []
    private let suspendedMethods: Set<String>
    private var methodSendCounts: [String: Int] = [:]

    init(suspendedMethods: Set<String> = []) {
        self.suspendedMethods = suspendedMethods
    }

    func start(
        onMessage: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws {
        self.onMessage = onMessage
        self.onError = onError
        self.isConnected = true
    }

    func send(_ payload: [String: CodexJSONValue]) async throws {
        sentPayloads.append(payload)

        // Automatically respond to any JSON-RPC request containing an ID
        if let idVal = payload["id"], payload["method"] != nil {
            let method = payload["method"]?.description ?? ""
            guard !suspendedMethods.contains(method) else { return }
            methodSendCounts[method, default: 0] += 1
            let methodSendCount = methodSendCounts[method] ?? 0

            let reqIdString = idVal.description
            if method == "retry/overload", methodSendCount == 1 {
                let responseJson = """
                {
                    "jsonrpc": "2.0",
                    "id": \(reqIdString),
                    "error": {
                        "code": -32000,
                        "message": "server overloaded",
                        "data": { "codex_error_info": "server_overloaded" }
                    }
                }
                """
                Task { [weak self] in
                    guard let self else { return }
                    await self.receiveMessage(responseJson)
                }
                return
            }

            let result: String
            switch method {
            case "initialize":
                result = #"{"serverInfo":{"name":"codex","version":"1.0.0"},"userAgent":"codex/1.0.0"}"#
            case "account/login/start":
                let loginType: String? = {
                    guard case .dictionary(let params)? = payload["params"], case .string(let type)? = params["type"] else {
                        return nil
                    }
                    return type
                }()
                switch loginType {
                case "chatgpt":
                    result = #"{"type":"chatgpt","loginId":"login-mock","authUrl":"https://example.com/auth"}"#
                case "chatgptDeviceCode":
                    result = #"{"type":"chatgptDeviceCode","loginId":"login-mock","verificationUrl":"https://example.com/device","userCode":"ABCD-EFGH"}"#
                case "chatgptAuthTokens":
                    result = #"{"type":"chatgptAuthTokens"}"#
                default:
                    result = #"{"type":"apiKey"}"#
                }
            case "account/read":
                result = #"{"requiresOpenaiAuth":false,"account":null}"#
            case "account/rateLimits/read":
                result = #"{"rateLimits":{"primary":{"usedPercent":42}}}"#
            case "account/logout", "account/login/cancel", "thread/archive", "thread/name/set", "thread/compact/start", "turn/interrupt":
                result = "{}"
            case "thread/start":
                result = #"{"thread":{"id":"thread-mock"}}"#
            case "thread/resume":
                result = #"{"thread":{"id":"thread-resumed"}}"#
            case "thread/fork":
                result = #"{"thread":{"id":"thread-fork"}}"#
            case "thread/unarchive":
                result = #"{"thread":{"id":"thread-unarchived"}}"#
            case "thread/list":
                result = #"{"data":[{"id":"thread-mock","cliVersion":"1.0.0","createdAt":1781075531,"cwd":"/tmp","ephemeral":false,"modelProvider":"openai","preview":"Mock thread","sessionId":"session-mock","source":"cli","status":{"type":"idle"},"turns":[],"updatedAt":1781075531}],"nextCursor":null,"backwardsCursor":null}"#
            case "thread/search":
                result = #"{"data":[{"thread":{"id":"thread-mock","name":"Search hit","preview":"Matched preview","cliVersion":"1.0.0","createdAt":1781075531,"cwd":"/tmp","ephemeral":false,"modelProvider":"openai","parentThreadId":null,"sessionId":"session-mock","source":"cli","status":{"type":"idle"},"turns":[],"updatedAt":1781075531},"snippet":"needle in transcript"}],"nextCursor":null,"backwardsCursor":null}"#
            case "thread/read":
                result = #"{"thread":{"id":"thread-mock"}}"#
            case "thread/goal/set":
                result = #"{"goal":{"threadId":"thread-mock","objective":"Ship Swift goal parity","status":"active","tokenBudget":4096,"tokensUsed":0,"timeUsedSeconds":0,"createdAt":1781075531,"updatedAt":1781075531}}"#
            case "thread/goal/get":
                result = #"{"goal":{"threadId":"thread-mock","objective":"Ship Swift goal parity","status":"active","tokenBudget":4096,"tokensUsed":12,"timeUsedSeconds":3,"createdAt":1781075531,"updatedAt":1781075540}}"#
            case "thread/goal/clear":
                result = #"{"cleared":true}"#
            case "turn/start":
                result = #"{"turn":{"id":"turn-mock"}}"#
            case "turn/steer":
                result = #"{"turnId":"turn-mock"}"#
            case "review/start":
                result = #"{"reviewThreadId":"review-thread-mock","turn":{"id":"turn-review-mock","items":[],"status":"inProgress"}}"#
            case "skills/list":
                result = #"{"data":[{"cwd":"/tmp","skills":[{"name":"resume-from-opencode","description":"Resume an OpenCode session","interface":{"displayName":"Resume OpenCode","shortDescription":"Resume a prior OpenCode run","defaultPrompt":"Resume the last OpenCode session."},"path":"/tmp/skills/resume-from-opencode/SKILL.md","scope":"user","enabled":true}],"errors":[]}]}"#
            case "permissionProfile/list":
                result = #"{"data":[{"id":":read-only","description":null},{"id":":workspace","description":null},{"id":":danger-full-access","description":null}],"nextCursor":null}"#
            case "collaborationMode/list":
                result = #"{"data":[{"name":"Plan","mode":"plan","model":null,"reasoning_effort":"medium"},{"name":"Default","mode":"default","model":null,"reasoning_effort":null}]}"#
            case "mcpServerStatus/list":
                result = #"{"data":[{"name":"filesystem","authStatus":"unsupported","serverInfo":{"name":"filesystem","title":"Filesystem","version":"1.0.0","description":"Local files"},"tools":{"read_file":{"name":"read_file","title":"Read file","description":"Read a file","inputSchema":{"type":"object"}}},"resources":[{"name":"workspace","uri":"file:///tmp"}],"resourceTemplates":[{"name":"repo-file","uriTemplate":"file:///{path}"}]}],"nextCursor":null}"#
            case "mcpServer/tool/call":
                result = #"{"content":[{"type":"text","text":"MCP_OK"}],"isError":false}"#
            case "mcpServer/resource/read":
                result = #"{"contents":[{"uri":"file:///tmp/readme.md","mimeType":"text/markdown","text":"Hello"}]}"#
            case "plugin/list":
                result = #"{"marketplaces":[{"name":"local","interface":{"displayName":"Local"},"path":"/tmp/marketplace.json","plugins":[{"authPolicy":"ON_USE","enabled":true,"id":"resume-from-opencode","installPolicy":"INSTALLED_BY_DEFAULT","installed":true,"name":"resume-from-opencode","source":{"type":"local","path":"/tmp/plugins/resume"},"availability":"AVAILABLE","interface":{"displayName":"Resume OpenCode","shortDescription":"Resume an OpenCode run","capabilities":["skills"],"screenshots":[],"screenshotUrls":[]},"keywords":["agents"],"localVersion":"1.0.0"}]}],"marketplaceLoadErrors":[],"featuredPluginIds":[]}"#
            case "model/list":
                result = #"{"data":[{"id":"gpt-5.5","model":"gpt-5.5","displayName":"GPT-5.5","description":"Frontier model for complex coding, research, and real-world work.","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast responses with lighter reasoning"},{"reasoningEffort":"medium","description":"Balances speed and reasoning depth for everyday tasks"},{"reasoningEffort":"high","description":"Greater reasoning depth for complex problems"},{"reasoningEffort":"xhigh","description":"Extra high reasoning depth for complex problems"}],"defaultReasoningEffort":"medium","inputModalities":["text","image"],"supportsPersonality":true,"additionalSpeedTiers":["fast"],"serviceTiers":[{"id":"priority","name":"Fast","description":"1.5x speed, increased usage"}],"defaultServiceTier":null,"isDefault":true},{"id":"gpt-5.4-mini","model":"gpt-5.4-mini","displayName":"GPT-5.4-Mini","description":"Small, fast, and cost-efficient model for simpler coding tasks.","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast responses with lighter reasoning"},{"reasoningEffort":"medium","description":"Balances speed and reasoning depth for everyday tasks"}],"defaultReasoningEffort":"medium","inputModalities":["text","image"],"supportsPersonality":true,"additionalSpeedTiers":[],"serviceTiers":[],"defaultServiceTier":null,"isDefault":false},{"id":"codex-auto-review","model":"codex-auto-review","displayName":"Codex Auto Review","description":"Automatic approval review model for Codex.","hidden":true,"supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Balances speed and reasoning depth for everyday tasks"}],"defaultReasoningEffort":"medium","inputModalities":["text","image"],"supportsPersonality":true,"additionalSpeedTiers":[],"serviceTiers":[],"defaultServiceTier":null,"isDefault":false}],"nextCursor":null}"#
            case "fuzzyFileSearch":
                result = #"{"files":[{"file_name":"Client.swift","match_type":"file","path":"Sources/CodexCore/Client/Client.swift","root":"/repo","score":0.91,"indices":[0,1,2]},{"file_name":"Codex.swift","match_type":"file","path":"Sources/CodexCore/Client/Codex.swift","root":"/repo","score":0.72}]}"#
            case "command/exec":
                result = #"{"exitCode":0,"stdout":"COMMAND_OK\n","stderr":""}"#
            case "retry/overload":
                result = #"{"ok":true}"#
            default:
                result = "{}"
            }

            let responseJson = """
            {
                "jsonrpc": "2.0",
                "id": \(reqIdString),
                "result": \(result)
            }
            """
            Task { [weak self] in
                guard let self else { return }
                await self.receiveMessage(responseJson)
            }
        }
    }

    func stop() async {
        isConnected = false
    }

    func sentPayloadsSnapshot() -> [[String: CodexJSONValue]] {
        sentPayloads
    }

    func receiveMessage(_ msg: String) {
        onMessage?(msg)
    }

    func fail(_ error: Error) {
        isConnected = false
        onError?(error)
    }
}
