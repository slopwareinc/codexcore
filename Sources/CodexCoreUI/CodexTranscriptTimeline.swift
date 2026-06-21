import Foundation

enum CodexTranscriptTimelineItem: Identifiable, Equatable {
    case message(CodexChatMessage)
    case assistantTurnHeader(id: String, assistantName: String)
    case assistantLifecycle(id: String, events: [CodexAgentLifecycleEvent])
    case assistantBlock(id: String, block: CodexBlock)
    case assistantStreamingWorking(id: String, text: String, isEmpty: Bool)
    case lifecycle(CodexAgentLifecycleEvent)

    var id: String {
        switch self {
        case .message(let message):
            return "message-\(message.id.uuidString)"
        case .assistantTurnHeader(let id, _):
            return "asst-hdr-\(id)"
        case .assistantLifecycle(let id, _):
            return "asst-life-\(id)"
        case .assistantBlock(let id, _):
            return "asst-blk-\(id)"
        case .assistantStreamingWorking(let id, _, _):
            return "asst-work-\(id)"
        case .lifecycle(let event):
            return "lifecycle-\(event.id.uuidString)"
        }
    }

    var createdAt: Date {
        switch self {
        case .message(let message):
            return message.createdAt
        case .lifecycle(let event):
            return event.createdAt
        default:
            return Date()
        }
    }
}

enum CodexTranscriptTimelineBuilder {
    static let maxGroupedAssistantMessages = 1
    static let maxGroupedLifecycleEvents = 12

    static func build(
        messages: [CodexChatMessage],
        lifecycleEvents: [CodexAgentLifecycleEvent]
    ) -> [CodexTranscriptTimelineItem] {
        compactAssistantTurns(
            (messages.map(CodexTranscriptTimelineItem.message) + lifecycleEvents.map(CodexTranscriptTimelineItem.lifecycle))
                .sorted { lhs, rhs in lhs.createdAt < rhs.createdAt }
        )
    }

    private static func compactAssistantTurns(_ items: [CodexTranscriptTimelineItem]) -> [CodexTranscriptTimelineItem] {
        var compacted: [CodexTranscriptTimelineItem] = []
        var pendingAssistantMessages: [CodexChatMessage] = []
        var pendingLifecycleEvents: [CodexAgentLifecycleEvent] = []

        func flushPending() {
            guard !pendingAssistantMessages.isEmpty || !pendingLifecycleEvents.isEmpty else { return }
            
            let primaryMessage = pendingAssistantMessages.last(where: { $0.detail == "final_answer" }) ?? pendingAssistantMessages.last
            let primaryID = primaryMessage?.id.uuidString ?? UUID().uuidString
            
            // Header
            compacted.append(.assistantTurnHeader(id: primaryID, assistantName: "Codex"))
            
            // Streamed messages (prior to primary)
            let streamMessages = pendingAssistantMessages.filter { $0.id != primaryMessage?.id }
            for msg in streamMessages {
                if msg.isStreaming {
                    compacted.append(.assistantStreamingWorking(id: msg.id.uuidString, text: msg.text, isEmpty: msg.text.isEmpty))
                } else {
                    let blocks = msg.projectedBlocks ?? CodexBlockProjector.project(msg.text, streaming: false, cacheNamespace: msg.id.uuidString)
                    for block in blocks {
                        compacted.append(.assistantBlock(id: block.id, block: block))
                    }
                }
            }
            
            // Lifecycle events
            if !pendingLifecycleEvents.isEmpty {
                compacted.append(.assistantLifecycle(id: primaryID, events: pendingLifecycleEvents))
            }
            
            // Primary message
            if let msg = primaryMessage {
                if msg.isStreaming {
                    compacted.append(.assistantStreamingWorking(id: msg.id.uuidString, text: msg.text, isEmpty: msg.text.isEmpty))
                } else {
                    let blocks = msg.projectedBlocks ?? CodexBlockProjector.project(msg.text, streaming: false, cacheNamespace: msg.id.uuidString)
                    for block in blocks {
                        compacted.append(.assistantBlock(id: block.id, block: block))
                    }
                }
            }
            
            pendingAssistantMessages = []
            pendingLifecycleEvents = []
        }

        for item in items {
            switch item {
            case .message(let message) where message.role == .assistant:
                if pendingAssistantMessages.count >= maxGroupedAssistantMessages {
                    flushPending()
                }
                pendingAssistantMessages.append(message)

            case .lifecycle(let event):
                if pendingLifecycleEvents.count >= maxGroupedLifecycleEvents {
                    flushPending()
                }
                pendingLifecycleEvents.append(event)

            default:
                flushPending()
                compacted.append(item)
            }
        }

        flushPending()
        return compacted
    }
}
