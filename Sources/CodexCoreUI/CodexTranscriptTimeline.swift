import Foundation

struct CodexTranscriptTimelineItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case messageRef(UUID)
        case completedWorkTrace(CodexCompletedWorkTrace)
        case operationAggregate([CodexLiveTurnOperationRow])
        case fileChangeAggregate([CodexChatMessage.FileChange])
        case assistantLifecycle([CodexAgentLifecycleEvent])
        case assistantBlock(CodexBlock)
        case assistantStreamingWorking(text: String, isEmpty: Bool)
        case lifecycle(CodexAgentLifecycleEvent)
    }

    let id: String
    let kind: Kind

    var messageID: UUID? {
        guard case .messageRef(let messageID) = kind else { return nil }
        return messageID
    }

    func streamingContentLength(in lookup: [UUID: CodexChatMessage]) -> Int {
        switch kind {
        case .messageRef(let messageID):
            guard let message = lookup[messageID], message.isStreaming else { return 0 }
            return message.text.count
        case .assistantStreamingWorking(let text, _):
            return text.count
        default:
            return 0
        }
    }
}

private enum CodexTranscriptTimelineBuildItem: Equatable {
    case message(CodexChatMessage)
    case completedWorkTrace(id: String, trace: CodexCompletedWorkTrace)
    case operationAggregate(id: String, rows: [CodexLiveTurnOperationRow])
    case fileChangeAggregate(id: String, changes: [CodexChatMessage.FileChange])
    case assistantLifecycle(id: String, events: [CodexAgentLifecycleEvent])
    case assistantBlock(id: String, block: CodexBlock)
    case assistantStreamingWorking(id: String, text: String, isEmpty: Bool)
    case lifecycle(CodexAgentLifecycleEvent)

    var materialized: CodexTranscriptTimelineItem {
        switch self {
        case .message(let message):
            return CodexTranscriptTimelineItem(
                id: "message-\(message.id.uuidString)",
                kind: .messageRef(message.id)
            )
        case .completedWorkTrace(let id, let trace):
            return CodexTranscriptTimelineItem(
                id: "work-trace-\(id)",
                kind: .completedWorkTrace(trace)
            )
        case .operationAggregate(let id, let rows):
            return CodexTranscriptTimelineItem(
                id: "op-agg-\(id)",
                kind: .operationAggregate(rows)
            )
        case .fileChangeAggregate(let id, let changes):
            return CodexTranscriptTimelineItem(
                id: "file-agg-\(id)",
                kind: .fileChangeAggregate(changes)
            )
        case .assistantLifecycle(let id, let events):
            return CodexTranscriptTimelineItem(
                id: "asst-life-\(id)",
                kind: .assistantLifecycle(events)
            )
        case .assistantBlock(let id, let block):
            return CodexTranscriptTimelineItem(
                id: "asst-blk-\(id)",
                kind: .assistantBlock(block)
            )
        case .assistantStreamingWorking(let id, let text, let isEmpty):
            return CodexTranscriptTimelineItem(
                id: "asst-work-\(id)",
                kind: .assistantStreamingWorking(text: text, isEmpty: isEmpty)
            )
        case .lifecycle(let event):
            return CodexTranscriptTimelineItem(
                id: "lifecycle-\(event.id.uuidString)",
                kind: .lifecycle(event)
            )
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
            mergedChronologically(messages: messages, lifecycleEvents: lifecycleEvents)
                .insertingCompletedWorkTraces()
        )
        .insertingOperationAggregateRows()
        .insertingAggregateFileChangeCards()
        .map(\.materialized)
    }

