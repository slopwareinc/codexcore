import SwiftUI
import Observation
import CodexCore

@main
struct CodexChatExampleApp: App {
    var body: some Scene {
        WindowGroup {
            CodexChatView()
                .frame(minWidth: 860, minHeight: 640)
                .preferredColorScheme(.light)
        }
    }
}

private enum AppTheme {
    static let background = Color(red: 0.96, green: 0.97, blue: 0.99)
    static let backgroundWarm = Color(red: 1.0, green: 0.98, blue: 0.94)
    static let panel = Color(red: 1.0, green: 1.0, blue: 1.0)
    static let panelAlt = Color(red: 0.95, green: 0.97, blue: 1.0)
    static let chat = Color(red: 0.97, green: 0.98, blue: 1.0)
    static let sidebar = Color(red: 0.94, green: 0.96, blue: 0.99)
    static let text = Color(red: 0.08, green: 0.10, blue: 0.16)
    static let secondaryText = Color(red: 0.29, green: 0.33, blue: 0.42)
    static let mutedText = Color(red: 0.42, green: 0.46, blue: 0.55)
    static let border = Color(red: 0.80, green: 0.84, blue: 0.90)
    static let accent = Color(red: 0.07, green: 0.37, blue: 0.91)
    static let accentSoft = Color(red: 0.88, green: 0.93, blue: 1.0)
    static let userBubble = Color(red: 0.87, green: 0.93, blue: 1.0)
    static let assistantBubble = Color(red: 1.0, green: 1.0, blue: 1.0)
    static let systemBubble = Color(red: 1.0, green: 0.97, blue: 0.86)
}

