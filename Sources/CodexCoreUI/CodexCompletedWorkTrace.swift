import Foundation
import os

private let collabTraceLog = Logger(subsystem: "CodexCoreUI", category: "CollabTrace")

/// Post-turn collapse model matching the official Codex app.
///
/// Expanded body is a **chronological stream** of:
/// - intermediate assistant prose (normal narrative, not "Update done")
/// - lean activity lines (`Created 2 agents`, `Closed 2 agents`, `Ran …`)
///
/// Not a taxonomy of nested groups that re-label assistant messages as Updates.
public struct CodexCompletedWorkTrace: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            /// Intermediate assistant text — rendered as normal prose.
            case narrative(text: String)
            /// Muted activity line (Created / Closed / Ran / …).
            case activity(title: String, detail: String?, style: ActivityStyle)
        }

        public enum ActivityStyle: String, Equatable, Sendable {
            case createdAgents
            case closedAgents
            case command
            case read
            case edit
            case tool
            case plan
            case reasoning
            case notice
            case other
        }

        public var id: String
        public var kind: Kind
        public var createdAt: Date

        public init(id: String, kind: Kind, createdAt: Date) {
            self.id = id
            self.kind = kind
            self.createdAt = createdAt
        }
    }

    /// Kept for older group-based UI / tests that still inspect taxonomy buckets.
    public struct Group: Equatable, Sendable, Identifiable {
        public enum Kind: String, Equatable, Sendable {
            case createdAgents
            case closedAgents
            case command
            case read
            case edit
            case tool
            case plan
            case reasoning
            case notice
            case update
        }

        public var id: String { kind.rawValue + "-" + title }
        public var kind: Kind
        public var title: String
        public var operations: [Operation]
        public var isCollapsedByDefault: Bool

        public init(
            kind: Kind,
            title: String,
            operations: [Operation],
            isCollapsedByDefault: Bool = true
        ) {
            self.kind = kind
            self.title = title
            self.operations = operations
            self.isCollapsedByDefault = isCollapsedByDefault
        }
    }

    public struct Operation: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var detail: String?
        public var status: String
        public var isFailure: Bool
        public var isCollapsedByDefault: Bool
        public var message: CodexChatMessage?

        public init(
            id: String,
            title: String,
            detail: String?,
            status: String,
            isFailure: Bool,
            isCollapsedByDefault: Bool = true,
            message: CodexChatMessage? = nil
        ) {
            self.id = id
            self.title = title
            self.detail = detail
            self.status = status
            self.isFailure = isFailure
            self.isCollapsedByDefault = isCollapsedByDefault
            self.message = message
        }
    }

    public var id: String
    public var title: String
    /// Chronological expanded body (official presentation).
    public var entries: [Entry]
    /// Derived taxonomy (tests / optional secondary UI). Prefer `entries` for rendering.
    public var groups: [Group]
    public var isCollapsedByDefault: Bool
    public var createdAt: Date

    public init(
        id: String,
        title: String,
        entries: [Entry] = [],
        groups: [Group] = [],
        isCollapsedByDefault: Bool = true,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.entries = entries
        self.groups = groups
        self.isCollapsedByDefault = isCollapsedByDefault
        self.createdAt = createdAt
    }

    public static func project(from messages: [CodexChatMessage]) -> CodexCompletedWorkTrace? {
        project(
            intermediateMessages: messages.filter(\.isCompletedWorkTraceInput),
            intermediateAssistants: [],
            lifecycleEvents: [],
            startedAt: messages.map(\.createdAt).min(),
            endedAt: messages.first(where: { $0.role == .assistant && !$0.isStreaming })?.createdAt
                ?? messages.map(\.createdAt).max()
        )
    }

    public static func project(
        intermediateMessages: [CodexChatMessage],
        intermediateAssistants: [CodexChatMessage],
        lifecycleEvents: [CodexAgentLifecycleEvent],
        startedAt: Date?,
        endedAt: Date?
    ) -> CodexCompletedWorkTrace? {
        let workMessages = intermediateMessages.filter { !$0.isStreaming && $0.isCompletedWorkTraceInput }
        let assistantNotes = intermediateAssistants.filter {
            $0.role == .assistant
                && !$0.isStreaming
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let lifecycle = lifecycleEvents.sorted { $0.createdAt < $1.createdAt }

        collabTraceLog.debug(
            """
            project inputs workMsgs=\(workMessages.count) assistantNotes=\(assistantNotes.count) \
            lifecycle=\(lifecycle.count) \
            lifecycleTitles=\(lifecycle.map(\.title).joined(separator: " | "), privacy: .public) \
            lifecycleNameCounts=\(lifecycle.map { "\($0.title):\($0.agentNames.count)" }.joined(separator: ","), privacy: .public)
            """
        )

        let entries = chronologicalEntries(
            workMessages: workMessages,
            assistantNotes: assistantNotes,
            lifecycleEvents: lifecycle
        )
        let groups = legacyGroups(from: workMessages, lifecycleEvents: lifecycle)
        guard !entries.isEmpty || !groups.isEmpty else { return nil }

        let createdLines = entries.compactMap { entry -> String? in
            if case .activity(let title, _, let style) = entry.kind, style == .createdAgents { return title }
            return nil
        }
        let closedLines = entries.compactMap { entry -> String? in
            if case .activity(let title, _, let style) = entry.kind, style == .closedAgents { return title }
            return nil
        }
        collabTraceLog.debug(
            """
            project outputs entries=\(entries.count) createdLines=\(createdLines.joined(separator: " | "), privacy: .public) \
            closedLines=\(closedLines.joined(separator: " | "), privacy: .public)
            """
        )

        let start = startedAt
            ?? ([workMessages.map(\.createdAt), assistantNotes.map(\.createdAt), lifecycle.map(\.createdAt)]
                .flatMap { $0 }.min() ?? Date())
        let end = endedAt
            ?? ([workMessages.map(\.createdAt), assistantNotes.map(\.createdAt), lifecycle.map(\.createdAt)]
                .flatMap { $0 }.max() ?? start)

        let seconds = Int(max(0, end.timeIntervalSince(start)).rounded())
        let firstID = workMessages.first?.id.uuidString
            ?? assistantNotes.first?.id.uuidString
            ?? lifecycle.first?.id.uuidString
            ?? UUID().uuidString

        return CodexCompletedWorkTrace(
            id: "completed-work-\(firstID)-\(entries.count)-\(seconds)",
            title: "Worked for \(durationLabel(seconds: seconds))",
            entries: entries,
            groups: groups,
            isCollapsedByDefault: true,
            createdAt: start
        )
    }

    // MARK: - Chronological body (official)

    private static func chronologicalEntries(
        workMessages: [CodexChatMessage],
        assistantNotes: [CodexChatMessage],
        lifecycleEvents: [CodexAgentLifecycleEvent]
    ) -> [Entry] {
        var timed: [(Date, Entry)] = []

        for note in assistantNotes {
            timed.append((
                note.createdAt,
                Entry(
                    id: "narrative-\(note.id.uuidString)",
                    kind: .narrative(text: note.text),
                    createdAt: note.createdAt
                )
            ))
        }

        // Collab lifecycle → Created / Closed activity lines (merged by kind when adjacent).
        for event in lifecycleEvents {
            if let activity = collabActivityEntry(from: event) {
                timed.append((event.createdAt, activity))
            }
        }

        // Lean tool/command one-liners (no nested "Ran commands 5" bucket in the stream).
        for message in workMessages {
            if let entry = workActivityEntry(from: message) {
                timed.append((message.createdAt, entry))
            }
        }

        timed.sort { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1.id < rhs.1.id }
            return lhs.0 < rhs.0
        }

        return mergeAdjacentCollabActivities(timed.map(\.1))
    }

    private static func collabActivityEntry(from event: CodexAgentLifecycleEvent) -> Entry? {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = title.lowercased()
        let names = event.agentNames
        let detail = event.detail.trimmingCharacters(in: .whitespacesAndNewlines).traceNilIfBlank

        if lower.hasPrefix("spawn") || lower.hasPrefix("created") || lower.contains("spawning") {
            let count = max(names.count, 1)
            let label = count == 1
                ? (names.first.map { "Created \($0)" } ?? "Created 1 agent")
                : "Created \(count) agents"
            return Entry(
                id: "created-\(event.id.uuidString)",
                kind: .activity(title: label, detail: detail, style: .createdAgents),
                createdAt: event.createdAt
            )
        }
        if lower.hasPrefix("closed") || lower.contains("closing") {
            let count = max(names.count, 1)
            let label = count == 1
                ? (names.first.map { "Closed \($0)" } ?? "Closed 1 agent")
                : "Closed \(count) agents"
            return Entry(
                id: "closed-\(event.id.uuidString)",
                kind: .activity(title: label, detail: detail, style: .closedAgents),
                createdAt: event.createdAt
            )
        }
        if lower.contains("wait") {
            return Entry(
                id: "wait-\(event.id.uuidString)",
                kind: .activity(
                    title: title.isEmpty ? "Waiting" : title,
                    detail: detail ?? names.joined(separator: ", ").traceNilIfBlank,
                    style: .other
                ),
                createdAt: event.createdAt
            )
        }
        // Skip non-collab lifecycle noise in the expanded stream.
        return nil
    }

    private static func workActivityEntry(from message: CodexChatMessage) -> Entry? {
        if let run = message.commandRun {
            let cmd = run.command.trimmingCharacters(in: .whitespacesAndNewlines)
            return Entry(
                id: "cmd-\(run.itemID)",
                kind: .activity(
                    title: cmd.isEmpty ? "command" : cmd,
                    detail: nil,
                    style: .command
                ),
                createdAt: message.createdAt
            )
        }
        if let tool = message.toolCall, !isCollabTool(tool) {
            let name = tool.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let style: Entry.ActivityStyle = isReadTool(tool) ? .read : .tool
            return Entry(
                id: "tool-\(tool.itemID)",
                kind: .activity(title: name.isEmpty ? "tool" : name, detail: nil, style: style),
                createdAt: message.createdAt
            )
        }
        if let change = message.fileChange {
            return Entry(
                id: "edit-\(change.itemID)",
                kind: .activity(title: change.displayPath, detail: nil, style: .edit),
                createdAt: message.createdAt
            )
        }
        // Reasoning is absorbed into duration only — not listed as "Reasoned 3".
        if message.reasoningBlock != nil { return nil }
        if let plan = message.planUpdate {
            return Entry(
                id: "plan-\(plan.itemID)",
                kind: .activity(title: "Plan", detail: plan.summary.traceNilIfBlank, style: .plan),
                createdAt: message.createdAt
            )
        }
        if let notice = message.notice {
            return Entry(
                id: "notice-\(notice.itemID)",
                kind: .activity(title: notice.title, detail: notice.detail.traceNilIfBlank, style: .notice),
                createdAt: message.createdAt
            )
        }
        return nil
    }

    /// Merge consecutive Created/Closed lines by **unique agent names**, not raw event count.
    /// (item/started + item/completed used to emit two lifecycle rows per spawn → 2× counts.)
    private static func mergeAdjacentCollabActivities(_ entries: [Entry]) -> [Entry] {
        var result: [Entry] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            guard case .activity(let title, _, let style) = entry.kind,
                  style == .createdAgents || style == .closedAgents else {
                result.append(entry)
                index += 1
                continue
            }

            var names = orderedUniqueAgentNames(fromActivityTitle: title)
            var end = index + 1
            while end < entries.count {
                guard case .activity(let nextTitle, _, let nextStyle) = entries[end].kind,
                      nextStyle == style else { break }
                for name in orderedUniqueAgentNames(fromActivityTitle: nextTitle) where !names.contains(name) {
                    names.append(name)
                }
                end += 1
            }

            let verb = style == .createdAgents ? "Created" : "Closed"
            let mergedCount = max(names.count, 1)
            let mergedTitle: String = {
                if mergedCount == 1, let only = names.first, !only.isEmpty {
                    return "\(verb) \(only)"
                }
                return "\(verb) \(mergedCount) agents"
            }()

            collabTraceLog.debug(
                """
                merge style=\(style.rawValue, privacy: .public) rawEvents=\(end - index) \
                uniqueNames=\(names.joined(separator: ","), privacy: .public) \
                mergedTitle=\(mergedTitle, privacy: .public)
                """
            )

            result.append(Entry(
                id: "\(entry.id)-merged-\(mergedCount)",
                kind: .activity(title: mergedTitle, detail: nil, style: style),
                createdAt: entry.createdAt
            ))
            index = end
        }
        return result
    }

    /// Pull agent nicknames from titles like "Spawned Boole", "Created 2 agents", "Closed Schrodinger".
    private static func orderedUniqueAgentNames(fromActivityTitle title: String) -> [String] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["Created ", "Spawned ", "Spawning ", "Closed ", "Closing "]
        var rest = trimmed
        for prefix in prefixes where rest.hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
            break
        }
        if rest.hasSuffix(" agents") || rest.hasSuffix(" agent") {
            // Aggregate title without individual names.
            if let number = Int(rest.split(separator: " ").first ?? "") {
                return (0..<number).map { "agent-\($0)" }
            }
            return []
        }
        let name = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? [] : [name]
    }

    // MARK: - Legacy groups (tests)

    private static func legacyGroups(
        from workMessages: [CodexChatMessage],
        lifecycleEvents: [CodexAgentLifecycleEvent]
    ) -> [Group] {
        let (createdOps, closedOps) = collabOperations(from: lifecycleEvents)
        let commands = workMessages.compactMap(commandOperation)
        let reads = workMessages.compactMap(readOperation)
        let edits = workMessages.compactMap(editOperation)
        let tools = workMessages.compactMap { message -> Operation? in
            guard let tool = message.toolCall, !isReadTool(tool), !isCollabTool(tool) else { return nil }
            return toolOperation(from: message)
        }
        let plans = workMessages.compactMap(planOperation)
        let notices = workMessages.compactMap(noticeOperation)

        return [
            group(kind: .createdAgents, title: createdAgentsTitle(createdOps), operations: createdOps),
            group(kind: .closedAgents, title: closedAgentsTitle(closedOps), operations: closedOps),
            group(kind: .command, title: "Ran commands", operations: commands),
            group(kind: .read, title: "Read files", operations: reads),
            group(kind: .edit, title: "Edited files", operations: edits),
            group(kind: .tool, title: "Used tools", operations: tools),
            group(kind: .plan, title: "Updated plan", operations: plans),
            group(kind: .notice, title: "Notices", operations: notices)
        ].compactMap { $0 }
    }

    private static func collabOperations(
        from events: [CodexAgentLifecycleEvent]
    ) -> (created: [Operation], closed: [Operation]) {
        var created: [Operation] = []
        var closed: [Operation] = []
        for event in events {
            let lower = event.title.lowercased()
            let names = event.agentNames
            let detail = event.detail.trimmingCharacters(in: .whitespacesAndNewlines).traceNilIfBlank
            if lower.hasPrefix("spawn") || lower.hasPrefix("created") || lower.contains("spawning") {
                if names.isEmpty {
                    created.append(Operation(id: event.id.uuidString, title: event.title, detail: detail, status: event.status.rawValue, isFailure: event.status == .failed))
                } else {
                    for (i, name) in names.enumerated() {
                        created.append(Operation(id: "\(event.id.uuidString)-c-\(i)", title: "Created \(name)", detail: detail, status: event.status.rawValue, isFailure: event.status == .failed))
                    }
                }
            } else if lower.hasPrefix("closed") || lower.contains("closing") {
                if names.isEmpty {
                    closed.append(Operation(id: event.id.uuidString, title: event.title, detail: detail, status: event.status.rawValue, isFailure: event.status == .failed))
                } else {
                    for (i, name) in names.enumerated() {
                        closed.append(Operation(id: "\(event.id.uuidString)-x-\(i)", title: "Closed \(name)", detail: detail, status: event.status.rawValue, isFailure: event.status == .failed))
                    }
                }
            }
        }
        return (created, closed)
    }

    private static func createdAgentsTitle(_ ops: [Operation]) -> String {
        ops.count <= 1 ? "Created 1 agent" : "Created \(ops.count) agents"
    }

    private static func closedAgentsTitle(_ ops: [Operation]) -> String {
        ops.count <= 1 ? "Closed 1 agent" : "Closed \(ops.count) agents"
    }

    private static func group(kind: Group.Kind, title: String, operations: [Operation]) -> Group? {
        guard !operations.isEmpty else { return nil }
        return Group(kind: kind, title: title, operations: operations, isCollapsedByDefault: true)
    }

    private static func commandOperation(from message: CodexChatMessage) -> Operation? {
        guard let run = message.commandRun else { return nil }
        return Operation(
            id: run.itemID,
            title: run.command,
            detail: run.output.traceNilIfBlank,
            status: run.exitCode.map { $0 == 0 ? "exit 0" : "exit \($0)" } ?? (run.status.traceNilIfBlank ?? "done"),
            isFailure: (run.exitCode ?? 0) != 0 || run.status.localizedCaseInsensitiveContains("fail"),
            message: message
        )
    }

    private static func readOperation(from message: CodexChatMessage) -> Operation? {
        guard let tool = message.toolCall, isReadTool(tool) else { return nil }
        let title: String = {
            if let progress = tool.progress.first(where: { $0.lowercased().hasPrefix("read ") }) {
                let path = String(progress.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { return path }
            }
            let result = tool.result.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? tool.displayName : result
        }()
        return Operation(
            id: tool.itemID,
            title: title,
            detail: tool.copyText.traceNilIfBlank,
            status: tool.status.traceNilIfBlank ?? "done",
            isFailure: tool.error != nil,
            message: message
        )
    }

    private static func editOperation(from message: CodexChatMessage) -> Operation? {
        guard let change = message.fileChange else { return nil }
        return Operation(
            id: change.itemID,
            title: change.displayPath,
            detail: change.diff.traceNilIfBlank ?? change.output.traceNilIfBlank,
            status: change.status.traceNilIfBlank ?? "updated",
            isFailure: change.status.localizedCaseInsensitiveContains("fail"),
            message: message
        )
    }

    private static func toolOperation(from message: CodexChatMessage) -> Operation? {
        guard let tool = message.toolCall else { return nil }
        return Operation(
            id: tool.itemID,
            title: tool.displayName,
            detail: tool.copyText.traceNilIfBlank,
            status: tool.status.traceNilIfBlank ?? "done",
            isFailure: tool.error != nil,
            message: message
        )
    }

    private static func planOperation(from message: CodexChatMessage) -> Operation? {
        guard let plan = message.planUpdate else { return nil }
        return Operation(id: plan.itemID, title: "Plan", detail: plan.copyText.traceNilIfBlank, status: plan.summary, isFailure: false, message: message)
    }

    private static func noticeOperation(from message: CodexChatMessage) -> Operation? {
        guard let notice = message.notice else { return nil }
        return Operation(
            id: notice.itemID,
            title: notice.title,
            detail: notice.copyText.traceNilIfBlank,
            status: notice.statusLabel,
            isFailure: notice.severity == .danger,
            message: message
        )
    }

    private static func isReadTool(_ tool: CodexChatMessage.ToolCall) -> Bool {
        let name = tool.displayName.lowercased()
        return name.contains("read") || tool.progress.contains { $0.lowercased().hasPrefix("read ") }
    }

    private static func isCollabTool(_ tool: CodexChatMessage.ToolCall) -> Bool {
        let name = tool.displayName.lowercased()
        return name.contains("spawn") || name.contains("subagent") || name.contains("collab")
            || name.contains("close agent") || name == "wait"
    }

    public static func durationLabel(seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 {
            if remainder == 0 { return "\(minutes)m" }
            return "\(minutes)m \(remainder)s"
        }
        let hours = minutes / 60
        let remMin = minutes % 60
        if remainder == 0 {
            return remMin == 0 ? "\(hours)h" : "\(hours)h \(remMin)m"
        }
        return "\(hours)h \(remMin)m \(remainder)s"
    }
}

public extension CodexChatMessage {
    var isCompletedWorkTraceInput: Bool {
        switch role {
        case .terminal: return commandRun != nil
        case .fileChange: return fileChange != nil
        case .tool: return toolCall != nil
        case .plan: return planUpdate != nil
        case .reasoning: return reasoningBlock != nil
        case .notice: return notice != nil
        case .assistant, .user, .system: return false
        }
    }

    var isTurnFinalAssistant: Bool {
        role == .assistant && !isStreaming && detail == "final_answer"
    }
}

private extension String {
    var traceNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
