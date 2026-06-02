import SwiftUI
import Observation
import CodexCore

@main
struct CodexChatExampleApp: App {
    var body: some Scene {
        WindowGroup {
            CodexChatView()
                .frame(minWidth: 860, minHeight: 640)
        }
    }
}

@MainActor
@Observable
final class CodexChatModel {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(server: String)
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting"
            case .connected(let server): return "Connected to \(server)"
            case .failed: return "Failed"
            }
        }
    }

    struct Message: Identifiable, Equatable {
        enum Role: String, Equatable {
            case user = "You"
            case assistant = "Codex"
            case system = "System"
        }

        let id: UUID
        var role: Role
        var text: String
        var detail: String?
        var isStreaming: Bool
        var createdAt: Date

        init(role: Role, text: String, detail: String? = nil, isStreaming: Bool = false, createdAt: Date = Date()) {
            self.id = UUID()
            self.role = role
            self.text = text
            self.detail = detail
            self.isStreaming = isStreaming
            self.createdAt = createdAt
        }
    }

    struct Activity: Identifiable, Equatable {
        enum Kind: String, Equatable {
            case turn
            case tool
            case token
            case login
            case notice
        }

        let id = UUID()
        var kind: Kind
        var title: String
        var detail: String
        var createdAt = Date()
    }

    var connectionState: ConnectionState = .disconnected
    var workspacePath = FileManager.default.currentDirectoryPath
    var codexBinaryPath = "/Applications/Codex.app/Contents/Resources/codex"
    var draft = ""
    var apiKey = ""
    var messages: [Message] = [
        Message(
            role: .system,
            text: "Connect to the local Codex app-server, then send a prompt. The app inherits your installed Codex auth from ~/.codex and only shows login controls if Codex reports missing auth."
        )
    ]
    var activities: [Activity] = []
    var isSending = false
    var isAuthenticated = true
    var deviceCodeURL: String?
    var deviceCode: String?

    private var codex: Codex?
    private var thread: CodexThread?
    private var activeTurn: CodexTurnHandle?
    private var streamTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var assistantMessageIDsByItemID: [String: UUID] = [:]

    var canSend: Bool {
        if case .connected = connectionState,
           isAuthenticated,
           thread != nil,
           !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !isSending {
            return true
        }
        return false
    }

    func connect() async {
        switch connectionState {
        case .connecting, .connected:
            return
        case .disconnected, .failed:
            break
        }

        connectionState = .connecting
        resetSessionState()
        do {
            let path = codexBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let config = CodexConfig(
                codexBinaryPath: path.isEmpty ? nil : path,
                cwd: workspacePath,
                environment: ["CODEX_HOME": defaultCodexHome()],
                clientName: "codex_swiftui_example",
                clientTitle: "Codex SwiftUI Example",
                clientVersion: "1.0.0"
            )
            let codex = try await Codex(config: config)
            self.codex = codex
            let server = codex.metadata.serverInfo?.name ?? "Codex"
            connectionState = .connected(server: server)

            do {
                let account = try await codex.account(refreshToken: false)
                isAuthenticated = !account.requiresOpenAIAuth
                if account.requiresOpenAIAuth {
                    appendMessage(.system, "Codex did not find usable auth in \(defaultCodexHome()). Login below, then the app will create a thread automatically.")
                    appendActivity(.login, title: "Authentication required", detail: defaultCodexHome())
                    return
                }
            } catch {
                appendActivity(.login, title: "Account check skipped", detail: String(describing: error))
            }

            try await ensureThread()
        } catch {
            connectionState = .failed(String(describing: error))
            appendActivity(.notice, title: "Connection failed", detail: String(describing: error))
        }
    }

    func disconnect() async {
        streamTask?.cancel()
        loginTask?.cancel()
        streamTask = nil
        loginTask = nil
        activeTurn = nil
        thread = nil
        let codex = self.codex
        self.codex = nil
        await codex?.close()
        connectionState = .disconnected
        appendActivity(.notice, title: "Disconnected", detail: "Closed app-server session")
    }

    func loginWithAPIKey() async {
        guard let codex else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try await codex.loginAPIKey(key)
            apiKey = ""
            isAuthenticated = true
            appendActivity(.login, title: "API key login", detail: "Authentication updated")
            try await ensureThread()
        } catch {
            appendActivity(.login, title: "API key login failed", detail: String(describing: error))
        }
    }

    func startDeviceCodeLogin() async {
        guard let codex else { return }
        do {
            let handle = try await codex.loginChatGPTDeviceCode()
            deviceCodeURL = handle.verificationUrl
            deviceCode = handle.userCode
            appendActivity(.login, title: "Device login started", detail: "Code: \(handle.userCode)")
            loginTask?.cancel()
            loginTask = Task { [weak self] in
                do {
                    _ = try await handle.wait()
                    await self?.finishDeviceCodeLogin()
                } catch {
                    await MainActor.run {
                        self?.appendActivity(.login, title: "Device login ended", detail: String(describing: error))
                    }
                }
            }
        } catch {
            appendActivity(.login, title: "Device login failed", detail: String(describing: error))
        }
    }

    func sendDraft() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        draft = ""
        isSending = true
        appendMessage(.user, prompt)
        appendActivity(.turn, title: "Turn starting", detail: prompt)

        do {
            let thread = try await ensureThread()
            let handle = try await thread.turn(
                [.text(prompt)],
                approvalMode: .autoReview,
                cwd: workspacePath,
                sandbox: .workspaceWrite
            )
            activeTurn = handle
            consumeTurn(handle)
        } catch {
            isSending = false
            appendMessage(.system, "Failed to start turn: \(error)")
            appendActivity(.turn, title: "Turn failed to start", detail: String(describing: error))
        }
    }

    private func finishDeviceCodeLogin() async {
        isAuthenticated = true
        deviceCode = nil
        deviceCodeURL = nil
        appendActivity(.login, title: "Device login complete", detail: "Authentication updated")
        do {
            try await ensureThread()
        } catch {
            appendActivity(.turn, title: "Thread creation failed", detail: String(describing: error))
        }
    }

    @discardableResult
    private func ensureThread() async throws -> CodexThread {
        if let thread { return thread }
        guard let codex else { throw CodexSDKError.runtimeNotFound }
        let thread = try await codex.threadStart(
            approvalMode: .autoReview,
            cwd: workspacePath,
            sandbox: .workspaceWrite
        )
        self.thread = thread
        appendActivity(.notice, title: "Thread ready", detail: thread.id)
        return thread
    }

    func interrupt() async {
        guard let activeTurn else { return }
        do {
            _ = try await activeTurn.interrupt()
            appendActivity(.turn, title: "Interrupt sent", detail: activeTurn.id)
        } catch {
            appendActivity(.turn, title: "Interrupt failed", detail: String(describing: error))
        }
    }

    private func consumeTurn(_ handle: CodexTurnHandle) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await notification in handle.stream() {
                self.apply(notification)
            }
            await MainActor.run {
                self.isSending = false
                self.activeTurn = nil
            }
        }
    }

    private func apply(_ notification: CodexNotification) {
        switch notification.payload {
        case .agentMessageDelta(let delta):
            appendAssistantDelta(delta.delta, itemID: delta.itemId)
        case .itemStarted(let payload):
            appendActivity(.tool, title: "Item started", detail: "\(payload.item.type) / \(payload.item.id)")
        case .itemCompleted(let payload):
            applyCompletedItem(payload.item)
        case .threadTokenUsageUpdated(let payload):
            appendActivity(.token, title: "Token usage", detail: payload.tokenUsage.raw.description)
        case .turnStarted(let payload):
            appendActivity(.turn, title: "Turn started", detail: payload.turn.id)
        case .turnCompleted(let payload):
            isSending = false
            activeTurn = nil
            appendActivity(.turn, title: "Turn completed", detail: payload.turn.id)
        case .accountLoginCompleted(let payload):
            appendActivity(.login, title: "Login completed", detail: payload.loginId)
        case .known(let method, _):
            appendActivity(.notice, title: method.rawValue, detail: "Known app-server notification")
        case .unknown(let method, _):
            appendActivity(.notice, title: method, detail: "Unknown notification")
        }
    }

    private func applyCompletedItem(_ item: ThreadItem) {
        switch item.type {
        case "agentMessage", "assistantMessage":
            guard let text = item.text, !text.isEmpty else { return }
            if let messageID = assistantMessageIDsByItemID[item.id], let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].text = text
                messages[index].isStreaming = false
            } else {
                let message = Message(role: .assistant, text: text)
                assistantMessageIDsByItemID[item.id] = message.id
                messages.append(message)
            }
        case "userMessage":
            break
        default:
            appendActivity(.tool, title: item.type, detail: item.raw.description)
        }
    }

    private func appendAssistantDelta(_ text: String, itemID: String) {
        if let messageID = assistantMessageIDsByItemID[itemID], let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].text.append(text)
            messages[index].isStreaming = true
            return
        }

        var message = Message(role: .assistant, text: text, isStreaming: true)
        message.detail = "Streaming"
        assistantMessageIDsByItemID[itemID] = message.id
        messages.append(message)
    }

    private func appendMessage(_ role: Message.Role, _ text: String, detail: String? = nil) {
        messages.append(Message(role: role, text: text, detail: detail))
    }

    private func appendActivity(_ kind: Activity.Kind, title: String, detail: String) {
        activities.insert(Activity(kind: kind, title: title, detail: detail), at: 0)
        if activities.count > 80 {
            activities.removeLast(activities.count - 80)
        }
    }

    private func resetSessionState() {
        streamTask?.cancel()
        loginTask?.cancel()
        streamTask = nil
        loginTask = nil
        activeTurn = nil
        thread = nil
        codex = nil
        isAuthenticated = true
        deviceCode = nil
        deviceCodeURL = nil
        assistantMessageIDsByItemID = [:]
    }
}

