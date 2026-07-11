import CodexCore
import Foundation

public struct CodexTranscriptReducerV2: Sendable {
    public let threadID: String
    public private(set) var transcript: CodexTranscriptV2
    private var pendingUsers: [String: CodexUserMessageV2] = [:]
    private var reasoningText: [String: String] = [:]
    private var turnStartedAt: [String: Int64] = [:]

    public init(threadID: String, transcript: CodexTranscriptV2 = .init()) {
        self.threadID = threadID; self.transcript = transcript
    }

    public mutating func submitLocalUserMessage(text: String, clientID: String) {
        let user = CodexUserMessageV2(id: "local-\(clientID)", clientID: clientID, text: text, isOptimistic: true)
        pendingUsers[clientID] = user
        if let index = transcript.turns.lastIndex(where: { if case .working = $0.status { $0.userMessage == nil } else { false } }) {
            transcript.turns[index].userMessage = user
        } else {
            transcript.turns.append(.init(id: "local-\(clientID)", userMessage: user, status: .working(since: nil)))
        }
    }

    public mutating func apply(method: String, params: CodexJSONValue) {
        guard let root = params.object, belongsToThread(root) else { return }
        switch method {
        case "turn/started": startTurn(root)
        case "turn/completed": completeTurn(root)
        case "turn/failed": failTurn(root)
        case "item/started": applyItem(root, completed: false)
        case "item/completed": applyItem(root, completed: true)
        case "item/agentMessage/delta": appendAgentDelta(root)
        case "item/reasoning/summaryTextDelta": appendReasoningDelta(root)
        case "item/commandExecution/outputDelta": appendCommandOutput(root)
        case "error": applyError(root)
        default: break
        }
    }

    public mutating func restoreHistory(items: [CodexJSONValue]) {
        transcript = .init(); reasoningText = [:]; turnStartedAt = [:]
        var fabricated = 0
        var turnID: String?
        for value in items {
            guard let item = value.object else { continue }
            if item.string("type") == "userMessage" || turnID == nil {
                fabricated += 1; turnID = "history-\(fabricated)"
                transcript.turns.append(.init(id: turnID!, status: .working(since: nil)))
            }
            applyHistoryItem(item, turnID: turnID!)
        }
        for index in transcript.turns.indices {
            finishTurn(at: index, duration: nil)
        }
    }

    public mutating func restoreHistory(params: CodexJSONValue) {
        guard let root = params.object, let items = root.array("items") else { return }
        restoreHistory(items: items)
    }

    private func belongsToThread(_ root: [String: CodexJSONValue]) -> Bool {
        let candidate = root.string("threadId") ?? root.object("turn")?.string("threadId") ?? root.object("item")?.string("threadId")
        return candidate == nil || candidate == threadID
    }

    private mutating func startTurn(_ root: [String: CodexJSONValue]) {
        guard let turn = root.object("turn"), let id = turn.string("id") else { return }
        let startedAt = turn.int64("startedAt")
        if let startedAt { turnStartedAt[id] = startedAt }
        ensureTurn(id, since: startedAt)
    }

    private mutating func completeTurn(_ root: [String: CodexJSONValue]) {
        guard let turn = root.object("turn"), let id = turn.string("id"), let index = turnIndex(id) else { return }
        if let error = turn.string("error"), !error.isEmpty { failTurn(at: index, message: error) }
        else { finishTurn(at: index, duration: completionDuration(turn, turnID: id)) }
    }

    private mutating func failTurn(_ root: [String: CodexJSONValue]) {
        let turn = root.object("turn") ?? root
        guard let id = turn.string("id") ?? root.string("turnId") else { return }
        ensureTurn(id, since: nil)
        if let index = turnIndex(id) { failTurn(at: index, message: turn.string("error") ?? root.string("message") ?? "Turn failed") }
    }

