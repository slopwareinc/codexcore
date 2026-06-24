import Foundation

public struct CodexLiveTurnPhaseState: Equatable, Sendable {
    public var statusTitle: String
    public var thinkingTitle: String
    public var elapsedLabel: String
    public var stopTitle: String?
    public var stopShortcut: String?

    public init(
        statusTitle: String,
        thinkingTitle: String,
        elapsedLabel: String,
        stopTitle: String?,
        stopShortcut: String?
    ) {
        self.statusTitle = statusTitle
        self.thinkingTitle = thinkingTitle
        self.elapsedLabel = elapsedLabel
        self.stopTitle = stopTitle
        self.stopShortcut = stopShortcut
    }
}

public struct CodexLiveTurnOperationRow: Identifiable, Equatable, Sendable {
    public var id: String { title }
    public var title: String

    public init(title: String) {
        self.title = title
    }
}

public struct CodexLiveTurnChangeFileRow: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var addedLineCount: Int
    public var removedLineCount: Int

    public init(path: String, addedLineCount: Int, removedLineCount: Int) {
        self.path = path
        self.addedLineCount = addedLineCount
        self.removedLineCount = removedLineCount
    }

    public var displayTitle: String {
        "\(path) +\(addedLineCount) -\(removedLineCount)"
    }
}

public struct CodexLiveTurnChangeCardSummary: Equatable, Sendable {
    public var primaryPath: String?
    public var primaryType: String?
    public var title: String
    public var addedLabel: String
    public var removedLabel: String
    public var actionTitles: [String]
    public var visibleFileRows: [CodexLiveTurnChangeFileRow]
    public var hiddenRowsTitle: String?

    public init(
        primaryPath: String?,
        primaryType: String?,
        title: String,
        addedLabel: String,
        removedLabel: String,
        actionTitles: [String],
        visibleFileRows: [CodexLiveTurnChangeFileRow],
        hiddenRowsTitle: String?
    ) {
        self.primaryPath = primaryPath
        self.primaryType = primaryType
        self.title = title
        self.addedLabel = addedLabel
        self.removedLabel = removedLabel
        self.actionTitles = actionTitles
        self.visibleFileRows = visibleFileRows
        self.hiddenRowsTitle = hiddenRowsTitle
    }
}

public enum CodexLiveTurnModel {
    public static let responseActionTitles = ["Copy", "Good response", "Bad response", "Fork from this point"]

    public static func phaseState(
        isActive: Bool,
        startedAt: Date,
        endedAt: Date? = nil,
        now: Date = Date()
    ) -> CodexLiveTurnPhaseState {
        let end = isActive ? now : (endedAt ?? now)
        let elapsed = max(0, Int(end.timeIntervalSince(startedAt).rounded()))
        let verb = isActive ? "Working" : "Worked"
        return CodexLiveTurnPhaseState(
            statusTitle: verb,
            thinkingTitle: "Thinking",
            elapsedLabel: "\(verb) for \(durationLabel(seconds: elapsed))",
            stopTitle: isActive ? "Stop" : nil,
            stopShortcut: isActive ? "Esc" : nil
        )
    }

    public static func phaseState(
        for activeTurn: CodexActiveTurnState,
        now: Date = Date()
    ) -> CodexLiveTurnPhaseState {
        phaseState(isActive: true, startedAt: activeTurn.startedAt, now: now)
    }

    public static func responseActionTitles(for message: CodexChatMessage) -> [String] {
        guard message.role == .assistant, !message.isStreaming else { return [] }
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return responseActionTitles
    }

    public static func operationRows(for messages: [CodexChatMessage]) -> [CodexLiveTurnOperationRow] {
        var rows: [CodexLiveTurnOperationRow] = []
        var commandGroup: [CodexChatMessage.CommandRun] = []
        var readCount = 0
        var fileChangeGroup: [CodexChatMessage.FileChange] = []

        func flushCommands() {
            guard !commandGroup.isEmpty else { return }
            if commandGroup.count > 1, !commandGroup.contains(where: isListCommand) {
                rows.append(contentsOf: commandGroup.map { CodexLiveTurnOperationRow(title: commandTitle($0)) })
            } else {
                rows.append(CodexLiveTurnOperationRow(title: commandGroupTitle(commandGroup)))
            }
            commandGroup = []
        }

        func flushReads() {
            guard readCount > 0 else { return }
            rows.append(CodexLiveTurnOperationRow(title: "Read \(readCount) \(readCount == 1 ? "file" : "files")"))
            readCount = 0
        }

        func flushFileChanges() {
            guard !fileChangeGroup.isEmpty else { return }
            rows.append(CodexLiveTurnOperationRow(title: fileChangeGroupTitle(fileChangeGroup)))
            fileChangeGroup = []
        }

        for message in messages {
            if let command = message.commandRun {
                flushReads()
                flushFileChanges()
                commandGroup.append(command)
            } else if let tool = message.toolCall, isReadTool(tool) {
                flushCommands()
                flushFileChanges()
                readCount += max(1, readFileCount(in: tool))
            } else if let fileChange = message.fileChange {
                flushCommands()
                flushReads()
                fileChangeGroup.append(fileChange)
            } else {
                flushCommands()
                flushReads()
                flushFileChanges()
            }
        }

        flushCommands()
        flushReads()
        flushFileChanges()
        return rows
    }