struct CodexChatView: View {
    @State private var model = CodexChatModel()
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ConnectionPanel(model: model, openURL: openURL)
                    Divider()
                    TranscriptView(messages: model.messages)
                    Divider()
                    ComposerBar(model: model)
                }
                .frame(minWidth: 520)

                Divider()
                ActivityRail(activities: model.activities)
                    .frame(width: 300)
            }
        }
    }
}

struct HeaderBar: View {
    let model: CodexChatModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex SwiftUI Chat")
                    .font(.title2.weight(.semibold))
                Text("A pure SwiftUI app using the public CodexCore SDK")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(state: model.connectionState)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }
}

struct ConnectionPanel: View {
    @Bindable var model: CodexChatModel
    let openURL: OpenURLAction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Workspace", text: $model.workspacePath)
                    .textFieldStyle(.roundedBorder)
                TextField("Codex binary", text: $model.codexBinaryPath)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Button("Connect") {
                    Task { await model.connect() }
                }
                .disabled(isConnectingOrConnected)

                Button("Disconnect") {
                    Task { await model.disconnect() }
                }
                .disabled(!isConnected)

                Spacer()

                SecureField("API key", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)

                Button("Login") {
                    Task { await model.loginWithAPIKey() }
                }
                .disabled(model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isConnected)
            }

            if !model.isAuthenticated {
                AuthCallout(model: model, openURL: openURL)
            }

            if case .failed(let message) = model.connectionState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06))
    }

    private var isConnected: Bool {
        if case .connected = model.connectionState { return true }
        return false
    }

    private var isConnectingOrConnected: Bool {
        switch model.connectionState {
        case .connecting, .connected: return true
        case .disconnected, .failed: return false
        }
    }
}

