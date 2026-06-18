import Foundation

/// A client-provided tool advertised to Codex app-server when a thread starts.
public struct CodexDynamicToolSpec: Codable, Sendable, Equatable {
    public var deferLoading: Bool?
    public var description: String
    public var inputSchema: CodexJSONValue
    public var name: String
    public var namespace: String?

    public init(
        name: String,
        description: String,
        inputSchema: CodexJSONValue,
        namespace: String? = nil,
        deferLoading: Bool? = nil
    ) {
        self.deferLoading = deferLoading
        self.description = description
        self.inputSchema = inputSchema
        self.name = name
        self.namespace = namespace
    }
}

/// A server request asking the host app to execute one of its dynamic tools.
public struct CodexDynamicToolCall: Sendable, Equatable {
    public var requestID: CodexJSONValue
    public var threadID: String?
    public var turnID: String?
    public var itemID: String?
    public var tool: String
    public var arguments: CodexJSONValue?
    public var params: [String: CodexJSONValue]

    public init?(_ serverRequest: JSONRPCServerRequest) {
        guard serverRequest.method == CodexAppServerServerRequestMethod.itemToolCall.rawValue else {
            return nil
        }
        guard case .string(let tool)? = serverRequest.params["tool"], !tool.isEmpty else {
            return nil
        }

        self.requestID = serverRequest.id
        self.threadID = Self.stringValue(serverRequest.params["threadId"])
        self.turnID = Self.stringValue(serverRequest.params["turnId"])
        self.itemID = Self.stringValue(serverRequest.params["itemId"])
        self.tool = tool
        self.arguments = serverRequest.params["arguments"]
        self.params = serverRequest.params
    }

    public var argumentsObject: [String: CodexJSONValue]? {
        guard case .dictionary(let object)? = arguments else { return nil }
        return object
    }

    private static func stringValue(_ value: CodexJSONValue?) -> String? {
        guard case .string(let string)? = value, !string.isEmpty else { return nil }
        return string
    }
}

public enum CodexDynamicToolContentItem: Sendable, Equatable {
    case inputText(String)
    case raw(CodexJSONValue)

    public var jsonValue: CodexJSONValue {
        switch self {
        case .inputText(let text):
            return .dictionary([
                "type": .string("inputText"),
                "text": .string(text)
            ])
        case .raw(let value):
            return value
        }
    }
}

/// The JSON-RPC result for `item/tool/call`.
public struct CodexDynamicToolResponse: Sendable, Equatable {
    public var success: Bool
    public var contentItems: [CodexDynamicToolContentItem]

    public init(
        success: Bool = true,
        contentItems: [CodexDynamicToolContentItem]
    ) {
        self.success = success
        self.contentItems = contentItems
    }

    public static func success(text: String) -> CodexDynamicToolResponse {
        CodexDynamicToolResponse(success: true, contentItems: [.inputText(text)])
    }

    public static func failure(text: String) -> CodexDynamicToolResponse {
        CodexDynamicToolResponse(success: false, contentItems: [.inputText(text)])
    }

    public var jsonValue: CodexJSONValue {
        .dictionary([
            "success": .bool(success),
            "contentItems": .array(contentItems.map(\.jsonValue))
        ])
    }
}

public extension JSONRPCServerRequest {
    var dynamicToolCall: CodexDynamicToolCall? {
        CodexDynamicToolCall(self)
    }
}
