import SwiftUI
import CodexCore

struct CodexMCPInspectorSheet: View {
    enum Operation: String, CaseIterable { case resource = "Read resource", tool = "Call tool", events = "Stream events" }
    @Environment(\.codexAgentTheme) private var theme
    let server: CodexMCPServerStatus
    let threadID: String?
    let provider: any CodexIntegrationControlPlaneProvider
    let onClose: () -> Void
    @State private var operation = Operation.resource
    @State private var name = ""
    @State private var arguments = "{}"
    @State private var output = ""
    @State private var error: String?
    @State private var isRunning = false
    @State private var pendingRequest: CodexIntegrationControlPlaneRequest?
    @State private var runningTask: Task<Void, Never>?
    @State private var eventLines: [String] = []
    @State private var connectorID = ""
    @State private var linkID = ""
    @State private var originCallID = ""
    @State private var withoutAuthentication = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(server.displayName).font(theme.fonts.sheetTitle)
                Spacer()
                Button("Close", systemImage: "xmark", action: onClose).labelStyle(.iconOnly)
            }
            Picker("Operation", selection: $operation) {
                ForEach(Operation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(isRunning)
            TextField(operation == .resource ? "Resource URI" : "Tool or event stream name", text: $name)
                .textFieldStyle(.roundedBorder).disabled(isRunning)
            if operation == .resource {
                Menu("Available resources") {
                    ForEach(server.resources) { resource in
                        if let uri = resource.uri { Button(resource.displayName) { name = uri } }
                    }
                    ForEach(server.resourceTemplates) { resource in
                        if let template = resource.uriTemplate { Button(resource.displayName + " (template)") { name = template } }
                    }
                }.disabled(isRunning)
                DisclosureGroup("Hosted app account scope") {
                    TextField("Connector ID (optional)", text: $connectorID).textFieldStyle(.roundedBorder)
                    TextField("Account link ID (optional)", text: $linkID).textFieldStyle(.roundedBorder).disabled(withoutAuthentication)
                    Toggle("Explicitly request no-auth access", isOn: $withoutAuthentication).disabled(connectorID.isEmpty)
                    TextField("Origin call ID (optional, requires chat)", text: $originCallID).textFieldStyle(.roundedBorder)
                    Text("An origin call in the selected chat takes precedence. No-auth reads remain subject to the app's resource policy.")
                        .foregroundStyle(theme.colors.textSecondary)
                }.disabled(isRunning)
            } else {
                Menu("Available tools") {
                    ForEach(server.tools) { tool in Button(tool.displayName) { name = tool.name } }
                }.disabled(isRunning)
                Text("Arguments (JSON object)").foregroundStyle(theme.colors.textSecondary)
                TextEditor(text: $arguments).font(theme.fonts.code).frame(height: 90).disabled(isRunning)
                if let schema = server.tools.first(where: { $0.name == name })?.inputSchema {
                    DisclosureGroup("Input schema") {
                        Text(Self.render(schema)).font(theme.fonts.code).textSelection(.enabled)
                    }
                }
            }
            if threadID == nil && operation != .resource {
                Text("Open a chat to execute tools or start an event stream.").foregroundStyle(theme.colors.warning)
            }
            if let error { Text(error).foregroundStyle(theme.colors.danger).textSelection(.enabled) }
            HStack {
                Button(operation.rawValue) { propose() }.buttonStyle(.borderedProminent)
                    .disabled(isRunning || name.nilIfBlank == nil || (threadID == nil && operation != .resource))
                if isRunning { Button("Stop") { runningTask?.cancel() }; ProgressView().controlSize(.small) }
            }
            ScrollView {
                Text(output.isEmpty ? "Results appear here." : output).font(theme.fonts.code).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.font(theme.fonts.caption).padding(24).frame(width: 760, height: 660).background(theme.colors.surface)
        .onDisappear { runningTask?.cancel() }
        .confirmationDialog("Allow external MCP operation?", isPresented: Binding(
            get: { pendingRequest != nil }, set: { if !$0 { pendingRequest = nil } }
        )) {
            Button("Allow once") { run() }
        } message: { Text("This contacts \(server.displayName). Tool calls and event stream setup may execute actions outside CodexCore.") }
    }

    private func propose() {
        do {
            if operation == .resource {
                let connector = connectorID.nilIfBlank
                let target = connector.flatMap { id -> CodexSchemaMCPResourceReadTarget? in
                    guard withoutAuthentication || linkID.nilIfBlank != nil else { return nil }
                    return .init(connectorID: id, linkID: withoutAuthentication ? nil : linkID.nilIfBlank)
                }
                pendingRequest = .mcpResourceRead(.init(
                    connectorID: target == nil ? connector : nil, originCallID: originCallID.nilIfBlank,
                    server: server.name, target: target, threadID: threadID, uri: name
                ))
            } else {
                guard let threadID else { return }
                let value = try JSONDecoder().decode(CodexJSONValue.self, from: Data(arguments.utf8))
                guard value.objectValue != nil else { throw CodexIntegrationControlPlaneError("Arguments must be a JSON object.") }
                if operation == .tool {
                    pendingRequest = .mcpToolCall(.init(arguments: value, server: server.name, threadID: threadID, tool: name))
                } else {
                    pendingRequest = .mcpEventStreamStart(.init(arguments: value, name: name, server: server.name,
                                                              subscriptionID: UUID().uuidString, threadID: threadID))
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func run() {
        guard let request = pendingRequest, !isRunning else { return }
        pendingRequest = nil
        isRunning = true
        output = ""
        error = nil
        runningTask = Task {
            defer { isRunning = false; runningTask = nil }
            if case .mcpEventStreamStart(let params) = request {
                do {
                    eventLines = []
                    try await CodexMCPEventStreamWorkflow.run(params, provider: provider) { notification in
                        eventLines.append("\(notification.method)\n\(Self.render(notification.params, maximumCharacters: 4_096))")
                        if eventLines.count > 64 { eventLines.removeFirst(eventLines.count - 64) }
                        output = eventLines.joined(separator: "\n\n")
                    }
                } catch is CancellationError { } catch { self.error = error.localizedDescription }
            } else {
                do {
                    let response = try await provider.perform(request)
                    try Task.checkCancellation()
                    output = Self.render(response)
                    if request.operationID == "mcpServer/tool/call", response.objectValue?["isError"] == .bool(true) {
                        error = "The MCP tool reported an error."
                    }
                } catch is CancellationError { } catch { self.error = error.localizedDescription }
            }
        }
    }

    private static func render(_ value: CodexJSONValue, maximumCharacters: Int = 262_144) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "Unable to decode result." }
        return text.count > maximumCharacters ? String(text.prefix(maximumCharacters)) + "\n… result truncated" : text
    }
}