private func defaultWorkspacePath() -> String {
    let current = FileManager.default.currentDirectoryPath
    if current != "/" { return current }

    let projectPath = "/Users/betterclever/Projects/slopware/CodexCore"
    if FileManager.default.fileExists(atPath: projectPath) { return projectPath }

    return FileManager.default.homeDirectoryForCurrentUser.path
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
            case terminal = "Terminal"
            case system = "System"
        }

        struct CommandRun: Equatable {
            var itemID: String
            var command: String
            var cwd: String?
            var output: String
            var status: String
            var exitCode: Int?
            var isStreaming: Bool
        }

        let id: UUID
        var role: Role
        var text: String
        var detail: String?
        var isStreaming: Bool
        var createdAt: Date
        var renderBlocks: [AssistantRenderBlock]
        var commandRun: CommandRun?

        init(
            role: Role,
            text: String,
            detail: String? = nil,
            isStreaming: Bool = false,
            createdAt: Date = Date(),
            parseContent: Bool = true,
            commandRun: CommandRun? = nil
        ) {
            self.id = UUID()
            self.role = role
            self.text = text
            self.detail = detail
            self.isStreaming = isStreaming
            self.createdAt = createdAt
            self.renderBlocks = parseContent ? Message.renderBlocks(for: text) : [.markdown(text)]
            self.commandRun = commandRun
        }

        mutating func setText(_ text: String, parseContent: Bool) {
            self.text = text
            renderBlocks = parseContent ? Self.renderBlocks(for: text) : [.markdown(text)]
        }

        mutating func appendStreamingText(_ delta: String) {
            text.append(delta)
            renderBlocks = [.markdown(text)]
        }

        private static func renderBlocks(for text: String) -> [AssistantRenderBlock] {
            MessageContentBridge.assistantRenderBlocks(text)
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
    var workspacePath = defaultWorkspacePath()
    var codexBinaryPath = "/Users/betterclever/.config/nvm/versions/node/v26.2.0/bin/codex"
    var draft = ""
    var apiKey = ""
    var messages: [Message] = []
    var activities: [Activity] = []
    var isSending = false
    var isAuthenticated = true
    var authLabel = "Checking auth"
    var deviceCodeURL: String?
    var deviceCode: String?

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = connectionState { return true }
        return false
    }

    var connectionErrorMessage: String? {
        if case .failed(let message) = connectionState { return message }
        return nil
    }

    var serverName: String? {
        if case .connected(let server) = connectionState { return server }
        return nil
    }

    var isThreadReady: Bool {
        thread != nil
    }

    private var codex: Codex?
    private var thread: CodexThread?
    private var activeTurn: CodexTurnHandle?
    private var streamTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var assistantMessageIDsByItemID: [String: UUID] = [:]
    private var commandMessageIDsByItemID: [String: UUID] = [:]

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
                isAuthenticated = account.account != nil || !account.requiresOpenAIAuth
                if let accountInfo = account.account {
                    authLabel = accountInfo.email.map { "\(accountInfo.type): \($0)" } ?? accountInfo.type
                    appendActivity(.login, title: "Signed in", detail: authLabel)
                } else if account.requiresOpenAIAuth {
                    authLabel = "Sign-in required"
                    appendActivity(.login, title: "Authentication required", detail: defaultCodexHome())
                    return
                } else {
                    authLabel = "Available"
                }
            } catch {
                authLabel = "Account check skipped"
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
            authLabel = "OpenAI API key"
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
        authLabel = "ChatGPT"
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
            if payload.item.type == "commandExecution" {
                startCommandRun(payload.item)
            } else {
                appendActivity(.tool, title: "Item started", detail: "\(payload.item.type) / \(payload.item.id)")
            }
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
        case .known(let method, let params):
            applyKnownNotification(method, params: params)
        case .unknown(let method, _):
            appendActivity(.notice, title: method, detail: "Unknown notification")
        }
    }

    private func applyKnownNotification(_ method: CodexAppServerNotificationMethod, params: [String: CodexJSONValue]) {
        switch method {
        case .itemCommandExecutionOutputDelta:
            guard let itemID = stringValue(params["itemId"]), let delta = stringValue(params["delta"]) else {
                return
            }
            appendCommandOutput(delta, itemID: itemID)
        case .itemCommandExecutionTerminalInteraction:
            guard let itemID = stringValue(params["itemId"]), let stdin = stringValue(params["stdin"]), !stdin.isEmpty else {
                return
            }
            appendCommandOutput("\n$ \(stdin)", itemID: itemID)
        default:
            appendActivity(.notice, title: method.rawValue, detail: "Known app-server notification")
        }
    }

    private func applyCompletedItem(_ item: ThreadItem) {
        switch item.type {
        case "agentMessage", "assistantMessage":
            guard let text = item.text, !text.isEmpty else { return }
            if let messageID = assistantMessageIDsByItemID[item.id], let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].setText(text, parseContent: true)
                messages[index].isStreaming = false
            } else {
                let message = Message(role: .assistant, text: text)
                assistantMessageIDsByItemID[item.id] = message.id
                messages.append(message)
            }
        case "userMessage":
            break
        case "commandExecution":
            finalizeCommandRun(item)
        default:
            appendActivity(.tool, title: item.type, detail: item.raw.description)
        }
    }

    private func appendAssistantDelta(_ text: String, itemID: String) {
        if let messageID = assistantMessageIDsByItemID[itemID], let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].appendStreamingText(text)
            messages[index].isStreaming = true
            return
        }

        var message = Message(role: .assistant, text: text, isStreaming: true, parseContent: false)
        message.detail = "Streaming"
        assistantMessageIDsByItemID[itemID] = message.id
        messages.append(message)
    }

    private func appendCommandOutput(_ delta: String, itemID: String) {
        if let messageID = commandMessageIDsByItemID[itemID], let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].commandRun?.output.append(delta)
            messages[index].commandRun?.isStreaming = true
            messages[index].isStreaming = true
            messages[index].text = messages[index].commandRun?.output ?? ""
            return
        }

        let run = Message.CommandRun(
            itemID: itemID,
            command: "Running command",
            cwd: nil,
            output: delta,
            status: "active",
            exitCode: nil,
            isStreaming: true
        )
        let message = Message(role: .terminal, text: delta, isStreaming: true, parseContent: false, commandRun: run)
        commandMessageIDsByItemID[itemID] = message.id
        messages.append(message)
    }

    private func startCommandRun(_ item: ThreadItem) {
        if commandMessageIDsByItemID[item.id] != nil { return }
        let run = Message.CommandRun(
            itemID: item.id,
            command: stringValue(item.raw["command"]) ?? "Running command",
            cwd: stringValue(item.raw["cwd"]),
            output: "",
            status: stringValue(item.raw["status"]) ?? "active",
            exitCode: nil,
            isStreaming: true
        )
        let message = Message(role: .terminal, text: "", isStreaming: true, parseContent: false, commandRun: run)
        commandMessageIDsByItemID[item.id] = message.id
        messages.append(message)
        appendActivity(.tool, title: "Command started", detail: run.command)
    }

    private func finalizeCommandRun(_ item: ThreadItem) {
        let command = stringValue(item.raw["command"]) ?? "Command"
        let output = stringValue(item.raw["aggregatedOutput"])
            ?? stringValue(item.raw["output"])
            ?? stringValue(item.raw["stdout"])
            ?? ""
        let status = stringValue(item.raw["status"]) ?? "completed"
        let run = Message.CommandRun(
            itemID: item.id,
            command: command,
            cwd: stringValue(item.raw["cwd"]),
            output: output,
            status: status,
            exitCode: intValue(item.raw["exitCode"]),
            isStreaming: status == "active" || status == "inProgress"
        )

        if let messageID = commandMessageIDsByItemID[item.id], let index = messages.firstIndex(where: { $0.id == messageID }) {
            var finalRun = run
            if finalRun.output.isEmpty {
                finalRun.output = messages[index].commandRun?.output ?? ""
            }
            messages[index].commandRun = finalRun
            messages[index].text = finalRun.output
            messages[index].isStreaming = finalRun.isStreaming
            return
        }

        let message = Message(role: .terminal, text: output, isStreaming: run.isStreaming, parseContent: false, commandRun: run)
        commandMessageIDsByItemID[item.id] = message.id
        messages.append(message)
    }

    private func stringValue(_ value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .array(let values): return values.compactMap(stringValue).joined(separator: " ")
        case .dictionary, .null, nil: return nil
        }
    }

    private func intValue(_ value: CodexJSONValue?) -> Int? {
        switch value {
        case .int(let int): return int
        case .double(let double): return Int(double)
        case .string(let string): return Int(string)
        case .bool, .array, .dictionary, .null, nil: return nil
        }
    }

    private func appendMessage(_ role: Message.Role, _ text: String, detail: String? = nil) {
        messages.append(Message(role: role, text: text, detail: detail))
    }

    private func appendActivity(_ kind: Activity.Kind, title: String, detail: String) {
        activities.insert(Activity(kind: kind, title: title, detail: clippedDetail(detail)), at: 0)
        if activities.count > 80 {
            activities.removeLast(activities.count - 80)
        }
    }

    private func clippedDetail(_ detail: String) -> String {
        let normalized = detail.replacingOccurrences(of: "\n", with: " ")
        guard normalized.count > 240 else { return normalized }
        return String(normalized.prefix(240)) + "..."
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
        authLabel = "Checking auth"
        deviceCode = nil
        deviceCodeURL = nil
        assistantMessageIDsByItemID = [:]
        commandMessageIDsByItemID = [:]
    }
}

