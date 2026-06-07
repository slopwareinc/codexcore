import SwiftUI
import Observation
import CodexCore
import CodexCoreUI

func defaultWorkspacePath() -> String {
    let current = FileManager.default.currentDirectoryPath
    if current != "/" { return current }

    let projectPath = "/Users/betterclever/Projects/slopware/CodexCore"
    if FileManager.default.fileExists(atPath: projectPath) { return projectPath }

    return FileManager.default.homeDirectoryForCurrentUser.path
}

@MainActor
@Observable
final class CodexChatModel {
    typealias ConnectionState = CodexConnectionState
    typealias Message = CodexChatMessage
    typealias Activity = CodexActivity

    var connectionState: ConnectionState = .disconnected
    var workspacePath = defaultWorkspacePath()
    var codexBinaryPath = "/Users/betterclever/.config/nvm/versions/node/v26.2.0/bin/codex"
    var draft = ""
    var apiKey = ""
    var messages: [Message] = []
    var lifecycleEvents: [CodexAgentLifecycleEvent] = []
    var sideChat: CodexSideChatState?
    var subagents: [CodexSubagentState] = []
    var activities: [Activity] = []
    var isSending = false
    var isAuthenticated = true
    var authLabel = "Checking auth"
    var deviceCodeURL: String?
    var deviceCode: String?
    var themePreset: CodexAgentThemePreset = .officialDark

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

    var showsChatWorkspace: Bool {
        isConnected && isAuthenticated && isThreadReady
    }