struct AuthCallout: View {
    let model: CodexChatModel
    let openURL: OpenURLAction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Authentication required")
                .font(.headline)
            Text("Use an API key or start a ChatGPT device-code login.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Start device login") {
                    Task { await model.startDeviceCodeLogin() }
                }
                if let code = model.deviceCode {
                    Text(code)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                if let urlString = model.deviceCodeURL, let url = URL(string: urlString) {
                    Button("Open login page") { openURL(url) }
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct TranscriptView: View {
    let messages: [CodexChatModel.Message]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(18)
            }
            .background(Color.primary.opacity(0.025))
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last?.id {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct MessageBubble: View {
    let message: CodexChatModel.Message

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 80) }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(message.role.rawValue)
                        .font(.caption.weight(.semibold))
                    if message.isStreaming {
                        Text("Streaming")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)

                AssistantContentView(text: message.text)

                if let detail = message.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(13)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
            .frame(maxWidth: 620, alignment: .leading)

            if message.role != .user { Spacer(minLength: 80) }
        }
    }

    private var background: Color {
        switch message.role {
        case .user: return Color.accentColor.opacity(0.14)
        case .assistant: return Color.secondary.opacity(0.10)
        case .system: return Color.yellow.opacity(0.12)
        }
    }

    private var border: Color {
        switch message.role {
        case .user: return Color.accentColor.opacity(0.25)
        case .assistant: return Color.secondary.opacity(0.18)
        case .system: return Color.yellow.opacity(0.25)
        }
    }
}

struct AssistantContentView: View {
    let text: String

    var body: some View {
        let blocks = MessageContentBridge.assistantRenderBlocks(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let markdown):
                    MarkdownText(markdown)
                case .codeBlock(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .inlineImage:
                    Label("Inline image", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct MarkdownText: View {
    let markdown: String

    init(_ markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        if let attributed = try? AttributedString(markdown: markdown) {
            Text(attributed)
                .textSelection(.enabled)
        } else {
            Text(markdown)
                .textSelection(.enabled)
        }
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : "code")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.08))

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ComposerBar: View {
    @Bindable var model: CodexChatModel

    var body: some View {
        VStack(spacing: 10) {
            TextField("Ask Codex to inspect, explain, edit, or run a command...", text: $model.draft, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text(model.isAuthenticated ? "Sandbox: workspace-write, approvals: auto-review" : "Type anytime; Send enables after login and thread setup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Interrupt") {
                    Task { await model.interrupt() }
                }
                .disabled(!model.isSending)

                Button(model.isSending ? "Running" : "Send") {
                    Task { await model.sendDraft() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.canSend)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.thinMaterial)
    }
}

struct ActivityRail: View {
    let activities: [CodexChatModel.Activity]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity")
                .font(.headline)
                .padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(activities) { activity in
                        ActivityRow(activity: activity)
                    }
                }
                .padding(14)
            }
        }
        .background(Color.secondary.opacity(0.05))
    }
}

struct ActivityRow: View {
    let activity: CodexChatModel.Activity

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(activity.title)
                    .font(.caption.weight(.semibold))
                Text(activity.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var color: Color {
        switch activity.kind {
        case .turn: return .blue
        case .tool: return .purple
        case .token: return .green
        case .login: return .orange
        case .notice: return .secondary
        }
    }
}

struct StatusPill: View {
    let state: CodexChatModel.ConnectionState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(state.label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch state {
        case .disconnected: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }
}