    private mutating func applyItem(_ root: [String: CodexJSONValue], completed: Bool) {
        guard let item = root.object("item"), let turnID = root.string("turnId"), let type = item.string("type") else { return }
        guard isHandledItemType(type) else { return }
        ensureTurn(turnID, since: nil)
        guard let index = turnIndex(turnID) else { return }
        switch type {
        case "userMessage": applyUser(item, turn: index)
        case "agentMessage": applyAgent(item, turn: index, completed: completed)
        case "reasoning": applyReasoning(item, turn: index, completed: completed)
        case "dynamicToolCall": applyProductTool(item, turn: index, completed: completed)
        case "plan": applyPlan(item, turn: index, completed: completed)
        case "enteredReviewMode": applyNotice(item, message: "Entered review mode", turn: index)
        case "exitedReviewMode": applyNotice(item, message: "Exited review mode", turn: index)
        case "contextCompaction": applyNotice(item, message: "Compacted context", turn: index)
        default: applyWork(item, type: type, turn: index, completed: completed)
        }
    }

    private mutating func applyHistoryItem(_ item: [String: CodexJSONValue], turnID: String) {
        guard let index = turnIndex(turnID), let type = item.string("type") else { return }
        switch type {
        case "userMessage": applyUser(item, turn: index)
        case "agentMessage": applyAgent(item, turn: index, completed: true)
        case "reasoning": break
        case "dynamicToolCall": applyProductTool(item, turn: index, completed: true)
        case "plan": applyPlan(item, turn: index, completed: true)
        case "enteredReviewMode": applyNotice(item, message: "Entered review mode", turn: index)
        case "exitedReviewMode": applyNotice(item, message: "Exited review mode", turn: index)
        case "contextCompaction": applyNotice(item, message: "Compacted context", turn: index)
        case "hookPrompt": break
        default: applyWork(item, type: type, turn: index, completed: true)
        }
    }

    private mutating func applyPlan(_ item: [String: CodexJSONValue], turn index: Int, completed: Bool) {
        guard let id = item.string("id"), let text = item.string("text"), !text.isEmpty else { return }
        closeGroup(turn: index)
        upsertProse(.init(id: id, text: text, isStreaming: !completed), turn: index)
        refreshTail(turn: index)
    }

    private mutating func applyNotice(_ item: [String: CodexJSONValue], message: String, turn index: Int) {
        guard let id = item.string("id") else { return }
        closeGroup(turn: index)
        let notice = CodexTurnNoticeV2(id: id, message: message)
        if let entry = transcript.turns[index].narrative.firstIndex(where: { $0.id == id }) {
            transcript.turns[index].narrative[entry] = .notice(notice)
        } else {
            transcript.turns[index].narrative.append(.notice(notice))
        }
        refreshTail(turn: index)
    }

    private mutating func applyUser(_ item: [String: CodexJSONValue], turn index: Int) {
        guard let id = item.string("id") else { return }
        let clientID = item.string("clientId"), text = item.textContent
        if let clientID { pendingUsers.removeValue(forKey: clientID) }
        transcript.turns[index].userMessage = .init(id: id, clientID: clientID, text: text, isOptimistic: false)
    }

    private mutating func applyAgent(_ item: [String: CodexJSONValue], turn index: Int, completed: Bool) {
        guard let id = item.string("id") else { return }
        let text = item.string("text") ?? "", phase = item.string("phase")
        if phase == "commentary" {
            closeGroup(turn: index)
            upsertProse(.init(id: id, text: text, isStreaming: !completed), turn: index)
        } else if phase == "final_answer" {
            transcript.turns[index].finalAnswer = .init(id: id, text: text, isStreaming: !completed)
        } else {
            if let previous = transcript.turns[index].finalAnswer, previous.id != id {
                transcript.turns[index].narrative.append(.prose(previous))
            }
            transcript.turns[index].finalAnswer = .init(id: id, text: text, isStreaming: !completed)
        }
        refreshTail(turn: index)
    }

    private mutating func applyReasoning(_ item: [String: CodexJSONValue], turn index: Int, completed: Bool) {
        guard let id = item.string("id") else { return }
        if completed { reasoningText.removeValue(forKey: id); refreshTail(turn: index); return }
        let summary = item.stringArrayText("summary")
        reasoningText[id] = summary
        transcript.turns[index].liveTail = summary.nonEmpty ?? "Thinking"
    }

    private mutating func applyProductTool(_ item: [String: CodexJSONValue], turn index: Int, completed: Bool) {
        guard let id = item.string("id") else { return }
        closeGroup(turn: index)
        let value = CodexProductToolCallV2(id: id, tool: item.string("tool") ?? "Tool", namespace: item.string("namespace"), arguments: item["arguments"], status: status(item, completed: completed), contentItems: item.array("contentItems") ?? [], success: item.bool("success"))
        if let entryIndex = transcript.turns[index].narrative.firstIndex(where: { $0.id == id }) { transcript.turns[index].narrative[entryIndex] = .productToolCall(value) }
        else { transcript.turns[index].narrative.append(.productToolCall(value)) }
        refreshTail(turn: index)
    }