    private var codex: Codex?
    private var thread: CodexThread?
    private var activeTurn: CodexTurnHandle?
    private var streamTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var assistantMessageIDsByItemID: [String: UUID] = [:]
    private var commandMessageIDsByItemID: [String: UUID] = [:]
    private var agentStateMapper = CodexAgentStateMapper()

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
                    authLabel = accountInfo.email.map { "\(accountInfo.type) · \($0)" } ?? accountInfo.type
                    appendActivity(.login, title: "Signed in", detail: authLabel)
                } else if account.requiresOpenAIAuth {
                    authLabel = "Sign-in required"
                    appendActivity(.login, title: "Authentication required", detail: "Sign in to continue")
                    return
                } else {
                    authLabel = "Available"
                }
            } catch {
                authLabel = "Account check skipped"
                appendActivity(.login, title: "Account check skipped", detail: friendlyError(error))
            }

            try await ensureThread()
        } catch {
            connectionState = .failed(friendlyError(error))
            appendActivity(.notice, title: "Connection failed", detail: friendlyError(error))
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
            appendActivity(.login, title: "API key accepted", detail: "Authentication updated")
            try await ensureThread()
        } catch {
            appendActivity(.login, title: "API key login failed", detail: friendlyError(error))
        }
    }

    func startDeviceCodeLogin() async {
        guard let codex else { return }
        do {
            let handle = try await codex.loginChatGPTDeviceCode()
            deviceCodeURL = handle.verificationUrl
            deviceCode = handle.userCode
            appendActivity(.login, title: "Device login started", detail: "Code \(handle.userCode)")
            loginTask?.cancel()
            loginTask = Task { [weak self] in
                do {
                    _ = try await handle.wait()
                    await self?.finishDeviceCodeLogin()
                } catch {
                    await MainActor.run {
                        self?.appendActivity(.login, title: "Device login ended", detail: self?.friendlyError(error) ?? "")
                    }
                }
            }
        } catch {
            appendActivity(.login, title: "Device login failed", detail: friendlyError(error))
        }
    }

    func sendDraft() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        draft = ""
        isSending = true
        appendMessage(.user, prompt)
        appendActivity(.turn, title: "You asked Codex", detail: prompt)

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
            appendMessage(.system, "Failed to start turn: \(friendlyError(error))")
            appendActivity(.turn, title: "Turn failed to start", detail: friendlyError(error))
        }
    }

    private func finishDeviceCodeLogin() async {
        isAuthenticated = true
        authLabel = "ChatGPT"
        deviceCode = nil
        deviceCodeURL = nil
        appendActivity(.login, title: "Signed in with ChatGPT", detail: "Authentication updated")
        do {
            try await ensureThread()
        } catch {
            appendActivity(.turn, title: "Thread creation failed", detail: friendlyError(error))
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
        appendActivity(.notice, title: "Thread ready", detail: "Workspace session created")
        return thread
    }

    func interrupt() async {
        guard let activeTurn else { return }
        do {
            _ = try await activeTurn.interrupt()
            appendActivity(.turn, title: "Interrupt sent", detail: "Stopping the current turn")
        } catch {
            appendActivity(.turn, title: "Interrupt failed", detail: friendlyError(error))
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
            if agentStateMapper.messageDelta(delta.delta, itemID: delta.itemId) {
                syncAgentState()
            } else {
                appendAssistantDelta(delta.delta, itemID: delta.itemId)
            }
        case .itemStarted(let payload):
            if payload.item.type == "commandExecution" {
                startCommandRun(payload.item)
            } else if agentStateMapper.isSubagentItem(payload.item) {
                applyAgentItemStarted(payload.item)
            } else if payload.item.type == "agentMessage" || payload.item.type == "assistantMessage" {
                // Assistant message begins — handled by deltas.
            } else {
                appendActivity(.tool, title: "Working", detail: humanItemType(payload.item.type))
            }
        case .itemCompleted(let payload):
            applyCompletedItem(payload.item)
        case .threadTokenUsageUpdated(let payload):
            appendActivity(.token, title: "Token usage updated", detail: tokenSummary(payload.tokenUsage))
        case .turnStarted:
            appendActivity(.turn, title: "Codex is working", detail: "Turn started")
        case .turnCompleted:
            isSending = false
            activeTurn = nil
            appendActivity(.turn, title: "Turn complete", detail: "Codex finished")
        case .accountLoginCompleted:
            appendActivity(.login, title: "Login completed", detail: "Authentication updated")
        case .known(let method, let params):
            applyKnownNotification(method, params: params)
        case .unknown(let method, _):
            appendActivity(.notice, title: humanMethod(method), detail: "Notification")
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
            appendActivity(.notice, title: humanMethod(method.rawValue), detail: "App-server notification")
        }
    }

    private func applyCompletedItem(_ item: ThreadItem) {
        switch item.type {
        case "agentMessage", "assistantMessage":
            guard let text = item.text, !text.isEmpty else { return }
            if let messageID = assistantMessageIDsByItemID[item.id], let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].setText(text, parseContent: true)
                messages[index].isStreaming = false
                messages[index].detail = nil
            } else {
                let message = Message(role: .assistant, text: text)
                assistantMessageIDsByItemID[item.id] = message.id
                messages.append(message)
            }
            appendActivity(.tool, title: "Codex replied", detail: previewText(text))
        case "userMessage":
            break
        case "commandExecution":
            finalizeCommandRun(item)
        case _ where agentStateMapper.isSubagentItem(item):
            applyAgentItemCompleted(item)
        default:
            appendActivity(.tool, title: humanItemType(item.type), detail: "Completed")
        }
    }

    private func appendAssistantDelta(_ text: String, itemID: String) {
        if let messageID = assistantMessageIDsByItemID[itemID], let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].appendStreamingText(text)
            messages[index].isStreaming = true
            return
        }

        var message = Message(role: .assistant, text: text, isStreaming: true, parseContent: false)
        message.detail = nil
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
        appendActivity(.tool, title: "Ran a command", detail: run.command)
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

    private func applyAgentItemStarted(_ item: ThreadItem) {
        guard let update = agentStateMapper.itemStarted(item) else { return }
        syncAgentState()
        appendActivity(.tool, title: update.activityTitle, detail: update.activityDetail)
    }

    private func applyAgentItemCompleted(_ item: ThreadItem) {
        guard let update = agentStateMapper.itemCompleted(item) else { return }
        syncAgentState()
        appendActivity(.tool, title: update.activityTitle, detail: update.activityDetail)
    }

    private func syncAgentState() {
        lifecycleEvents = agentStateMapper.lifecycleEvents
        sideChat = agentStateMapper.sideChat
        subagents = agentStateMapper.subagents
    }

    // MARK: - Value helpers

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
        let normalized = detail.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard normalized.count > 160 else { return normalized }
        return String(normalized.prefix(160)) + "…"
    }

    private func previewText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokenSummary(_ usage: some Any) -> String {
        "Updated"
    }

    private func humanItemType(_ type: String) -> String {
        switch type {
        case "agentMessage", "assistantMessage": return "Codex message"
        case "commandExecution": return "Command"
        case "fileChange", "patch": return "File change"
        case "reasoning": return "Reasoning"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func humanMethod(_ method: String) -> String {
        method
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: ".", with: " ")
            .capitalized ?? method
    }

    private func friendlyError(_ error: Error) -> String {
        let described = String(describing: error)
        return described.count > 200 ? String(described.prefix(200)) + "…" : described
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
        agentStateMapper.reset()
        syncAgentState()
    }

}
