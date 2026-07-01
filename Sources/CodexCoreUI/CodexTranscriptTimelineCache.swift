import Foundation

enum CodexTranscriptTimelineDigest {
    static func messages(
        messages: [CodexChatMessage],
        lifecycleEvents: [CodexAgentLifecycleEvent]
    ) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        mixUInt64(&hash, UInt64(messages.count))
        for message in messages {
            mixUUID(&hash, message.id)
            mixString(&hash, message.role.rawValue)
            mixBool(&hash, message.isStreaming)
            mixUInt64(&hash, UInt64(message.text.count))
            mixOptionalString(&hash, message.detail)
            if message.isStreaming {
                mixStringTail(&hash, message.text, maxBytes: 512)
            }
            if let commandRun = message.commandRun {
                mixString(&hash, commandRun.itemID)
                mixUInt64(&hash, UInt64(commandRun.output.count))
                mixBool(&hash, commandRun.isStreaming)
                mixOptionalInt(&hash, commandRun.exitCode)
            }
            if let fileChange = message.fileChange {
                mixString(&hash, fileChange.itemID)
                mixUInt64(&hash, UInt64(fileChange.diff.count))
                mixUInt64(&hash, UInt64(fileChange.output.count))
                mixBool(&hash, fileChange.isStreaming)
            }
            if let plan = message.planUpdate {
                mixUInt64(&hash, UInt64(plan.text.count))
                mixUInt64(&hash, UInt64(plan.steps.count))
                mixBool(&hash, plan.isStreaming)
            }
            if let toolCall = message.toolCall {
                mixString(&hash, toolCall.itemID)
                mixUInt64(&hash, UInt64(toolCall.result.count))
                mixUInt64(&hash, UInt64(toolCall.arguments.count))
                mixBool(&hash, toolCall.isStreaming)
            }
            if let notice = message.notice {
                mixUInt64(&hash, UInt64(notice.detail.count))
                mixBool(&hash, notice.isStreaming)
            }
            if let reasoning = message.reasoningBlock {
                mixString(&hash, reasoning.itemID)
                mixUInt64(&hash, UInt64(reasoning.text.count))
                mixBool(&hash, reasoning.isStreaming)
            }
        }
        mixUInt64(&hash, UInt64(lifecycleEvents.count))
        for event in lifecycleEvents {
            mixUUID(&hash, event.id)
            mixString(&hash, event.status.rawValue)
            mixUInt64(&hash, UInt64(event.detail.count))
        }
        return hash
    }

    static func lifecycleEvents(_ events: [CodexAgentLifecycleEvent]) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        mixUInt64(&hash, UInt64(events.count))
        for event in events {
            mixUUID(&hash, event.id)
            mixString(&hash, event.title)
            mixString(&hash, event.status.rawValue)
            mixUInt64(&hash, UInt64(event.detail.count))
            mixUInt64(&hash, UInt64(event.agentNames.count))
        }
        return hash
    }

    static func activeTurn(_ activeTurn: CodexActiveTurnState?) -> UInt64 {
        guard let activeTurn else { return 0 }
        var hash: UInt64 = 1469598103934665603
        mixDate(&hash, activeTurn.startedAt)
        if let activity = activeTurn.activity {
            mixUUID(&hash, activity.id)
            mixString(&hash, activity.kind.rawValue)
            mixUInt64(&hash, UInt64(activity.title.count))
            mixUInt64(&hash, UInt64(activity.detail.count))
        }
        return hash
    }

    private static func mixStringTail(_ hash: inout UInt64, _ value: String, maxBytes: Int) {
        let suffix = value.utf8.suffix(maxBytes)
        for byte in suffix {
            mixUInt8(&hash, byte)
        }
        mixUInt8(&hash, 0)
    }

    private static func mixUUID(_ hash: inout UInt64, _ value: UUID) {
        let uuid = value.uuid
        mixUInt64(&hash, UInt64(uuid.0))
        mixUInt64(&hash, UInt64(uuid.1))
        mixUInt64(&hash, UInt64(uuid.2))
        mixUInt64(&hash, UInt64(uuid.3))
        mixUInt64(&hash, UInt64(uuid.4))
        mixUInt64(&hash, UInt64(uuid.5))
        mixUInt64(&hash, UInt64(uuid.6))
        mixUInt64(&hash, UInt64(uuid.7))
        mixUInt64(&hash, UInt64(uuid.8))
        mixUInt64(&hash, UInt64(uuid.9))
        mixUInt64(&hash, UInt64(uuid.10))
        mixUInt64(&hash, UInt64(uuid.11))
        mixUInt64(&hash, UInt64(uuid.12))
        mixUInt64(&hash, UInt64(uuid.13))
        mixUInt64(&hash, UInt64(uuid.14))
        mixUInt64(&hash, UInt64(uuid.15))
    }

    private static func mixDate(_ hash: inout UInt64, _ value: Date) {
        mixUInt64(&hash, UInt64(bitPattern: Int64(value.timeIntervalSinceReferenceDate * 1000)))
    }

    private static func mixBool(_ hash: inout UInt64, _ value: Bool) {
        mixUInt64(&hash, value ? 1 : 0)
    }

    private static func mixOptionalInt(_ hash: inout UInt64, _ value: Int?) {
        mixUInt64(&hash, value.map { UInt64(bitPattern: Int64($0)) } ?? 0)
    }

    private static func mixOptionalString(_ hash: inout UInt64, _ value: String?) {
        mixUInt64(&hash, UInt64(value?.count ?? 0))
    }

    private static func mixString(_ hash: inout UInt64, _ value: String) {
        mixUInt64(&hash, UInt64(value.count))
        if value.count <= 64 {
            for byte in value.utf8 {
                mixUInt8(&hash, byte)
            }
        } else {
            for byte in value.utf8.prefix(32) {
                mixUInt8(&hash, byte)
            }
            for byte in value.utf8.suffix(32) {
                mixUInt8(&hash, byte)
            }
        }
        mixUInt8(&hash, 0)
    }

    private static func mixUInt64(_ hash: inout UInt64, _ value: UInt64) {
        hash ^= value
        hash &*= 1099511628211
    }

    private static func mixUInt8(_ hash: inout UInt64, _ value: UInt8) {
        hash ^= UInt64(value)
        hash &*= 1099511628211
    }
}