struct CodexChatView: View {
    @State private var model = CodexChatModel()
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            AppBackdrop()

            Group {
                if !model.isConnected {
                    WelcomeFlowView(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else if !model.isAuthenticated {
                    SignInFlowView(model: model, openURL: openURL)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if !model.isThreadReady {
                    PreparingChatView(model: model)
                        .transition(.opacity)
                } else {
                    ChatWorkspaceView(model: model)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.88), value: flowKey)
        }
        .foregroundStyle(AppTheme.text)
        .tint(AppTheme.accent)
    }

    private var flowKey: String {
        if !model.isConnected { return "connect" }
        if !model.isAuthenticated { return "sign-in" }
        if !model.isThreadReady { return "prepare" }
        return "chat"
    }
}

struct AppBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppTheme.background,
                    AppTheme.panelAlt,
                    AppTheme.backgroundWarm
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(AppTheme.accent.opacity(0.14))
                .frame(width: 420, height: 420)
                .blur(radius: 80)
                .offset(x: -310, y: -220)
            Circle()
                .fill(Color.orange.opacity(0.12))
                .frame(width: 360, height: 360)
                .blur(radius: 90)
                .offset(x: 330, y: 240)
        }
        .ignoresSafeArea()
    }
}

struct WelcomeFlowView: View {
    @Bindable var model: CodexChatModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 32)

            VStack(spacing: 22) {
                BrandMark()

                VStack(spacing: 8) {
                    Text("Start a Codex chat")
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.text)
                    Text("Connect to your local Codex app-server. If your installed Codex is already signed in, you will go straight to chat.")
                        .font(.title3)
                        .foregroundStyle(AppTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }

                VStack(spacing: 12) {
                    LabeledTextField(
                        title: "Workspace",
                        subtitle: "Where Codex will read and write files",
                        text: $model.workspacePath,
                        systemImage: "folder"
                    )
                    LabeledTextField(
                        title: "Codex binary",
                        subtitle: "Leave blank to use PATH",
                        text: $model.codexBinaryPath,
                        systemImage: "terminal"
                    )
                }
                .frame(maxWidth: 620)

                if let message = model.connectionErrorMessage {
                    ErrorBanner(message: message)
                        .frame(maxWidth: 620)
                }

                Button {
                    Task { await model.connect() }
                } label: {
                    HStack(spacing: 10) {
                        if model.isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        Text(model.isConnecting ? "Connecting" : "Connect")
                    }
                    .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isConnecting)

                Text("Uses CODEX_HOME=\(defaultCodexHome()) for installed auth.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
            .padding(34)
            .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 34, y: 18)
            .padding(.horizontal, 28)

            Spacer(minLength: 32)
        }
    }
}

