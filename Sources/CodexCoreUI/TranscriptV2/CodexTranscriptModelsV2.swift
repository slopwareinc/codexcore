import CodexCore
import Foundation

public struct CodexTranscriptV2: Sendable, Equatable {
    public var turns: [CodexTurnV2]
    public init(turns: [CodexTurnV2] = []) { self.turns = turns }
}

public enum CodexTurnPresentationStyleV2: Sendable, Equatable {
    case standard
    case realtimeVoice
}

public struct CodexTurnV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var userMessage: CodexUserMessageV2?
    /// Additional user messages appended to this in-flight turn by `turn/steer`.
    public var steeredMessages: [CodexUserMessageV2]
    /// Chronological work slices. The first slice follows `userMessage`; every
    /// later slice begins with its `steeredMessage` and contains only work that
    /// occurred after that steer.
    public var conversationSegments: [CodexTurnConversationSegmentV2]
    public var narrative: [CodexNarrativeEntry]
    public var finalAnswer: CodexAssistantTextV2?
    /// Completed image-generation outputs displayed as persistent turn media.
    public var generatedImages: [CodexGeneratedImageV2]
    public var liveTail: String?
    public var status: CodexTurnStatusV2
    public var presentationStyle: CodexTurnPresentationStyleV2

    public init(id: String, userMessage: CodexUserMessageV2? = nil, steeredMessages: [CodexUserMessageV2] = [], conversationSegments: [CodexTurnConversationSegmentV2]? = nil, narrative: [CodexNarrativeEntry] = [], finalAnswer: CodexAssistantTextV2? = nil, generatedImages: [CodexGeneratedImageV2] = [], liveTail: String? = nil, status: CodexTurnStatusV2, presentationStyle: CodexTurnPresentationStyleV2 = .standard) {
        self.id = id; self.userMessage = userMessage; self.steeredMessages = steeredMessages; self.narrative = narrative
        self.conversationSegments = conversationSegments ?? [
            CodexTurnConversationSegmentV2(id: "\(id):initial", narrative: narrative)
        ] + steeredMessages.map {
            CodexTurnConversationSegmentV2(
                id: "\(id):steer:\($0.clientID ?? $0.id)",
                steeredMessage: $0
            )
        }
        self.finalAnswer = finalAnswer; self.generatedImages = generatedImages
        self.liveTail = liveTail; self.status = status
        self.presentationStyle = presentationStyle
    }
}

public struct CodexTurnConversationSegmentV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var steeredMessage: CodexUserMessageV2?
    public var narrative: [CodexNarrativeEntry]

    public init(
        id: String,
        steeredMessage: CodexUserMessageV2? = nil,
        narrative: [CodexNarrativeEntry] = []
    ) {
        self.id = id
        self.steeredMessage = steeredMessage
        self.narrative = narrative
    }
}

public struct CodexUserMessageV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var clientID: String?
    public var text: String
    public var rawText: String
    public var referencedFiles: [CodexReferencedFile]
    public var responseAnnotations: [CodexResponseAnnotationContent]
    /// Independent Codex task that sent this message, when present.
    public var delegationSource: CodexThreadReferenceV2?
    public var isOptimistic: Bool
    /// Server-backed presentation time. Nil means the protocol supplied no
    /// trustworthy time; renderers must not substitute the hydration clock.
    public var sentAt: Date?
    public init(
        id: String,
        clientID: String? = nil,
        text: String,
        rawText: String? = nil,
        referencedFiles: [CodexReferencedFile] = [],
        responseAnnotations: [CodexResponseAnnotationContent] = [],
        delegationSource: CodexThreadReferenceV2? = nil,
        isOptimistic: Bool = false,
        sentAt: Date? = nil
    ) {
        self.id = id
        self.clientID = clientID
        self.text = text
        self.rawText = rawText ?? text
        self.referencedFiles = referencedFiles
        self.responseAnnotations = responseAnnotations
        self.delegationSource = delegationSource
        self.isOptimistic = isOptimistic
        self.sentAt = sentAt
    }

    public var displayText: String {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = referencedFiles.map { "📎 \($0.displayName)" }.joined(separator: "  ")
        return [request, attachments]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

/// Stable navigation identity for an independent Codex task referenced in a transcript.
public struct CodexThreadReferenceV2: Sendable, Equatable, Hashable {
    public var hostID: String?
    public var threadID: String

    public init(hostID: String? = nil, threadID: String) {
        self.hostID = hostID
        self.threadID = threadID
    }
}

public struct CodexAssistantTextV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var isStreaming: Bool
    public var sentAt: Date?
    public init(id: String, text: String = "", isStreaming: Bool = true, sentAt: Date? = nil) {
        self.id = id; self.text = text; self.isStreaming = isStreaming; self.sentAt = sentAt
    }
}

/// A completed image-generation output that remains visible with the assistant
/// response independently of the collapsible work transcript.
public struct CodexGeneratedImageV2: Identifiable, Sendable, Equatable {
    public var id: String
    /// A local path, file/data/HTTP URL, or raw base64 image payload.
    public var source: String
    public var revisedPrompt: String?

