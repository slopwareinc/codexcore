import Foundation

public enum CodexWorkGroupHeaderV2 {
    public static func synthesize(rows: [CodexWorkRowV2]) -> String {
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
                counts[category, default: 0] += count
            }
        }

        var phrases: [String] = []

        // Official completed summaries use a fixed semantic order rather than
        // event arrival order. Named sources lead, followed by loaded tools,
        // edits, exploration, commands, and web search.
        let mcpApps = rows.compactMap { row -> String? in
            guard case .mcpToolCall(let value) = row else { return nil }
            return value.appName.isEmpty ? value.server : value.appName
        }
        .reduce(into: [String]()) { result, app in
            if !result.contains(app) { result.append(app) }
        }
        if !mcpApps.isEmpty {
            phrases.append("used \(mcpApps.joined(separator: " and "))")
        }

        appendPhrase(.loadedTool, counts: counts, to: &phrases)
        appendPhrase(.edit, counts: counts, to: &phrases)

        let explorationCount = counts[.read, default: 0]
            + counts[.search, default: 0]
            + counts[.list, default: 0]
        if explorationCount > 0 {
            phrases.append("read files")
        }

        appendPhrase(.run, counts: counts, to: &phrases)
        appendPhrase(.webSearch, counts: counts, to: &phrases)
        appendPhrase(.collabCreated, counts: counts, to: &phrases)
        appendPhrase(.collabClosed, counts: counts, to: &phrases)
        appendPhrase(.collabWait, counts: counts, to: &phrases)
        appendPhrase(.collabWorked, counts: counts, to: &phrases)
        appendPhrase(.imageGeneration, counts: counts, to: &phrases)

        guard let first = phrases.first else { return "" }
        return (first.prefix(1).uppercased() + first.dropFirst())
            + phrases.dropFirst().map { ", \($0)" }.joined()
    }

    private static func appendPhrase(
        _ category: CodexWorkCategoryV2,
        counts: [CodexWorkCategoryV2: Int],
        to phrases: inout [String]
    ) {
        let count = counts[category, default: 0]
        if count > 0 {
            phrases.append(phrase(category, count: count))
        }
    }

    private static func phrase(
        _ category: CodexWorkCategoryV2,
        count: Int
    ) -> String {
        switch category {
        case .loadedTool: return count == 1 ? "loaded a tool" : "loaded tools"
        case .run: return count == 1 ? "ran a command" : "ran commands"
        case .edit: return count == 1 ? "edited a file" : "edited files"
        case .webSearch: return "searched the web"
        case .collabCreated: return count == 1 ? "created an agent" : "created \(count) agents"
        case .collabClosed: return count == 1 ? "closed an agent" : "closed \(count) agents"
        case .collabWait: return "working"
        case .collabWorked: return count == 1 ? "worked with an agent" : "worked with \(count) agents"
        case .imageGeneration: return count == 1 ? "generated an image" : "generated \(count) images"
        case .read, .list, .search: return "read files"
        case .mcp(let app): return "used \(app)"
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