    private mutating func applyWork(_ item: [String: CodexJSONValue], type: String, turn index: Int, completed: Bool) {
        guard let row = makeRow(item, type: type, completed: completed) else { return }
        if let location = rowLocation(id: row.id, turn: index) {
            guard case .workGroup(var group) = transcript.turns[index].narrative[location.entry] else { return }
            group.rows[location.row] = row; group.header = CodexWorkGroupHeaderV2.synthesize(rows: group.rows)
            group.isLive = group.rows.contains(where: \.isInProgress)
            transcript.turns[index].narrative[location.entry] = .workGroup(group)
        } else if case .workGroup(var group)? = transcript.turns[index].narrative.last,
                  canAppend(row, to: group) {
            group.rows.append(row); group.header = CodexWorkGroupHeaderV2.synthesize(rows: group.rows)
            group.isLive = group.rows.contains(where: \.isInProgress)
            transcript.turns[index].narrative[transcript.turns[index].narrative.count - 1] = .workGroup(group)
        } else {
            let header = CodexWorkGroupHeaderV2.synthesize(rows: [row])
            guard !header.isEmpty else { return }
            let group = CodexWorkGroupV2(id: "group-\(row.id)", header: header, rows: [row], isLive: row.isInProgress)
            transcript.turns[index].narrative.append(.workGroup(group))
        }
        refreshTail(turn: index)
    }

    private func makeRow(_ item: [String: CodexJSONValue], type: String, completed: Bool) -> CodexWorkRowV2? {
        guard let id = item.string("id") else { return nil }
        let state = status(item, completed: completed)
        switch type {
        case "commandExecution":
            let command = item.string("command") ?? "Command"
            return .command(.init(id: id, command: command, label: "Ran `\(shortCommand(command))`", action: commandCategory(item), status: state, exitCode: item.int("exitCode"), durationMs: item.int("durationMs"), output: item.string("aggregatedOutput")))
        case "fileChange":
            let files = item.array("changes")?.compactMap { $0.object?.string("path") } ?? []
            return .fileChange(.init(id: id, files: files, status: state, durationMs: item.int("durationMs"), diff: item.string("diff")))
        case "mcpToolCall":
            let app = item.object("appContext")?.string("appName") ?? item.string("server") ?? "Tool"
            return .mcpToolCall(.init(id: id, appName: app, server: item.string("server") ?? app, tool: item.string("tool") ?? "Tool", status: state, durationMs: item.int("durationMs"), errorFirstLine: state == .failed ? mcpError(item) : nil, arguments: item["arguments"], result: item["result"]))
        case "webSearch": return .webSearch(.init(id: id, query: item.string("query") ?? "", status: state))
        case "collabAgentToolCall":
            let tool = item.string("tool") ?? "", action: CodexCollabActionV2 = tool == "spawnAgent" ? .created : (tool == "closeAgent" ? .closed : .waited)
            let names = item.array("receiverThreadIds")?.compactMap(\.stringValue) ?? []
            let messages = item.object("agentsStates")?.reduce(into: [String: String]()) { result, entry in
                if let message = entry.value.object?.string("message"), !message.isEmpty { result[entry.key] = message }
            } ?? [:]
            return .collabAgent(.init(
                id: id, action: action, agentNames: names, instructions: item.string("prompt"),
                agentMessages: messages, status: state
            ))
        case "subAgentActivity":
            let action: CodexCollabActionV2
            switch item.string("kind") {
            case "started": action = .started
            case "interacted": action = .interacted
            case "interrupted": action = .interrupted
            default: return nil
            }
            let agent = item.string("agentPath") ?? item.string("agentThreadId") ?? "agent"
            return .collabAgent(.init(id: id, action: action, agentNames: [agent], instructions: nil, status: state))
        case "imageGeneration":
            return .other(.init(id: id, label: "Generating an image", status: state))
        default: return nil
        }
    }