    private static func mergedChronologically(
        messages: [CodexChatMessage],
        lifecycleEvents: [CodexAgentLifecycleEvent]
    ) -> [CodexTranscriptTimelineBuildItem] {
        let messages = chronologicallySorted(messages, by: \.createdAt)
        let lifecycleEvents = chronologicallySorted(lifecycleEvents, by: \.createdAt)

        guard !messages.isEmpty else {
            return lifecycleEvents.map(CodexTranscriptTimelineBuildItem.lifecycle)
        }
        guard !lifecycleEvents.isEmpty else {
            return messages.map(CodexTranscriptTimelineBuildItem.message)
        }

        var merged: [CodexTranscriptTimelineBuildItem] = []
        merged.reserveCapacity(messages.count + lifecycleEvents.count)

        var messageIndex = messages.startIndex
        var eventIndex = lifecycleEvents.startIndex

        while messageIndex < messages.endIndex, eventIndex < lifecycleEvents.endIndex {
            let message = messages[messageIndex]
            let event = lifecycleEvents[eventIndex]
            if message.createdAt <= event.createdAt {
                merged.append(.message(message))
                messageIndex = messages.index(after: messageIndex)
            } else {
                merged.append(.lifecycle(event))
                eventIndex = lifecycleEvents.index(after: eventIndex)
            }
        }

        if messageIndex < messages.endIndex {
            merged.append(contentsOf: messages[messageIndex...].map(CodexTranscriptTimelineBuildItem.message))
        }
        if eventIndex < lifecycleEvents.endIndex {
            merged.append(contentsOf: lifecycleEvents[eventIndex...].map(CodexTranscriptTimelineBuildItem.lifecycle))
        }

        return merged
    }

    private static func chronologicallySorted<Value>(
        _ values: [Value],
        by createdAt: (Value) -> Date
    ) -> [Value] {
        guard values.count > 1 else { return values }

        var previousDate = createdAt(values[0])
        for value in values.dropFirst() {
            let currentDate = createdAt(value)
            if previousDate > currentDate {
                return values.enumerated()
                    .sorted { lhs, rhs in
                        let lhsDate = createdAt(lhs.element)
                        let rhsDate = createdAt(rhs.element)
                        if lhsDate == rhsDate {
                            return lhs.offset < rhs.offset
                        }
                        return lhsDate < rhsDate
                    }
                    .map { $0.element }
            }
            previousDate = currentDate
        }

        return values
    }

