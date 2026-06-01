import Foundation

// MARK: - Projected Timeline Row Descriptor

public enum CodexConversationTimelineItem: Identifiable, Sendable, Equatable {
    case item(CodexTimelineItem)
    case exploration(id: String, items: [CodexTimelineItem])

    public var id: String {
        switch self {
        case .item(let item): return item.id
        case .exploration(let id, _): return id
        }
    }

    public var isAssistantRow: Bool {
        switch self {
        case .item(let item):
            if case .assistantMessage = item { return true }
            return false
        case .exploration:
            return false
        }
    }
}

// MARK: - Live Detail Retention Policy

public enum CodexLiveDetailRetentionPolicy {
    /// Selectively retains rich detailed item IDs (only active + last completed)
    /// to save main thread layout memory when scrolling long conversations.
    public static func retainedRichDetailItemIDs(for items: [CodexTimelineItem]) -> Set<String> {
        var retained = Set<String>()

        // Retain the active streaming assistant message
        if let activeIdx = items.firstIndex(where: {
            if case .assistantMessage(_, _, _, let streaming) = $0 { return streaming }
            return false
        }) {
            retained.insert(items[activeIdx].id)
        }

        // Retain the latest completed item
        if let latestCompleted = items.reversed().first(where: {
            if case .assistantMessage(_, _, _, let streaming) = $0 { return !streaming }
            return true
        }) {
            retained.insert(latestCompleted.id)
        }

        return retained
    }
}

// MARK: - Codex Timeline Projection Engine

public enum CodexTimelineProjection {

    /// Projects a flat list of timeline items into a clean, merged conversation timeline.
    public static func project(
        _ items: [CodexTimelineItem],
        reasoningVisible: Bool = true,
        commandsVisible: Bool = true
    ) -> [CodexConversationTimelineItem] {
        var rows: [CodexConversationTimelineItem] = []
        var explorationBuffer: [CodexTimelineItem] = []

        func flushExplorationBuffer() {
            guard !explorationBuffer.isEmpty else { return }
            let seed = explorationBuffer.first?.id ?? UUID().uuidString
            rows.append(.exploration(id: "exploration-\(seed)", items: explorationBuffer))
            explorationBuffer.removeAll(keepingCapacity: true)
        }

        for item in items {
            if isExplorationItem(item) {
                if commandsVisible {
                    explorationBuffer.append(item)
                }
            } else {
                flushExplorationBuffer()

                // Check if reasoning should be hidden
                if case .reasoning = item, !reasoningVisible {
                    continue
                }

                rows.append(.item(item))
            }
        }

        flushExplorationBuffer()
        return rows
    }

    private static func isExplorationItem(_ item: CodexTimelineItem) -> Bool {
        switch item {
        case .commandExecution(let id, let cmd, _, _, _):
            // Check if it is a quiet setup or diagnostic command
            let lower = cmd.lowercased()
            return lower.hasPrefix("git status")
                || lower.hasPrefix("pwd")
                || lower.hasPrefix("echo")
                || lower.hasPrefix("which")
                || id.hasPrefix("expl-")
        default:
            return false
        }
    }
}