    private mutating func appendAgentDelta(_ root: [String: CodexJSONValue]) {
        guard let turnID = root.string("turnId"), let id = root.string("itemId"), let delta = root.string("delta"), let index = turnIndex(turnID) else { return }
        if transcript.turns[index].finalAnswer?.id == id { transcript.turns[index].finalAnswer?.text += delta; return }
        for entry in transcript.turns[index].narrative.indices where transcript.turns[index].narrative[entry].id == id {
            if case .prose(var prose) = transcript.turns[index].narrative[entry] { prose.text += delta; transcript.turns[index].narrative[entry] = .prose(prose) }
        }
    }

    private mutating func appendReasoningDelta(_ root: [String: CodexJSONValue]) {
        guard let turnID = root.string("turnId"), let id = root.string("itemId"), let delta = root.string("delta"), let index = turnIndex(turnID) else { return }
        reasoningText[id, default: ""] += delta
        transcript.turns[index].liveTail = reasoningText[id]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Thinking"
    }

    private mutating func appendCommandOutput(_ root: [String: CodexJSONValue]) {
        guard let turnID = root.string("turnId"), let id = root.string("itemId"), let delta = root.string("delta"), let index = turnIndex(turnID), let location = rowLocation(id: id, turn: index), case .workGroup(var group) = transcript.turns[index].narrative[location.entry], case .command(var command) = group.rows[location.row] else { return }
        command.output = (command.output ?? "") + delta; group.rows[location.row] = .command(command); transcript.turns[index].narrative[location.entry] = .workGroup(group)
    }

    private mutating func applyError(_ root: [String: CodexJSONValue]) {
        guard let id = root.string("turnId"), let index = turnIndex(id) else { return }
        failTurn(at: index, message: root.string("message") ?? "Turn failed")
    }

    private mutating func ensureTurn(_ id: String, since: Int64?) {
        if let index = turnIndex(id) {
            if case .working(let existingSince) = transcript.turns[index].status,
               existingSince == nil,
               let since {
                transcript.turns[index].status = .working(since: since)
            }
            return
        }
        if let provisional = transcript.turns.firstIndex(where: { $0.id.hasPrefix("local-") && $0.userMessage?.isOptimistic == true }) {
            transcript.turns[provisional].id = id
            transcript.turns[provisional].status = .working(since: since)
            turnStartedAt[id] = since ?? Int64(Date().timeIntervalSince1970)
            return
        }
        var user: CodexUserMessageV2?
        if let first = pendingUsers.first { user = first.value }
        turnStartedAt[id] = turnStartedAt[id] ?? Int64(Date().timeIntervalSince1970)
        transcript.turns.append(.init(id: id, userMessage: user, status: .working(since: since)))
    }
    private func turnIndex(_ id: String) -> Int? { transcript.turns.firstIndex { $0.id == id } }
    private mutating func finishTurn(at index: Int, duration: Int?) {
        transcript.turns[index].status = .done(durationMs: duration); transcript.turns[index].liveTail = nil
        for entry in transcript.turns[index].narrative.indices { if case .workGroup(var group) = transcript.turns[index].narrative[entry] { group.isLive = false; transcript.turns[index].narrative[entry] = .workGroup(group) } }
        transcript.turns[index].finalAnswer?.isStreaming = false
    }
    private mutating func failTurn(at index: Int, message: String) { finishTurn(at: index, duration: nil); transcript.turns[index].status = .failed(message: message) }
    private mutating func closeGroup(turn index: Int) { if case .workGroup(var group)? = transcript.turns[index].narrative.last { group.isLive = false; transcript.turns[index].narrative[transcript.turns[index].narrative.count - 1] = .workGroup(group) } }
    private mutating func upsertProse(_ prose: CodexAssistantTextV2, turn index: Int) { if let i = transcript.turns[index].narrative.firstIndex(where: { $0.id == prose.id }) { transcript.turns[index].narrative[i] = .prose(prose) } else { transcript.turns[index].narrative.append(.prose(prose)) } }
    private func rowLocation(id: String, turn: Int) -> (entry: Int, row: Int)? { for (e, entry) in transcript.turns[turn].narrative.enumerated() { if case .workGroup(let group) = entry, let r = group.rows.firstIndex(where: { $0.id == id }) { return (e, r) } }; return nil }