@MainActor
struct CodexTranscriptInput: Equatable {
    let transcriptID: String?
    let messageCount: Int
    let firstMessageID: UUID?
    let lastMessageID: UUID?
    let streamingVersion: Int
    let lifecycleCount: Int
    let lastLifecycleID: UUID?
    let activeTurnDigest: UInt64
    let structuralDigest: UInt64

    init(
        transcriptID: String?,
        messages: [CodexChatMessage],
        lifecycleEvents: [CodexAgentLifecycleEvent],
        activeTurn: CodexActiveTurnState?
    ) {
        self.transcriptID = transcriptID
        self.messageCount = messages.count
        self.firstMessageID = messages.first?.id
        self.lastMessageID = messages.last?.id
        self.streamingVersion = Self.streamingVersion(for: messages)
        self.lifecycleCount = lifecycleEvents.count
        self.lastLifecycleID = lifecycleEvents.last?.id
        self.activeTurnDigest = CodexTranscriptTimelineDigest.activeTurn(activeTurn)
        self.structuralDigest = CodexTranscriptTimelineDigest.messages(
            messages: messages,
            lifecycleEvents: lifecycleEvents
        )
    }

    func cacheKey(lifecycleEvents: [CodexAgentLifecycleEvent]) -> CodexTranscriptTimelineCache.Key {
        CodexTranscriptTimelineCache.Key(
            input: self,
            lifecycleEvents: lifecycleEvents
        )
    }

    private static func streamingVersion(for messages: [CodexChatMessage]) -> Int {
        messages.reduce(into: 0) { total, message in
            if message.isStreaming {
                total &+= message.text.count
            }
            if let commandRun = message.commandRun, commandRun.isStreaming {
                total &+= commandRun.output.count
            }
            if let fileChange = message.fileChange, fileChange.isStreaming {
                total &+= fileChange.diff.count &+ fileChange.output.count
            }
            if let plan = message.planUpdate, plan.isStreaming {
                total &+= plan.text.count
            }
            if let toolCall = message.toolCall, toolCall.isStreaming {
                total &+= toolCall.result.count &+ toolCall.progress.joined().count
            }
            if let notice = message.notice, notice.isStreaming {
                total &+= notice.detail.count
            }
            if let reasoning = message.reasoningBlock, reasoning.isStreaming {
                total &+= reasoning.text.count
            }
        }
    }
}

@MainActor
enum CodexTranscriptTimelineCache {
    struct Key: Equatable {
        let transcriptID: String?
        let messageDigest: UInt64
        let lifecycleDigest: UInt64
        let activeTurnDigest: UInt64

        init(input: CodexTranscriptInput, lifecycleEvents: [CodexAgentLifecycleEvent]) {
            self.transcriptID = input.transcriptID
            self.messageDigest = input.structuralDigest
            self.lifecycleDigest = CodexTranscriptTimelineDigest.lifecycleEvents(lifecycleEvents)
            self.activeTurnDigest = input.activeTurnDigest
        }
    }

    private struct Entry {
        let key: Key
        let items: [CodexTranscriptTimelineItem]
    }

    private static var entries: [String: Entry] = [:]

    static func cachedItems(for key: Key) -> [CodexTranscriptTimelineItem]? {
        let storageKey = key.transcriptID ?? "empty-transcript"
        guard let cached = entries[storageKey], cached.key == key else {
            return nil
        }
        return cached.items
    }

    static func store(key: Key, items: [CodexTranscriptTimelineItem]) {
        let storageKey = key.transcriptID ?? "empty-transcript"
        entries[storageKey] = Entry(key: key, items: items)
    }

    static func clear(transcriptID: String? = nil) {
        if let transcriptID {
            entries.removeValue(forKey: transcriptID)
        } else {
            entries.removeAll()
        }
    }
}