    private static func compactAssistantTurns(_ items: [CodexTranscriptTimelineBuildItem]) -> [CodexTranscriptTimelineBuildItem] {
        var compacted: [CodexTranscriptTimelineBuildItem] = []
        var pendingAssistantMessages: [CodexChatMessage] = []
        var pendingLifecycleEvents: [CodexAgentLifecycleEvent] = []

        func flushPending() {
            guard !pendingAssistantMessages.isEmpty || !pendingLifecycleEvents.isEmpty else { return }

            let primaryMessage = pendingAssistantMessages.last(where: { $0.detail == "final_answer" }) ?? pendingAssistantMessages.last
            let primaryID = primaryMessage?.id.uuidString
                ?? pendingLifecycleEvents.first?.id.uuidString
                ?? "assistant-turn"

            let streamMessages = pendingAssistantMessages.filter { $0.id != primaryMessage?.id }
            for msg in streamMessages {
                if msg.isStreaming {
                    compacted.append(.assistantStreamingWorking(id: msg.id.uuidString, text: msg.text, isEmpty: msg.text.isEmpty))
                } else {
                    compacted.append(.message(msg))
                }
            }

            if !pendingLifecycleEvents.isEmpty {
                compacted.append(.assistantLifecycle(id: primaryID, events: pendingLifecycleEvents))
            }

            if let msg = primaryMessage {
                if msg.isStreaming {
                    compacted.append(.assistantStreamingWorking(id: msg.id.uuidString, text: msg.text, isEmpty: msg.text.isEmpty))
                } else {
                    compacted.append(.message(msg))
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

private extension Array where Element == CodexTranscriptTimelineBuildItem {
    func insertingCompletedWorkTraces() -> [CodexTranscriptTimelineBuildItem] {
        var result: [CodexTranscriptTimelineBuildItem] = []
        var pendingWorkMessages: [CodexChatMessage] = []

        func flushPendingWork() {
            guard !pendingWorkMessages.isEmpty else { return }
            result.append(contentsOf: pendingWorkMessages.map(CodexTranscriptTimelineBuildItem.message))
            pendingWorkMessages = []
        }

        func appendTrace(before assistantMessage: CodexChatMessage) -> Bool {
            guard !pendingWorkMessages.isEmpty,
                  let trace = CodexCompletedWorkTrace.project(from: pendingWorkMessages + [assistantMessage]) else {
                return false
            }
            result.append(.completedWorkTrace(id: trace.id, trace: trace))
            pendingWorkMessages = []
            return true
        }

        for item in self {
            switch item {
            case .message(let message) where message.isCompletedWorkTraceInput:
                pendingWorkMessages.append(message)

            case .message(let message) where message.role == .assistant && !message.isStreaming:
                _ = appendTrace(before: message)
                result.append(item)

            case .lifecycle:
                result.append(item)

            default:
                flushPendingWork()
                result.append(item)
            }
        }

        flushPendingWork()
        return result
    }

    func insertingOperationAggregateRows() -> [CodexTranscriptTimelineBuildItem] {
        var result: [CodexTranscriptTimelineBuildItem] = []
        var pendingOperationMessages: [CodexChatMessage] = []

        func flushPendingOperations() {
            guard !pendingOperationMessages.isEmpty else { return }
            let rows = CodexLiveTurnModel.operationRows(for: pendingOperationMessages)
            if pendingOperationMessages.count > 1, !rows.isEmpty {
                let firstID = pendingOperationMessages.first?.id.uuidString ?? UUID().uuidString
                result.append(.operationAggregate(id: "\(firstID)-\(pendingOperationMessages.count)", rows: rows))
            }
            result.append(contentsOf: pendingOperationMessages.map(CodexTranscriptTimelineBuildItem.message))
            pendingOperationMessages = []
        }

        for item in self {
            switch item {
            case .message(let message) where message.isOperationSummaryInput:
                pendingOperationMessages.append(message)
            default:
                flushPendingOperations()
                result.append(item)
            }
        }

        flushPendingOperations()
        return result
    }

    func insertingAggregateFileChangeCards() -> [CodexTranscriptTimelineBuildItem] {
        var result: [CodexTranscriptTimelineBuildItem] = []
        var pendingFileChangeMessages: [CodexChatMessage] = []

        func flushPendingFileChanges() {
            guard !pendingFileChangeMessages.isEmpty else { return }
            let changes = pendingFileChangeMessages.compactMap(\.fileChange)
            if changes.count > 1, CodexLiveTurnModel.changeCardSummary(for: changes) != nil {
                let firstID = pendingFileChangeMessages.first?.id.uuidString ?? UUID().uuidString
                result.append(.fileChangeAggregate(id: "\(firstID)-\(changes.count)", changes: changes))
            }
            result.append(contentsOf: pendingFileChangeMessages.map(CodexTranscriptTimelineBuildItem.message))
            pendingFileChangeMessages = []
        }

        for item in self {
            switch item {
            case .message(let message) where message.role == .fileChange && message.fileChange != nil:
                pendingFileChangeMessages.append(message)
            default:
                flushPendingFileChanges()
                result.append(item)
            }
        }

        flushPendingFileChanges()
        return result
    }
}

private extension CodexChatMessage {
    var isCompletedWorkTraceInput: Bool {
        switch role {
        case .terminal:
            return commandRun != nil && !isStreaming
        case .tool:
            return toolCall != nil && !isStreaming
        case .fileChange:
            return fileChange != nil && !isStreaming
        case .plan:
            return planUpdate != nil && !isStreaming
        case .notice:
            return notice != nil && !isStreaming
        case .reasoning:
            return reasoningBlock != nil && !isStreaming
        case .assistant, .user, .system:
            return false
        }
    }

    var isOperationSummaryInput: Bool {
        switch role {
        case .terminal:
            return commandRun != nil
        case .tool:
            return toolCall != nil
        case .fileChange:
            return fileChange != nil
        case .assistant, .user, .system, .plan, .notice, .reasoning:
            return false
        }
    }
}
