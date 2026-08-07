import Foundation
import CodexCore

/// The app-server operations used by the integration management surfaces.
///
/// MCP add/edit/remove is implemented through the generated `config/value/write`
/// method followed by the generated `config/mcpServer/reload` method. There is
/// no separate MCP CRUD RPC in the current protocol inventory.
public enum CodexIntegrationControlPlaneRequest: Equatable, Sendable {
    case mcpOAuthLogin(CodexSchemaMCPServerOAuthLoginParams)
    case mcpStatusList(CodexSchemaListMCPServerStatusParams)
    case mcpReload
    case configValueWrite(CodexSchemaConfigValueWriteParams)

    public var operationID: String {
        switch self {
        case .mcpOAuthLogin: "mcpServer/oauth/login"
        case .mcpStatusList: "mcpServerStatus/list"
        case .mcpReload: "config/mcpServer/reload"
        case .configValueWrite: "config/value/write"
        }
    }
}

public protocol CodexIntegrationControlPlaneProvider: Sendable {
    func perform(_ request: CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue
}

public struct CodexAppServerIntegrationControlPlaneProvider: CodexIntegrationControlPlaneProvider {
    private let codex: Codex

    public init(codex: Codex) {
        self.codex = codex
    }

    public func perform(_ request: CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue {
        switch request {
        case .mcpOAuthLogin(let params):
            return try CodexJSONValue(encoding: await codex.mcpServerOAuthLogin(params))
        case .mcpStatusList(let params):
            return try CodexJSONValue(encoding: await codex.mcpServerStatusList(params))
        case .mcpReload:
            return try await codex.configMCPServerReload()
        case .configValueWrite(let params):
            return try await codex.configValueWrite(params)
        }
    }
}

public struct CodexUnsupportedIntegrationControlPlaneProvider: CodexIntegrationControlPlaneProvider {
    public init() {}

    public func perform(_ request: CodexIntegrationControlPlaneRequest) async throws -> CodexJSONValue {
        throw CodexIntegrationControlPlaneError("Connect to Codex before changing MCP servers.")
    }
}

public struct CodexIntegrationControlPlaneError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// A configuration accepted by Codex's `mcp_servers.<name>` config object.
/// The wire value is deliberately represented as raw JSON because the generated
/// protocol has no typed MCP configuration object.
public struct CodexMCPServerConfiguration: Identifiable, Equatable, Sendable {
    public enum Transport: String, CaseIterable, Equatable, Sendable {
        case stdio
        case streamableHTTP = "streamable_http"
    }

    public var name: String
    public var enabled: Bool
    public var transport: Transport
    public var command: String
    public var arguments: [String]
    public var url: String
    public var environment: [String: String]
    public var httpHeaders: [String: String]
    public var bearerTokenEnvironmentVariable: String?
    public var enabledTools: [String]?
    public var disabledTools: [String]
    public var startupTimeoutSeconds: Int?
    public var toolTimeoutSeconds: Int?

    public var id: String { name }

    public init(
        name: String,
        enabled: Bool = true,
        transport: Transport = .stdio,
        command: String = "",
        arguments: [String] = [],
        url: String = "",
        environment: [String: String] = [:],
        httpHeaders: [String: String] = [:],
        bearerTokenEnvironmentVariable: String? = nil,
        enabledTools: [String]? = nil,
        disabledTools: [String] = [],
        startupTimeoutSeconds: Int? = nil,
        toolTimeoutSeconds: Int? = nil
    ) {
        self.name = name
        self.enabled = enabled
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.environment = environment
        self.httpHeaders = httpHeaders
        self.bearerTokenEnvironmentVariable = bearerTokenEnvironmentVariable
        self.enabledTools = enabledTools
        self.disabledTools = disabledTools
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.toolTimeoutSeconds = toolTimeoutSeconds
    }

    /// Encodes only fields supported by the current Codex config schema.
    public var configValue: CodexJSONValue {
        var value: [String: CodexJSONValue] = ["enabled": .bool(enabled)]
        switch transport {
        case .stdio:
            value["command"] = .string(command)
            if !arguments.isEmpty { value["args"] = .array(arguments.map(CodexJSONValue.string)) }
            if !environment.isEmpty { value["env"] = .dictionary(environment.mapValues(CodexJSONValue.string)) }
        case .streamableHTTP:
            value["url"] = .string(url)
            if !httpHeaders.isEmpty { value["http_headers"] = .dictionary(httpHeaders.mapValues(CodexJSONValue.string)) }
            if let bearerTokenEnvironmentVariable {
                value["bearer_token_env_var"] = .string(bearerTokenEnvironmentVariable)
            }
        }
        if let enabledTools { value["enabled_tools"] = .array(enabledTools.map(CodexJSONValue.string)) }
        if !disabledTools.isEmpty { value["disabled_tools"] = .array(disabledTools.map(CodexJSONValue.string)) }
        if let startupTimeoutSeconds { value["startup_timeout_sec"] = .int(startupTimeoutSeconds) }
        if let toolTimeoutSeconds { value["tool_timeout_sec"] = .int(toolTimeoutSeconds) }
        return .dictionary(value)
    }
}

public enum CodexMCPProtocolMutation {
    public static func save(_ configuration: CodexMCPServerConfiguration) throws -> CodexIntegrationControlPlaneRequest {
        try validate(configuration.name)
        guard configuration.transport == .streamableHTTP
            ? !configuration.url.nilIfBlank.isNilOrEmpty
            : !configuration.command.nilIfBlank.isNilOrEmpty else {
            throw CodexIntegrationControlPlaneError(
                configuration.transport == .streamableHTTP ? "MCP URL is required." : "MCP command is required."
            )
        }
        return .configValueWrite(.init(
            keyPath: "mcp_servers.\(configuration.name)",
            mergeStrategy: .replace,
            value: configuration.configValue
        ))
    }

    public static func setEnabled(name: String, enabled: Bool) throws -> CodexIntegrationControlPlaneRequest {
        try validate(name)
        return .configValueWrite(.init(
            keyPath: "mcp_servers.\(name).enabled",
            mergeStrategy: .replace,
            value: .bool(enabled)
        ))
    }

    public static func remove(name: String) throws -> CodexIntegrationControlPlaneRequest {
        try validate(name)
        return .configValueWrite(.init(
            keyPath: "mcp_servers.\(name)",
            mergeStrategy: .replace,
            value: .null
        ))
    }

    private static func validate(_ name: String) throws {
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0)
              }) else {
            throw CodexIntegrationControlPlaneError(
                "MCP server names may contain only letters, numbers, underscores, and hyphens."
            )
        }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