    public static func finalAssistantSummary(in messages: [CodexChatMessage]) -> String? {
        messages.last { message in
            message.role == .assistant && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text
    }

    public static func changeCardSummary(
        for changes: [CodexChatMessage.FileChange],
        visibleRowLimit: Int = 3
    ) -> CodexLiveTurnChangeCardSummary? {
        let rows = changes.compactMap(fileRow)
        guard !rows.isEmpty else { return nil }

        let added = rows.reduce(0) { $0 + $1.addedLineCount }
        let removed = rows.reduce(0) { $0 + $1.removedLineCount }
        let hiddenCount = max(0, rows.count - visibleRowLimit)
        let primaryPath = rows.first?.path

        return CodexLiveTurnChangeCardSummary(
            primaryPath: primaryPath,
            primaryType: primaryPath.map(fileTypeLabel),
            title: "Edited \(rows.count) \(rows.count == 1 ? "file" : "files")",
            addedLabel: "+\(added)",
            removedLabel: "-\(removed)",
            actionTitles: ["Undo", "Review"],
            visibleFileRows: Array(rows.prefix(max(0, visibleRowLimit))),
            hiddenRowsTitle: hiddenCount > 0 ? "Show \(hiddenCount) more \(hiddenCount == 1 ? "file" : "files")" : nil
        )
    }

    private static func commandGroupTitle(_ commands: [CodexChatMessage.CommandRun]) -> String {
        if commands.count == 1, let command = commands.first {
            return commandTitle(command)
        }

        let listedCount = commands.filter(isListCommand).count
        let otherCount = commands.count - listedCount
        var parts: [String] = []
        if listedCount > 0 {
            parts.append(listedCount == 1 ? "Listed files" : "Listed files \(listedCount) times")
        }
        if otherCount > 0 {
            parts.append("ran \(otherCount) \(otherCount == 1 ? "command" : "commands")")
        }
        return parts.joined(separator: ", ")
    }

    private static func commandTitle(_ command: CodexChatMessage.CommandRun) -> String {
        if isListCommand(command) { return "Listed files" }
        var title = "Ran \(command.command)"
        let duration = command.outputDurationLabel ?? command.statusDurationLabel
        if let duration {
            title += " for \(duration)"
        }
        return title
    }

    private static func isListCommand(_ command: CodexChatMessage.CommandRun) -> Bool {
        let normalized = command.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == "ls" || normalized.hasPrefix("ls ")
    }

    private static func isReadTool(_ tool: CodexChatMessage.ToolCall) -> Bool {
        let name = tool.displayName.lowercased()
        return name.contains("read") || tool.progress.contains { $0.lowercased().hasPrefix("read ") }
    }

    private static func readFileCount(in tool: CodexChatMessage.ToolCall) -> Int {
        let count = tool.progress.filter { $0.lowercased().hasPrefix("read ") }.count
        return count == 0 ? 1 : count
    }

    private static func fileChangeGroupTitle(_ changes: [CodexChatMessage.FileChange]) -> String {
        let created = changes.filter(isCreatedFileChange).count
        let edited = changes.count - created
        var parts: [String] = []
        if created > 0 {
            parts.append("Created \(created == 1 ? "a file" : "\(created) files")")
        }
        if edited > 0 {
            parts.append("edited \(edited) \(edited == 1 ? "file" : "files")")
        }
        guard let first = parts.first else { return "Edited files" }
        return ([first.prefix(1).uppercased() + String(first.dropFirst())] + parts.dropFirst()).joined(separator: ", ")
    }

    private static func isCreatedFileChange(_ change: CodexChatMessage.FileChange) -> Bool {
        let kind = change.kind.lowercased()
        return kind == "add" || kind == "create" || kind == "created"
    }

    private static func fileRow(_ change: CodexChatMessage.FileChange) -> CodexLiveTurnChangeFileRow? {
        guard let path = change.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return CodexLiveTurnChangeFileRow(
            path: path,
            addedLineCount: change.addedLineCount,
            removedLineCount: change.removedLineCount
        )
    }

    private static func fileTypeLabel(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "md":
            return "Document · MD"
        case "json":
            return "JSON"
        case "js":
            return "JavaScript"
        case "sh":
            return "Shell"
        default:
            return "File"
        }
    }

    private static func durationLabel(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 { return "\(minutes)m" }
        return "\(minutes)m \(remainder)s"
    }
}

private extension CodexChatMessage.CommandRun {
    var outputDurationLabel: String? {
        let marker = "duration="
        guard let range = output.range(of: marker) else { return nil }
        return output[range.upperBound...]
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
    }

    var statusDurationLabel: String? {
        let marker = "duration="
        guard let range = status.range(of: marker) else { return nil }
        return status[range.upperBound...]
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
    }
}