    public init(id: String, source: String, revisedPrompt: String? = nil) {
        self.id = id
        self.source = source
        self.revisedPrompt = revisedPrompt
    }
}

public enum CodexTurnStatusV2: Sendable, Equatable {
    case working(since: Int64?)
    case done(durationMs: Int?)
    case failed(message: String)

    /// Details retained for a user-stopped turn. This is a value type rather
    /// than a protocol status so callers can preserve the elapsed work time
    /// while the existing canonical failure mapping remains source-compatible.
    public struct Interruption: Sendable, Equatable {
        public var durationMs: Int?
        public var message: String

        public init(durationMs: Int? = nil, message: String = "Turn interrupted") {
            self.durationMs = durationMs
            self.message = message
        }
    }

    private static let interruptionPrefix = "\u{001E}codex-turn-interrupted\u{001F}"

    /// Constructs an interrupted terminal state while retaining the elapsed
    /// duration before the user stopped the turn. The encoded payload stays
    /// inside the legacy `.failed` case so existing canonical projections and
    /// their exhaustive switches continue to compile.
    public static func interrupted(durationMs: Int? = nil, message: String = "Turn interrupted") -> Self {
        let duration = durationMs.map(String.init) ?? ""
        return .failed(message: interruptionPrefix + duration + "\n" + message)
    }

    public var interruption: Interruption? {
        guard case .failed(let message) = self else { return nil }
        if message.hasPrefix(Self.interruptionPrefix) {
            let payload = String(message.dropFirst(Self.interruptionPrefix.count))
            let parts = payload.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let duration = parts.first.flatMap { Int($0) }
            let detail = parts.dropFirst().first.map(String.init) ?? "Turn interrupted"
            return Interruption(durationMs: duration, message: detail)
        }
        // Canonical history currently reports interruption as a legacy failure
        // message. Recognize that spelling so it still renders as stopped work.
        guard message.localizedCaseInsensitiveContains("interrupt") else { return nil }
        return Interruption(message: message)
    }
}

public enum CodexNarrativeEntry: Identifiable, Sendable, Equatable {
    case prose(CodexAssistantTextV2)
    case workGroup(CodexWorkGroupV2)
    case productToolCall(CodexProductToolCallV2)
    case inlineActivity(CodexInlineActivityV2)
    case notice(CodexTurnNoticeV2)

    public var id: String {
        switch self {
        case .prose(let value): value.id
        case .workGroup(let value): value.id
        case .productToolCall(let value): value.id
        case .inlineActivity(let value): value.id
        case .notice(let value): value.id
        }
    }
}

public struct CodexWorkGroupV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var header: String
    public var rows: [CodexWorkRowV2]
    public var isLive: Bool
    public init(id: String, header: String = "", rows: [CodexWorkRowV2] = [], isLive: Bool = true) {
        self.id = id; self.header = header; self.rows = rows; self.isLive = isLive
    }
}

public enum CodexWorkItemStatusV2: Sendable, Equatable {
    case inProgress
    case completed
    case failed
    case declined
    case unknown(String)
}

/// User-facing lifecycle for one collaboration agent. This stays distinct from
/// `CodexWorkItemStatusV2`: completing a spawn request does not mean the child
/// agent has completed its task, and a closed child is not the same as success.
public enum CodexAgentDisplayStatusV2: Sendable, Equatable {
    case starting
    case working
    case done
    case failed
    case closed
}

public struct CodexCommandRowV2: Identifiable, Sendable, Equatable {
    public var id: String; public var command: String; public var label: String
    public var action: CodexWorkCategoryV2; public var status: CodexWorkItemStatusV2
    public var exitCode: Int?; public var durationMs: Int?; public var output: String?
    public init(id: String, command: String, label: String, action: CodexWorkCategoryV2, status: CodexWorkItemStatusV2, exitCode: Int? = nil, durationMs: Int? = nil, output: String? = nil) {
        self.id = id; self.command = command; self.label = label; self.action = action; self.status = status
        self.exitCode = exitCode; self.durationMs = durationMs; self.output = output
    }

    /// Compact outcome text used beside a command card's duration. A non-zero
    /// exit status is a failure even when a transport-level item completed.
    public var executionStateLabel: String {
        switch status {
        case .inProgress: return "running"
        case .completed:
            if let exitCode {
                return exitCode == 0 ? "succeeded (exit 0)" : "failed (exit \(exitCode))"
            }
            return "finished"
        case .failed:
            return exitCode.map { "failed (exit \($0))" } ?? "failed"
        case .declined: return "stopped"
        case .unknown: return "status unknown"
        }
    }
}
public struct CodexMCPToolCallRowV2: Identifiable, Sendable, Equatable {
    public var id: String; public var appName: String; public var server: String; public var tool: String
    public var status: CodexWorkItemStatusV2; public var durationMs: Int?; public var errorFirstLine: String?
    public var arguments: CodexJSONValue?; public var result: CodexJSONValue?
}
public struct CodexWebSearchRowV2: Identifiable, Sendable, Equatable {
    public var id: String; public var query: String; public var status: CodexWorkItemStatusV2
}
 public enum CodexCollabActionV2: Sendable, Equatable {
    case created, sentInput, waited, closed
    case started, interacted, interrupted
}