    private mutating func refreshTail(turn index: Int) {
        guard case .working = transcript.turns[index].status else { transcript.turns[index].liveTail = nil; return }
        if let reasoning = reasoningText.values.first { transcript.turns[index].liveTail = reasoning.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).nonEmpty ?? "Thinking"; return }
        for entry in transcript.turns[index].narrative.reversed() {
            if case .productToolCall(let value) = entry, value.status == .inProgress { transcript.turns[index].liveTail = "Using \(value.tool)"; return }
            if case .workGroup(let group) = entry, let row = group.rows.last(where: \.isInProgress) { transcript.turns[index].liveTail = tail(row); return }
        }
        transcript.turns[index].liveTail = nil
    }

    private func tail(_ row: CodexWorkRowV2) -> String {
        switch row {
        case .command(let value): "Running \(shortCommand(value.command))"
        case .mcpToolCall(let value): "Asking \(value.appName)"
        case .fileChange: "Editing files"
        case .webSearch: "Searching"
        case .collabAgent(let value):
            switch value.action {
            case .created: "Creating an agent"
            case .waited: "Waiting for agents"
            default: "Working with agents"
            }
        case .other(let value): value.label
        }
    }
    private func canAppend(_ row: CodexWorkRowV2, to group: CodexWorkGroupV2) -> Bool {
        guard case .collabAgent(let incoming) = row,
              case .collabAgent(let previous)? = group.rows.last else { return true }
        let incomingIsWait = incoming.action == .waited
        let previousIsWait = previous.action == .waited
        return incomingIsWait == previousIsWait
    }
    private func status(_ item: [String: CodexJSONValue], completed: Bool) -> CodexWorkItemStatusV2 { if item.string("status") == "failed" || (item.int("exitCode").map { $0 != 0 } ?? false) { return .failed }; return completed ? .completed : .inProgress }
    private func commandCategory(_ item: [String: CodexJSONValue]) -> CodexWorkCategoryV2 { guard let action = item.array("commandActions")?.first?.object?.string("type") else { return .run }; switch action.lowercased() { case "read", "fileread": return .read; case "listfiles", "list": return .list; case "search", "searchfiles": return .search; default: return .run } }
    private func shortCommand(_ command: String) -> String { if let range = command.range(of: "-lc ") { return String(command[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }; return command }
    private func isHandledItemType(_ type: String) -> Bool {
        ["userMessage", "agentMessage", "reasoning", "dynamicToolCall", "plan",
         "enteredReviewMode", "exitedReviewMode", "contextCompaction", "commandExecution",
         "fileChange", "mcpToolCall", "webSearch", "collabAgentToolCall", "subAgentActivity",
         "imageGeneration"].contains(type)
    }
    private func completionDuration(_ turn: [String: CodexJSONValue], turnID: String) -> Int {
        if let duration = turn.int("durationMs") { return max(0, duration) }
        let start = turn.int64("startedAt") ?? turnStartedAt[turnID] ?? Int64(Date().timeIntervalSince1970)
        let end = turn.int64("completedAt") ?? Int64(Date().timeIntervalSince1970)
        return max(0, Int(end - start) * 1_000)
    }
    private func mcpError(_ item: [String: CodexJSONValue]) -> String? { if let error = item.string("error") { return error.firstLine }; if let result = item.object("result"), let error = result.object("structuredContent")?.string("error") { return error.firstLine }; return item.object("result")?.array("content")?.compactMap { $0.object?.string("text") }.first?.firstLine }
}

private extension CodexJSONValue {
    var object: [String: CodexJSONValue]? { if case .dictionary(let value) = self { value } else { nil } }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
}
private extension Dictionary where Key == String, Value == CodexJSONValue {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func object(_ key: String) -> [String: CodexJSONValue]? { self[key]?.object }
    func array(_ key: String) -> [CodexJSONValue]? { if case .array(let value) = self[key] { value } else { nil } }
    func int(_ key: String) -> Int? { if case .int(let value) = self[key] { value } else { nil } }
    func int64(_ key: String) -> Int64? { int(key).map(Int64.init) }
    func bool(_ key: String) -> Bool? { if case .bool(let value) = self[key] { value } else { nil } }
    var textContent: String { array("content")?.compactMap { $0.object?.string("text") }.joined() ?? string("text") ?? "" }
    func stringArrayText(_ key: String) -> String { array(key)?.compactMap { $0.stringValue ?? $0.object?.string("text") }.joined() ?? "" }
}
private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var firstLine: String { components(separatedBy: .newlines).first ?? self }
}
