import Foundation

public enum CodexWorkGroupHeaderV2 {
    public static func synthesize(rows: [CodexWorkRowV2]) -> String {
        let summary = Summary(rows: rows)
        var phrases: [String] = []

        // Official completed summaries use a fixed semantic order rather than
        // event arrival order. Named sources lead, followed by loaded tools,
        // edits, exploration, commands, and web search.
        append(summary.mcpApps.isEmpty ? nil : "used \(summary.mcpApps.joined(separator: " and "))", to: &phrases)
        append(counted(summary.loadedTools, singular: "loaded a tool", plural: "loaded tools"), to: &phrases)
        append(counted(summary.editedFiles, singular: "edited a file", plural: "edited files"), to: &phrases)
        append(summary.exploration > 0 ? "read files" : nil, to: &phrases)
        append(counted(summary.commands, singular: "ran a command", plural: "ran commands"), to: &phrases)
        append(summary.webSearches > 0 ? "searched the web" : nil, to: &phrases)
        append(counted(summary.createdAgents, singular: "created an agent", plural: "created \(summary.createdAgents) agents"), to: &phrases)
        append(counted(summary.closedAgents, singular: "closed an agent", plural: "closed \(summary.closedAgents) agents"), to: &phrases)
        append(summary.waits > 0 ? "working" : nil, to: &phrases)
        append(counted(summary.workedAgents, singular: "worked with an agent", plural: "worked with \(summary.workedAgents) agents"), to: &phrases)
        append(counted(summary.generatedImages, singular: "generated an image", plural: "generated \(summary.generatedImages) images"), to: &phrases)

        guard let first = phrases.first else { return "" }
        return (first.prefix(1).uppercased() + first.dropFirst())
            + phrases.dropFirst().map { ", \($0)" }.joined()
    }

    private static func append(_ phrase: String?, to phrases: inout [String]) {
        if let phrase { phrases.append(phrase) }
    }

    private static func counted(_ count: Int, singular: String, plural: String) -> String? {
        count == 0 ? nil : (count == 1 ? singular : plural)
    }

    private struct Summary {
        var mcpApps: [String] = []
        var loadedTools = 0
        var editedFiles = 0
        var exploration = 0
        var commands = 0
        var webSearches = 0
        var createdAgents = 0
        var closedAgents = 0
        var waits = 0
        var workedAgents = 0
        var generatedImages = 0

        init(rows: [CodexWorkRowV2]) {
            for row in rows { add(row) }
        }

        mutating func add(_ row: CodexWorkRowV2) {
            switch row {
            case .command(let value):
                switch value.action {
                case .loadedTool: loadedTools += 1
                case .read, .list, .search: exploration += 1
                case .run: commands += 1
                case .webSearch: webSearches += 1
                case .edit: editedFiles += 1
                case .mcp(let app): appendUnique(app, to: &mcpApps)
                case .collabCreated: createdAgents += 1
                case .collabClosed: closedAgents += 1
                case .collabWait: waits += 1
                case .collabWorked: workedAgents += 1
                case .imageGeneration: generatedImages += 1
                }
            case .fileChange(let value):
                editedFiles += max(1, value.files.count)
            case .mcpToolCall(let value):
                appendUnique(value.appName.isEmpty ? value.server : value.appName, to: &mcpApps)
            case .webSearch:
                webSearches += 1
            case .collabAgent(let value):
                let count = max(1, value.agentNames.count)
                switch value.action {
                case .created: createdAgents += count
                case .closed: closedAgents += count
                case .waited: waits += count
                case .sentInput, .started, .interacted, .interrupted: workedAgents += count
                }
            case .other(let value):
                if value.label == "Generating an image" { generatedImages += 1 }
            }
        }

        private func appendUnique(_ value: String, to values: inout [String]) {
            if !values.contains(value) { values.append(value) }
        }
    }
}

enum CodexWorkGroupPresentationV2 {
    static func header(_ group: CodexWorkGroupV2, rows: [CodexWorkRowV2]? = nil) -> String {
        let visibleRows = rows ?? group.rows
        if group.isLive,
           let active = visibleRows.last(where: \.isInProgress) {
            return activeLabel(active)
        }
        if rows == nil, !group.header.isEmpty { return group.header }
        return CodexWorkGroupHeaderV2.synthesize(rows: visibleRows)
    }

    static func status(
        rows: [CodexWorkRowV2],
        isLive: Bool
    ) -> CodexWorkItemStatusV2 {
        if rows.contains(where: isFailed) { return .failed }
        if isLive || rows.contains(where: \.isInProgress) { return .inProgress }
        return .completed
    }

    static func systemImage(rows: [CodexWorkRowV2]) -> String {
        if rows.contains(where: isFileChange) { return "pencil" }
        if rows.contains(where: isMCPCall) { return "app.connected.to.app.below.fill" }
        if rows.contains(where: isCollaboration) { return "person.2" }
        if rows.contains(where: isDiscovery) { return "doc.text.magnifyingglass" }
        if rows.contains(where: isImageGeneration) { return "photo.badge.plus" }
        return "terminal"
    }

    private static func activeLabel(_ row: CodexWorkRowV2) -> String {
        switch row {
        case .command(let value):
            return value.label
        case .fileChange:
            return "Editing files"
        case .mcpToolCall(let value):
            let app = value.appName.isEmpty ? value.server : value.appName
            return "Using \(app)"
        case .webSearch:
            return "Searching the web"
        case .collabAgent(let value):
            switch value.action {
            case .created, .started: return "Creating an agent"
            case .sentInput, .interacted: return "Messaging an agent"
            case .waited: return "Waiting for agents"
            case .closed: return "Closing agents"
            case .interrupted: return "Interrupting an agent"
            }
        case .other(let value):
            return value.label
        }
    }

    private static func isFailed(_ row: CodexWorkRowV2) -> Bool {
        switch row {
        case .command(let value): value.status == .failed
        case .fileChange(let value): value.status == .failed
        case .mcpToolCall(let value): value.status == .failed
        case .webSearch(let value): value.status == .failed
        case .collabAgent(let value): value.status == .failed
        case .other(let value): value.status == .failed
        }
    }

    private static func isFileChange(_ row: CodexWorkRowV2) -> Bool {
        if case .fileChange = row { true } else { false }
    }

    private static func isMCPCall(_ row: CodexWorkRowV2) -> Bool {
        if case .mcpToolCall = row { true } else { false }
    }

    private static func isCollaboration(_ row: CodexWorkRowV2) -> Bool {
        if case .collabAgent = row { true } else { false }
    }

    private static func isDiscovery(_ row: CodexWorkRowV2) -> Bool {
        switch row {
        case .command(let value):
            value.action == .read || value.action == .list || value.action == .search
        case .webSearch:
            true
        default:
            false
        }
    }

    private static func isImageGeneration(_ row: CodexWorkRowV2) -> Bool {
        guard case .other(let value) = row else { return false }
        return value.label == "Generating an image"
    }
}
