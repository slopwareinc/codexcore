import Foundation

public enum CodexWorkGroupHeaderV2 {
    public static func synthesize(rows: [CodexWorkRowV2]) -> String {
        var order: [CodexWorkCategoryV2] = []
        var counts: [CodexWorkCategoryV2: Int] = [:]
        for row in rows {
            let categories: [(CodexWorkCategoryV2, Int)]
            switch row {
            case .command(let value): categories = [(value.action, 1)]
            case .fileChange(let value): categories = [(.edit, max(1, value.files.count))]
            case .mcpToolCall(let value): categories = [(.mcp(value.appName), 1)]
            case .webSearch: categories = [(.webSearch, 1)]
            case .collabAgent(let value):
                switch value.action {
                case .created: categories = [(.collabCreated, max(1, value.agentNames.count))]
                case .closed: categories = [(.collabClosed, max(1, value.agentNames.count))]
                case .waited: categories = [(.collabWait, max(1, value.agentNames.count))]
                case .sentInput, .started, .interacted, .interrupted:
                    categories = [(.collabWorked, max(1, value.agentNames.count))]
                }
            case .other(let value):
                categories = value.label == "Generating an image" ? [(.imageGeneration, 1)] : []
            }
            for (category, count) in categories {
                if counts[category] == nil { order.append(category) }
                counts[category, default: 0] += count
            }
        }
        guard !order.isEmpty else { return "" }
        // The app treats read + search as one discovery phrase, even when run
        // commands arrived between them on the wire.
        if let read = order.firstIndex(of: .read), let search = order.firstIndex(of: .search), search > read + 1 {
            order.remove(at: search)
            order.insert(.search, at: read + 1)
        }
        let phrases = order.map { phrase($0, count: counts[$0, default: 0]) }
        var result = phrases[0].prefix(1).uppercased() + phrases[0].dropFirst()
        if phrases.count > 1 {
            for index in 1..<phrases.count {
                let previous = order[index - 1], current = order[index]
                let separator = (previous == .read && current == .search) ? " and " : ", "
                result += separator + phrases[index]
            }
        }
        return result
    }

    private static func phrase(_ category: CodexWorkCategoryV2, count: Int) -> String {
        switch category {
        case .read: count == 1 ? "read a file" : "read \(count) files"
        case .list: "listed files"
        case .search, .webSearch: "searched"
        case .run: count == 1 ? "ran a command" : "ran \(count) commands"
        case .edit: count == 1 ? "edited a file" : "edited \(count) files"
        case .mcp(let app): count == 1 ? "called \(app)" : "called \(app) \(count) times"
        case .collabCreated: count == 1 ? "created an agent" : "created \(count) agents"
        case .collabClosed: count == 1 ? "closed an agent" : "closed \(count) agents"
        case .collabWait: "working"
        case .collabWorked: count == 1 ? "worked with an agent" : "worked with \(count) agents"
        case .imageGeneration: count == 1 ? "generated an image" : "generated \(count) images"
        }
    }
}
