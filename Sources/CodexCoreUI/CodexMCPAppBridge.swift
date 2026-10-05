import Foundation
import Observation
import CodexCore

@MainActor @Observable
final class CodexMCPAppBridge {
    struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }
    let descriptor: CodexMCPAppDescriptor
    let displayMode: CodexMCPAppDescriptor.DisplayMode
    var resource: CodexMCPAppResource?
    var error: String?
    var confirmation: Confirmation?
    var preferredHeight: Double = 320
    private let provider: any CodexIntegrationControlPlaneProvider
    private let onFullscreen: (@MainActor (CodexMCPAppDescriptor) -> Void)?
    private let onMessage: (@MainActor (CodexMCPAppDescriptor, String) -> Void)?
    private let onUpdateContext: (@MainActor (CodexMCPAppDescriptor, CodexJSONValue) -> Void)?
    private let openLink: @MainActor (URL) -> Void
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var appDisplayModes: Set<String> = []
    private var hasInitializeResponse = false
    private var isInitialized = false
    private var isStopped = false

    var canOpenFullscreen: Bool {
        displayMode == .inline && onFullscreen != nil
            && (!hasInitializeResponse || appDisplayModes.isEmpty || appDisplayModes.contains("fullscreen"))
    }

    var canNotifyHostContext: Bool { isInitialized && !isStopped }

    func openFullscreen() { if canOpenFullscreen { onFullscreen?(descriptor) } }

    init(descriptor: CodexMCPAppDescriptor, provider: any CodexIntegrationControlPlaneProvider,
         displayMode: CodexMCPAppDescriptor.DisplayMode,
         onFullscreen: (@MainActor (CodexMCPAppDescriptor) -> Void)? = nil,
         onMessage: (@MainActor (CodexMCPAppDescriptor, String) -> Void)? = nil,
         onUpdateContext: (@MainActor (CodexMCPAppDescriptor, CodexJSONValue) -> Void)? = nil,
         openLink: @escaping @MainActor (URL) -> Void = { _ in }) {
        self.descriptor = descriptor; self.provider = provider; self.displayMode = displayMode
        self.onFullscreen = onFullscreen; self.onMessage = onMessage; self.openLink = openLink
        self.onUpdateContext = onUpdateContext
    }

    func load() async {
        guard resource == nil, !isStopped else { return }
        do {
            let response = try await provider.perform(descriptor.resourceRequest())
            try Task.checkCancellation()
            guard !isStopped else { return }
            resource = try .init(response: response, uri: descriptor.resourceURI)
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }

    func resolveConfirmation(_ approved: Bool) {
        confirmation = nil
        let continuation = approvalContinuation
        approvalContinuation = nil
        continuation?.resume(returning: approved)
    }

    func stop() {
        isStopped = true
        resolveConfirmation(false)
    }

    func handle(_ message: CodexJSONValue, theme: String = "dark", styleVariables: [String: String] = [:]) async -> [CodexJSONValue] {
        guard !isStopped, !Task.isCancelled, let fields = message.objectValue, fields["jsonrpc"] == .string("2.0"),
              case .string(let method)? = fields["method"] else { return [] }
        let id = fields["id"]
        if let id, !Self.validRequestID(id) { return [] }
        let params = fields["params"]?.objectValue ?? [:]
        if method == "ui/notifications/initialized" {
            guard hasInitializeResponse, !isInitialized, id == nil else { return [] }
            isInitialized = true
            var messages = [Self.notification("ui/notifications/tool-input", .dictionary([
                "arguments": descriptor.arguments?.objectValue.map(CodexJSONValue.dictionary) ?? .dictionary([:])
            ]))]
            if let result = descriptor.result, result.objectValue != nil {
                messages.append(Self.notification("ui/notifications/tool-result", result))
            }
            return messages
        }
        if method == "ui/notifications/size-changed", isInitialized,
           let height = params["height"]?.mcpAppNumber, height.isFinite {
            preferredHeight = min(max(height, 120), 600)
            return []
        }
        // Notifications are accepted only through the implemented lifecycle; no arbitrary forwarding.
        guard let id else { return [] }
        do {
            let result: CodexJSONValue
            switch method {
            case "ping": result = .dictionary([:])
            case "ui/initialize":
                guard !hasInitializeResponse, resource != nil,
                      params["protocolVersion"] == .string("2026-01-26") else {
                    throw CodexIntegrationControlPlaneError("Unsupported MCP app protocol or repeated initialization.")
                }
                if case .array(let modes)? = params["appCapabilities"]?.objectValue?["availableDisplayModes"] {
                    appDisplayModes = Set(modes.compactMap { if case .string(let mode) = $0 { mode } else { nil } })
                }
                hasInitializeResponse = true
                result = initializeResult(theme: theme, styleVariables: styleVariables)
            default:
                guard isInitialized else { throw CodexIntegrationControlPlaneError("The MCP app has not initialized.") }
                result = try await interactiveResult(method: method, params: params)
            }
            try Task.checkCancellation()
            guard !isStopped else { return [] }
            return [.dictionary(["jsonrpc": .string("2.0"), "id": id, "result": result])]
        } catch {
            guard !isStopped else { return [] }
            return [.dictionary(["jsonrpc": .string("2.0"), "id": id,
                                 "error": .dictionary(["code": .int(Self.supportedMethods.contains(method) ? -32000 : -32601),
                                                       "message": .string(error.localizedDescription)])])]
        }
    }

    private static let supportedMethods: Set<String> = ["ping", "ui/initialize", "tools/call", "resources/read", "ui/open-link",
                                                        "ui/message", "ui/request-display-mode", "ui/update-model-context"]

    private func initializeResult(theme: String, styleVariables: [String: String]) -> CodexJSONValue {
        let modes = onFullscreen == nil ? [displayMode.rawValue] : ["inline", "fullscreen"]
        return .dictionary([
            "protocolVersion": .string("2026-01-26"),
            "hostInfo": .dictionary(["name": .string("CodexCore"), "version": .string("1")]),
            "hostCapabilities": .dictionary([
                "serverTools": .dictionary([:]), "serverResources": .dictionary([:]), "openLinks": .dictionary([:]),
                "sandbox": .dictionary(["permissions": .dictionary([:]), "csp": resource?.csp.capabilityValue ?? .dictionary([:])]),
            ]),
            "hostContext": .dictionary([
                "theme": .string(theme), "displayMode": .string(displayMode.rawValue),
                "styles": .dictionary(["variables": .dictionary(styleVariables.mapValues(CodexJSONValue.string))]),
                "availableDisplayModes": .array(modes.map(CodexJSONValue.string)),
                "containerDimensions": .dictionary(["maxHeight": .int(displayMode == .inline ? 600 : 1_200)]),
                "platform": .string("desktop"), "locale": .string(Locale.current.identifier.replacingOccurrences(of: "_", with: "-")),
                "timeZone": .string(TimeZone.current.identifier),
            ]),
        ])
    }

    private func interactiveResult(method: String, params: [String: CodexJSONValue]) async throws -> CodexJSONValue {
        // Requests cannot change the server, thread or account owning this view.
        for field in ["server", "threadId", "connectorId", "linkId", "target", "originCallId"] where params[field] != nil {
            throw CodexIntegrationControlPlaneError("MCP app requests cannot override their originating scope.")
        }
        switch method {
        case "tools/call":
            guard case .string(let name)? = params["name"], !name.isEmpty,
                  params["arguments"] == nil || params["arguments"]?.objectValue != nil else {
                throw CodexIntegrationControlPlaneError("Invalid MCP app tool arguments.")
            }
            try await requireAppVisibleTool(name)
            guard await confirm("Allow MCP app tool call?", detail: "\(descriptor.appName) wants to run \(name) on \(descriptor.server).") else {
                throw CodexIntegrationControlPlaneError("Tool call declined.")
            }
            try Task.checkCancellation()
            return try await provider.perform(.mcpToolCall(.init(arguments: params["arguments"], server: descriptor.server,
                                                                 threadID: descriptor.threadID, tool: name)))
        case "resources/read":
            guard case .string(let uri)? = params["uri"], !uri.isEmpty, uri.utf8.count <= 8_192 else {
                throw CodexIntegrationControlPlaneError("Invalid MCP resource URI.")
            }
            guard await confirm("Allow MCP app resource read?", detail: "\(descriptor.appName) wants to read \(uri).") else {
                throw CodexIntegrationControlPlaneError("Resource read declined.")
            }
            try Task.checkCancellation()
            return try await provider.perform(descriptor.resourceRequest(uri: uri))
        case "ui/open-link":
            guard case .string(let value)? = params["url"], let url = URL(string: value),
                  url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
                throw CodexIntegrationControlPlaneError("MCP app links must use HTTPS.")
            }
            guard await confirm("Open external link?", detail: url.absoluteString) else {
                throw CodexIntegrationControlPlaneError("Link opening declined.")
            }
            try Task.checkCancellation()
            openLink(url)
            return .dictionary([:])
        case "ui/message":
            guard let onMessage, params["role"] == .string("user"), let text = Self.messageText(params["content"]),
                  !text.isEmpty, text.utf8.count <= 32_768 else {
                throw CodexIntegrationControlPlaneError("Only supported user text messages can be sent to this chat.")
            }
            guard await confirm("Send app message to chat?", detail: text) else {
                throw CodexIntegrationControlPlaneError("Message sending declined.")
            }
            try Task.checkCancellation()
            onMessage(descriptor, text)
            return .dictionary([:])
        case "ui/request-display-mode":
            guard case .string(let mode)? = params["mode"], mode == "fullscreen", displayMode == .inline,
                  appDisplayModes.contains(mode), let onFullscreen else {
                return .dictionary(["mode": .string(displayMode.rawValue)])
            }
            onFullscreen(descriptor)
            return .dictionary(["mode": .string("fullscreen")])
        case "ui/update-model-context":
            guard let onUpdateContext,
                  params["structuredContent"] == nil || params["structuredContent"]?.objectValue != nil,
                  params["content"] == nil || Self.validContextContent(params["content"]) else {
                throw CodexIntegrationControlPlaneError("Invalid or unsupported MCP app model context.")
            }
            var context: [String: CodexJSONValue] = [:]
            context["content"] = params["content"]
            context["structuredContent"] = params["structuredContent"]
            let value = CodexJSONValue.dictionary(context)
            guard try JSONEncoder().encode(value).count <= 16_384 else {
                throw CodexIntegrationControlPlaneError("MCP app model context exceeds 16 KiB.")
            }
            onUpdateContext(descriptor, value)
            return .dictionary([:])
        default:
            throw CodexIntegrationControlPlaneError("Unsupported MCP app method: \(method)")
        }
    }

    private func requireAppVisibleTool(_ name: String) async throws {
        let raw = try await provider.perform(.mcpStatusList(.init(detail: .full, limit: 100, serverName: descriptor.server, threadID: descriptor.threadID)))
        try Task.checkCancellation()
        let inventory = try JSONDecoder().decode(CodexSchemaListMCPServerStatusResponse.self, from: JSONEncoder().encode(raw))
        guard let tool = inventory.data.first(where: { $0.name == descriptor.server })?.tools.values.first(where: { $0.name == name }) else {
            throw CodexIntegrationControlPlaneError("The MCP app tool is unavailable on its originating server.")
        }
        if let visibility = tool.meta?.objectValue?["ui"]?.objectValue?["visibility"] {
            guard case .array(let values) = visibility, values.contains(.string("app")) else {
                throw CodexIntegrationControlPlaneError("This tool is not callable by MCP apps.")
            }
        }
    }

    private func confirm(_ title: String, detail: String) async -> Bool {
        guard approvalContinuation == nil, !isStopped, !Task.isCancelled else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                approvalContinuation = continuation
                confirmation = .init(title: title, detail: detail)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.resolveConfirmation(false) } }
    }

    static func validRequestID(_ value: CodexJSONValue) -> Bool {
        switch value {
        case .string(let value): !value.isEmpty && value.utf8.count <= 256
        case .int: true
        default: false
        }
    }

    private static func messageText(_ value: CodexJSONValue?) -> String? {
        if let fields = value?.objectValue, fields["type"] == .string("text"), case .string(let text)? = fields["text"] { return text }
        if case .array(let blocks)? = value {
            let values = blocks.compactMap(messageText)
            return values.count == blocks.count ? values.joined(separator: "\n") : nil
        }
        return nil
    }

    private static func validContextContent(_ value: CodexJSONValue?) -> Bool {
        guard case .array(let blocks)? = value else { return false }
        return blocks.allSatisfy { block in
            guard let fields = block.objectValue, case .string(let type)? = fields["type"] else { return false }
            switch type {
            case "text": if case .string? = fields["text"] { return true }; return false
            case "image", "audio": if case .string? = fields["data"], case .string? = fields["mimeType"] { return true }; return false
            case "resource": return fields["resource"]?.objectValue != nil
            case "resource_link": if case .string? = fields["uri"], case .string? = fields["name"] { return true }; return false
            default: return false
            }
        }
    }

    static func notification(_ method: String, _ params: CodexJSONValue) -> CodexJSONValue {
        .dictionary(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])
    }
}

private extension CodexJSONValue {
    var mcpAppNumber: Double? {
        switch self { case .int(let value): Double(value); case .double(let value): value; default: nil }
    }
}