extension CodexCollabAgentRowV2 {
    var label: String {
        let subject: String
        if agentNames.count > 1 {
            subject = "\(agentNames.count) agents"
        } else if let name = agentNames.first, !name.isEmpty {
            subject = "Agent \(name)"
        } else {
            subject = "Agent"
        }
        return switch action {
        case .created, .started:
            "\(subject) · \(status.collaborationLabel(active: "working", completed: "started"))"
        case .sentInput, .interacted: "\(subject) · messaged"
        case .waited:
            "\(subject) · \(status.collaborationLabel(active: "waiting", completed: "finished"))"
        case .closed: "\(subject) · closed"
        case .interrupted: "\(subject) · interrupted"
        }
    }
}
 public struct CodexCollabAgentRowV2: Identifiable, Sendable, Equatable {
     public var id: String; public var action: CodexCollabActionV2; public var agentNames: [String]
     public var agentThreadIDs: [String]
     public var instructions: String?; public var agentMessages: [String: String]
    public var timeline: [CodexCollabActionV2]
    public var status: CodexWorkItemStatusV2
    public var displayStatus: CodexAgentDisplayStatusV2

    public init(
        id: String,
         action: CodexCollabActionV2,
         agentNames: [String],
         agentThreadIDs: [String] = [],
        instructions: String?,
        agentMessages: [String: String] = [:],
        timeline: [CodexCollabActionV2]? = nil,
        status: CodexWorkItemStatusV2,
        displayStatus: CodexAgentDisplayStatusV2? = nil
    ) {
         self.id = id; self.action = action; self.agentNames = agentNames; self.agentThreadIDs = agentThreadIDs
         self.instructions = instructions; self.agentMessages = agentMessages
         self.timeline = timeline ?? [action]; self.status = status
         self.displayStatus = displayStatus ?? {
             switch status {
             case .inProgress: .working
             case .completed: .done
             case .failed, .declined, .unknown: .failed
             }
         }()
    }
}

private extension CodexWorkItemStatusV2 {
    func collaborationLabel(active: String, completed: String) -> String {
        switch self {
        case .inProgress: active
        case .completed: completed
        case .failed: "failed"
        case .declined: "declined"
        case .unknown: "status unknown"
        }
    }
}
public struct CodexOtherWorkRowV2: Identifiable, Sendable, Equatable {
    public var id: String; public var label: String; public var status: CodexWorkItemStatusV2
}

public enum CodexWorkRowV2: Identifiable, Sendable, Equatable {
    case command(CodexCommandRowV2), fileChange(CodexFileChangeRowV2), mcpToolCall(CodexMCPToolCallRowV2)
    case webSearch(CodexWebSearchRowV2), collabAgent(CodexCollabAgentRowV2), other(CodexOtherWorkRowV2)
    public var id: String {
        switch self {
        case .command(let v): v.id; case .fileChange(let v): v.id; case .mcpToolCall(let v): v.id
        case .webSearch(let v): v.id; case .collabAgent(let v): v.id; case .other(let v): v.id
        }
    }
    public var isInProgress: Bool {
        switch self {
        case .command(let v): v.status == .inProgress; case .fileChange(let v): v.status == .inProgress
        case .mcpToolCall(let v): v.status == .inProgress; case .webSearch(let v): v.status == .inProgress
        case .collabAgent(let v): v.status == .inProgress; case .other(let v): v.status == .inProgress
        }
    }
}

public struct CodexProductToolCallV2: Identifiable, Sendable, Equatable {
    public var id: String; public var tool: String; public var namespace: String?
    public var arguments: CodexJSONValue?; public var status: CodexWorkItemStatusV2
    public var contentItems: [CodexJSONValue]; public var success: Bool?
}

/// One compact, semantic activity line embedded in the current assistant turn.
///
/// Hosts should reuse `id` for successive canonical items that represent the
/// same logical activity. Projection then replaces the existing line in place
/// instead of appending another transcript row.
public struct CodexInlineActivityV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var systemImage: String?
    /// Optional learner-facing detail revealed from the compact activity row.
    public var detail: String?
    /// Optional local image displayed inline when the activity is expanded.
    public var imagePath: String?
    public var status: CodexWorkItemStatusV2

    public init(
        id: String,
        label: String,
        systemImage: String? = nil,
        detail: String? = nil,
        imagePath: String? = nil,
        status: CodexWorkItemStatusV2
    ) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.detail = detail
        self.imagePath = imagePath
        self.status = status
    }
}

public struct CodexTurnNoticeV2: Identifiable, Sendable, Equatable {
    public var id: String; public var message: String
    public init(id: String, message: String) { self.id = id; self.message = message }
}

/// The semantic activity category used to summarize and render a work row.
public enum CodexWorkCategoryV2: Sendable, Hashable {
    case read, list, search, loadedTool, webSearch, run, edit, mcp(String)
    case collabCreated, collabClosed, collabWait, collabWorked, imageGeneration
}