struct SignInFlowView: View {
    @Bindable var model: CodexChatModel
    let openURL: OpenURLAction

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 32)

            VStack(spacing: 22) {
                BrandMark(systemImage: "person.crop.circle.badge.checkmark")

                VStack(spacing: 8) {
                    Text("Sign in to continue")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.text)
                    Text("Codex did not find a usable ChatGPT account or API key in ~/.codex. Complete one sign-in step, then your chat opens automatically.")
                        .font(.title3)
                        .foregroundStyle(AppTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }

                VStack(spacing: 14) {
                    Button {
                        Task { await model.startDeviceCodeLogin() }
                    } label: {
                        Label(model.deviceCode == nil ? "Continue with ChatGPT" : "Device login in progress", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if let code = model.deviceCode {
                        DeviceCodeCard(code: code, urlString: model.deviceCodeURL, openURL: openURL)
                    }

                    HStack(spacing: 12) {
                        Rectangle()
                            .fill(AppTheme.border)
                            .frame(height: 1)
                        Text("or use an API key")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppTheme.mutedText)
                        Rectangle()
                            .fill(AppTheme.border)
                            .frame(height: 1)
                    }

                    HStack(spacing: 10) {
                        SecureField("OpenAI API key", text: $model.apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button("Use key") {
                            Task { await model.loginWithAPIKey() }
                        }
                        .disabled(model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .frame(maxWidth: 520)

                Button("Disconnect") {
                    Task { await model.disconnect() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(34)
            .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 34, y: 18)
            .padding(.horizontal, 28)

            Spacer(minLength: 32)
        }
    }
}

struct PreparingChatView: View {
    let model: CodexChatModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing your chat")
                .font(.title2.weight(.semibold))
                .foregroundStyle(AppTheme.text)
            Text(model.serverName.map { "Connected to \($0). Creating a workspace thread..." } ?? "Creating a workspace thread...")
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(34)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.10), radius: 28, y: 16)
    }
}

struct ChatWorkspaceView: View {
    @Bindable var model: CodexChatModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ChatHeader(model: model)
                Divider()
                TranscriptView(model: model)
                Divider()
                ComposerBar(model: model)
            }
            .frame(minWidth: 560)

            Divider()
            SessionSidebar(model: model)
                .frame(width: 270)
        }
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(AppTheme.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.13), radius: 34, y: 18)
        .padding(20)
    }
}

struct ChatHeader: View {
    let model: CodexChatModel

