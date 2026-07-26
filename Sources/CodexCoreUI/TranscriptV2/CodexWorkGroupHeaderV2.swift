import Foundation

public enum CodexWorkGroupHeaderV2 {
    public static func synthesize(rows: [CodexWorkRowV2]) -> String {
        var order: [CodexWorkCategoryV2] = []
        var counts: [CodexWorkCategoryV2: Int] = [:]
        for row in rows {
            let categories: [(CodexWorkCategoryV2, Int)]
            switch row {
            case .command(let value):
                categories = [(
                    value.action,
                    value.action == .read ? max(1, value.targets.count) : 1
                )]
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
        let phrases = order.map {
            phrase($0, count: counts[$0, default: 0], rows: rows)
        }
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

    private static func phrase(
        _ category: CodexWorkCategoryV2,
        count: Int,
        rows: [CodexWorkRowV2]
    ) -> String {
        switch category {
        case .read:
            let targets = rows.compactMap { row -> [String]? in
                guard case .command(let command) = row, command.action == .read else { return nil }
                return command.targets
            }.flatMap { $0 }
            return count == 1 ? "read \(targets.first ?? "a file")" : "read \(count) files"
        case .list: return "listed files"
        case .search, .webSearch: return "searched"
        case .run: return count == 1 ? "ran a command" : "ran \(count) commands"
        case .edit: return count == 1 ? "edited a file" : "edited \(count) files"
        case .mcp(let app): return count == 1 ? "called \(app)" : "called \(app) \(count) times"
        case .collabCreated: return count == 1 ? "created an agent" : "created \(count) agents"
        case .collabClosed: return count == 1 ? "closed an agent" : "closed \(count) agents"
        case .collabWait: return "working"
        case .collabWorked: return count == 1 ? "worked with an agent" : "worked with \(count) agents"
        case .imageGeneration: return count == 1 ? "generated an image" : "generated \(count) images"
        }
    }
}

enum CodexWorkGroupPresentationV2 {
    static func header(_ group: CodexWorkGroupV2, rows: [CodexWorkRowV2]? = nil) -> String {
        let visibleRows = rows ?? group.rows
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
