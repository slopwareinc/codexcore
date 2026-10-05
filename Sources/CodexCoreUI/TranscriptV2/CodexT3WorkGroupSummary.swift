import Foundation

/// Native adaptation of T3 Code's `work-log/presentation.ts` summary grammar.
/// Action counts describe canonical work; rendering never reparses shell text.
enum CodexT3WorkGroupSummary {
    private enum Action: Hashable {
        case read, edit, command, search, webSearch, tool, createAgent, closeAgent, messageAgent, update

        var priority: Int {
            switch self {
            case .edit, .command, .createAgent, .closeAgent, .messageAgent: 0
            case .read, .search, .webSearch: 1
            case .tool, .update: 2
            }
        }

        func label(_ count: Int) -> String {
            switch self {
            case .read: "Read \(count) \(count == 1 ? "file" : "files")"
            case .edit: "Changed \(count) \(count == 1 ? "file" : "files")"
            case .command: "Ran \(count) \(count == 1 ? "command" : "commands")"
            case .search: "Searched code \(count) \(count == 1 ? "time" : "times")"
            case .webSearch: "Searched the web \(count) \(count == 1 ? "time" : "times")"
            case .tool: "Used \(count) \(count == 1 ? "tool" : "tools")"
            case .createAgent: "Created \(count) \(count == 1 ? "agent" : "agents")"
            case .closeAgent: "Closed \(count) \(count == 1 ? "agent" : "agents")"
            case .messageAgent: "Worked with \(count) \(count == 1 ? "agent" : "agents")"
            case .update: "Received \(count) \(count == 1 ? "update" : "updates")"
            }
        }
    }

    private struct Group {
        var action: Action
        var firstIndex: Int
        var calls = 0
        var count = 0
        var changedPaths: Set<String> = []

        var label: String { action.label(count + changedPaths.count) }
    }

    static func synthesize(rows: [CodexWorkRowV2]) -> String {
        var groups: [Group] = []
        var sources: [String] = []
        var sourcedCalls = 0
        for (index, row) in rows.enumerated() {
            if case .mcpToolCall(let call) = row {
                let source = call.presentation?.sourceName ?? (call.appName.isEmpty ? call.server : call.appName)
                if !sources.contains(source) { sources.append(source) }
                sourcedCalls += 1
                continue
            }
            if case .command(let command) = row, case .mcp(let source) = command.action {
                if !sources.contains(source) { sources.append(source) }
                sourcedCalls += 1
                continue
            }
            let action = action(for: row)
            let groupIndex: Int
            if let existing = groups.firstIndex(where: { $0.action == action }) {
                groupIndex = existing
            } else {
                groupIndex = groups.count
                groups.append(Group(action: action, firstIndex: index))
            }
            groups[groupIndex].calls += 1
            if case .fileChange(let change) = row {
                let paths = change.changes.isEmpty ? change.files : change.changes.map(\.displayPath)
                if paths.isEmpty { groups[groupIndex].count += 1 }
                else { groups[groupIndex].changedPaths.formUnion(paths) }
            } else {
                groups[groupIndex].count += 1
            }
        }
        // Select the most meaningful two categories, then restore their arrival
        // order. Omitted categories remain represented by their number of calls.
        let selected = groups.sorted {
            $0.action.priority == $1.action.priority
                ? $0.firstIndex < $1.firstIndex
                : $0.action.priority < $1.action.priority
        }.prefix(2).sorted { $0.firstIndex < $1.firstIndex }
        var labels = selected.map(\.label)
        if !sources.isEmpty {
            labels.insert("Used \(sentence(sources)) \(sources.count == 1 ? "integration" : "integrations")", at: 0)
        }
        let remainder = rows.count - sourcedCalls - selected.reduce(0) { $0 + $1.calls }
        if remainder > 0 {
            labels.append("Performed \(remainder) other \(remainder == 1 ? "action" : "actions")")
        }
        return sentence(labels.enumerated().map { index, label in
            index == 0 ? label : label.prefix(1).lowercased() + label.dropFirst()
        })
    }

    private static func sentence(_ labels: [String]) -> String {
        switch labels.count {
        case 0: ""
        case 1: labels[0]
        case 2: labels.joined(separator: " and ")
        default: labels.dropLast().joined(separator: ", ") + ", and " + labels[labels.count - 1]
        }
    }

    private static func action(for row: CodexWorkRowV2) -> Action {
        switch row {
        case .command(let value):
            switch value.action {
            case .read, .list: .read
            case .search: .search
            case .edit: .edit
            case .run: .command
            case .webSearch: .webSearch
            case .collabCreated: .createAgent
            case .collabClosed: .closeAgent
            case .collabWorked: .messageAgent
            case .collabWait: .update
            case .loadedTool, .mcp, .imageGeneration: .tool
            }
        case .fileChange: .edit
        case .webSearch: .webSearch
        case .mcpToolCall: .tool
        case .collabAgent(let value):
            switch value.action {
            case .created, .started: .createAgent
            case .closed, .interrupted: .closeAgent
            case .sentInput, .interacted: .messageAgent
            case .waited: .update
            }
        case .other: .tool
        }
    }
}