    var body: some View {
        HStack(spacing: 14) {
            BrandMark(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.text)
                Text(model.workspacePath)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            StatusPill(state: model.connectionState)
            Button("Disconnect") {
                Task { await model.disconnect() }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

struct BrandMark: View {
    var systemImage = "command"
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppTheme.accent, Color.blue.opacity(0.76)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: AppTheme.accent.opacity(0.24), radius: 18, y: 10)
    }
}

struct LabeledTextField: View {
    let title: String
    let subtitle: String
    @Binding var text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.text)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                TextField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(12)
        .background(AppTheme.panelAlt, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.border, lineWidth: 1)
        )
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct DeviceCodeCard: View {
    let code: String
    let urlString: String?
    let openURL: OpenURLAction

    var body: some View {
        VStack(spacing: 10) {
            Text("Enter this code in your browser")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
            Text(code)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(AppTheme.text)
                .tracking(2)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(AppTheme.border, lineWidth: 1)
                )
            if let urlString, let url = URL(string: urlString) {
                Button("Open sign-in page") { openURL(url) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
}

struct TranscriptView: View {
    @Bindable var model: CodexChatModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.messages.isEmpty {
                    EmptyTranscriptView(model: model)
                        .frame(maxWidth: .infinity, minHeight: 360)
                        .padding(24)
                } else {
                    LazyVStack(spacing: 18) {
                        ForEach(model.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(22)
                }
            }
            .background(AppTheme.chat)
            .onChange(of: model.messages.count) { _, _ in
                if let last = model.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct EmptyTranscriptView: View {
    @Bindable var model: CodexChatModel

    private let prompts = [
        "Summarize this package and point out the main extension points.",
        "Inspect the current git diff and tell me what still needs polish.",
        "Find one small improvement we can make safely."
    ]

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 42))
                .foregroundStyle(AppTheme.accent)
            VStack(spacing: 6) {
                Text("You are in chat")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppTheme.text)
                Text("Ask Codex to inspect code, explain behavior, or make changes in this workspace.")
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                ForEach(prompts, id: \.self) { prompt in
                    Button(prompt) {
                        model.draft = prompt
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: 460)
    }
}

struct MessageBubble: View {
    let message: CodexChatModel.Message

    var body: some View {
        if message.role == .system {
            SystemMessage(text: message.text)
        } else if let commandRun = message.commandRun {
            HStack(alignment: .top, spacing: 10) {
                MessageAvatar(role: .terminal)
                TerminalRunView(run: commandRun)
                Spacer(minLength: 80)
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                if message.role == .user { Spacer(minLength: 80) }

                if message.role == .assistant {
                    MessageAvatar(role: message.role)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(message.role.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                        if message.isStreaming {
                            Text("Streaming")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(AppTheme.accentSoft, in: Capsule())
                        }
                    }

                    AssistantContentView(blocks: message.renderBlocks)
                        .foregroundStyle(AppTheme.text)

                    if let detail = message.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .padding(14)
                .background(background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(border, lineWidth: 1)
                )
                .frame(maxWidth: 650, alignment: .leading)

                if message.role == .user {
                    MessageAvatar(role: message.role)
                } else {
                    Spacer(minLength: 80)
                }
            }
        }
    }

    private var background: Color {
        switch message.role {
        case .user: return AppTheme.userBubble
        case .assistant: return AppTheme.assistantBubble
        case .terminal: return AppTheme.assistantBubble
        case .system: return AppTheme.systemBubble
        }
    }

    private var border: Color {
        switch message.role {
        case .user: return AppTheme.accent.opacity(0.28)
        case .assistant: return AppTheme.border
        case .terminal: return AppTheme.border
        case .system: return Color.orange.opacity(0.35)
        }
    }
}

struct TerminalRunView: View {
    let run: CodexChatModel.Message.CommandRun

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.white.opacity(0.78))
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.command)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let cwd = run.cwd, !cwd.isEmpty {
                        Text(cwd)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                TerminalStatusPill(run: run)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(red: 0.10, green: 0.12, blue: 0.18))

            ScrollView(.horizontal) {
                Text(outputText)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Color(red: 0.88, green: 0.96, blue: 0.90))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            .background(Color(red: 0.04, green: 0.05, blue: 0.07))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.black.opacity(0.16), lineWidth: 1)
        )
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var outputText: String {
        if run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return run.isStreaming ? "Running..." : "No output"
        }
        return run.output
    }
}

struct TerminalStatusPill: View {
    let run: CodexChatModel.Message.CommandRun

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
    }

