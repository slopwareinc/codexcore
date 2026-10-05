import Foundation
import CodexCore

public extension CodexMCPServerConfiguration {
    /// Retains unknown fields so editing a known field does not erase newer runtime settings.
    init?(name: String, value: CodexJSONValue) {
        guard let object = value.objectValue,
              object["command"]?.stringValue != nil || object["url"]?.stringValue != nil else { return nil }
        func strings(_ key: String) -> [String] {
            guard case .array(let values) = object[key] else { return [] }
            return values.compactMap(\.stringValue)
        }
        func dictionary(_ key: String) -> [String: String] {
            object[key]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
        }
        self.init(
            name: name,
            enabled: CodexJSONCoercion.bool(from: object["enabled"]) ?? true,
            transport: object["url"]?.stringValue == nil ? .stdio : .streamableHTTP,
            command: object["command"]?.stringValue ?? "",
            arguments: strings("args"),
            workingDirectory: object["cwd"]?.stringValue,
            environment: dictionary("env"),
            environmentPassthrough: strings("env_vars"),
            url: object["url"]?.stringValue ?? "",
            bearerTokenEnvironmentVariable: object["bearer_token_env_var"]?.stringValue,
            httpHeaders: dictionary("http_headers"),
            environmentHTTPHeaders: dictionary("env_http_headers"),
            startupTimeoutSeconds: object["startup_timeout_sec"]?.doubleValue,
            toolTimeoutSeconds: object["tool_timeout_sec"]?.doubleValue,
            enabledTools: object["enabled_tools"] == nil ? nil : strings("enabled_tools"),
            disabledTools: strings("disabled_tools"),
            defaultToolsApprovalMode: object["default_tools_approval_mode"]?.stringValue.flatMap(CodexMCPToolApprovalMode.init(rawValue:)),
            toolApprovalModes: object["tools"]?.objectValue?.compactMapValues {
                $0.objectValue?["approval_mode"]?.stringValue.flatMap(CodexMCPToolApprovalMode.init(rawValue:))
            } ?? [:]
        )
        preservedFields = object
    }

    /// Config layers are returned in increasing precedence; disabled layers never contribute.
    static func configurations(from response: CodexSchemaConfigReadResponse) -> [String: Self] {
        var merged: [String: CodexJSONValue] = [:]
        for layer in response.layers ?? [] where layer.disabledReason == nil {
            guard let servers = layer.config.objectValue?["mcp_servers"]?.objectValue else { continue }
            for (name, value) in servers { merged[name] = merge(merged[name], value) }
        }
        return merged.reduce(into: [:]) { result, entry in
            result[entry.key] = Self(name: entry.key, value: entry.value)
        }
    }

    private static func merge(_ existing: CodexJSONValue?, _ incoming: CodexJSONValue) -> CodexJSONValue {
        guard var fields = existing?.objectValue, let updates = incoming.objectValue else { return incoming }
        for (key, value) in updates { fields[key] = merge(fields[key], value) }
        return .dictionary(fields)
    }
}

private extension CodexJSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
    var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}