    private var label: String {
        if run.isStreaming { return "running" }
        if let exitCode = run.exitCode { return "exit \(exitCode)" }
        return run.status
    }

    private var color: Color {
        if run.isStreaming { return Color(red: 0.42, green: 0.72, blue: 1.0) }
        if let exitCode = run.exitCode, exitCode != 0 { return Color(red: 1.0, green: 0.45, blue: 0.45) }
        return Color(red: 0.42, green: 0.88, blue: 0.50)
    }
}

struct MessageAvatar: View {
    let role: CodexChatModel.Message.Role

    var body: some View {
        Image(systemName: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(role == .user ? AppTheme.accent : .white)
            .frame(width: 28, height: 28)
            .background(role == .user ? AppTheme.accentSoft : AppTheme.accent, in: Circle())
    }

    private var systemImage: String {
        switch role {
        case .user: return "person.fill"
        case .assistant, .system: return "command"
        case .terminal: return "terminal.fill"
        }
    }
}

struct SystemMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(AppTheme.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(AppTheme.panelAlt, in: Capsule())
            .frame(maxWidth: .infinity)
    }
}

struct AssistantContentView: View {
    let blocks: [AssistantRenderBlock]

    var body: some View {
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
                        .foregroundStyle(AppTheme.secondaryText)
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
        Text(markdown)
            .textSelection(.enabled)
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
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.22))

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ComposerBar: View {
    @Bindable var model: CodexChatModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask Codex anything about this workspace...", text: $model.draft, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(AppTheme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(AppTheme.border, lineWidth: 1)
                    )

                Button {
                    Task { await model.sendDraft() }
                } label: {
                    Label(model.isSending ? "Running" : "Send", systemImage: model.isSending ? "hourglass" : "arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.canSend)
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
            }

            HStack(spacing: 12) {
                Label("workspace-write", systemImage: "lock.open")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                Label("auto-review approvals", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Button("Interrupt") {
                    Task { await model.interrupt() }
                }
                .disabled(!model.isSending)
            }
        }
        .padding(16)
        .background(AppTheme.panelAlt)
    }
}

struct SessionSidebar: View {
    let model: CodexChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Session")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.text)
                Text(model.serverName ?? "Codex")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            VStack(alignment: .leading, spacing: 10) {
                SidebarFact(icon: "folder", title: "Workspace", value: model.workspacePath)
                SidebarFact(icon: "person.crop.circle", title: "Auth", value: model.isAuthenticated ? model.authLabel : "Required")
                SidebarFact(icon: "text.bubble", title: "Thread", value: model.isThreadReady ? "Ready" : "Preparing")
            }

            Divider()

            Text("Recent Activity")
                .font(.subheadline.weight(.semibold))

            ScrollView {
                if model.activities.isEmpty {
                    Text("Nothing yet. Activity appears here while Codex works.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.activities.prefix(10)) { activity in
                            ActivityRow(activity: activity)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(AppTheme.sidebar)
    }
}

struct SidebarFact: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.text)
                Text(value)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }
}

struct ActivityRow: View {
    let activity: CodexChatModel.Activity

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(activity.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.text)
                Text(activity.detail)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(4)
            }
        }
        .padding(10)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.border, lineWidth: 1)
        )
    }

    private var color: Color {
        switch activity.kind {
        case .turn: return AppTheme.accent
        case .tool: return Color(red: 0.49, green: 0.20, blue: 0.82)
        case .token: return Color(red: 0.04, green: 0.48, blue: 0.23)
        case .login: return Color(red: 0.72, green: 0.34, blue: 0.00)
        case .notice: return AppTheme.mutedText
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
        .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case .disconnected: return AppTheme.mutedText
        case .connecting: return Color(red: 0.72, green: 0.34, blue: 0.00)
        case .connected: return Color(red: 0.04, green: 0.48, blue: 0.23)
        case .failed: return Color(red: 0.72, green: 0.09, blue: 0.12)
        }
    }
}
