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
    /// Structured terminal failures displayed beside final turn content.
    public var imageGenerationFailures: [CodexImageGenerationFailureV2]
    /// Structured cards are presentation-ready projections of canonical plan,
    /// todo, and implementation facts. They retain no expansion state.
    public var structuredCards: [CodexStructuredTranscriptCardV2]
    /// Automatic approval review outcomes are kept separate from pending
    /// interaction prompts so a completed denial/timeout remains visible.
    public var approvalReviews: [CodexApprovalReviewCardV2]
    /// Hook runs are chronological transcript activity, not diagnostics only.
    public var hookActivities: [CodexHookActivityV2]
    /// Recoverable failures are explicit transcript notices rather than a
    /// spinner that can survive a disconnected session.
    public var recoveryNotices: [CodexTranscriptRecoveryNoticeV2]
    public var liveTail: String?
    public var status: CodexTurnStatusV2
    public var presentationStyle: CodexTurnPresentationStyleV2

    public init(id: String, userMessage: CodexUserMessageV2? = nil, steeredMessages: [CodexUserMessageV2] = [], conversationSegments: [CodexTurnConversationSegmentV2]? = nil, narrative: [CodexNarrativeEntry] = [], finalAnswer: CodexAssistantTextV2? = nil, generatedImages: [CodexGeneratedImageV2] = [], imageGenerationFailures: [CodexImageGenerationFailureV2] = [], structuredCards: [CodexStructuredTranscriptCardV2] = [], approvalReviews: [CodexApprovalReviewCardV2] = [], hookActivities: [CodexHookActivityV2] = [], recoveryNotices: [CodexTranscriptRecoveryNoticeV2] = [], liveTail: String? = nil, status: CodexTurnStatusV2, presentationStyle: CodexTurnPresentationStyleV2 = .standard) {
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
        self.imageGenerationFailures = imageGenerationFailures
        self.structuredCards = structuredCards
        self.approvalReviews = approvalReviews
        self.hookActivities = hookActivities
        self.recoveryNotices = recoveryNotices
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
    /// Typed non-text input arms from the app-server UserInput union.
    public var attachments: [CodexUserAttachmentV2]
    /// Additional context is canonical input metadata and is never folded into
    /// the editable request string.
    public var context: [CodexUserContextV2]
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
        attachments: [CodexUserAttachmentV2] = [],
        context: [CodexUserContextV2] = [],
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
        self.attachments = attachments
        self.context = context
        self.delegationSource = delegationSource
        self.isOptimistic = isOptimistic
        self.sentAt = sentAt
    }

    public var displayText: String {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = referencedFiles.map { "📎 \($0.displayName)" }
        let typed = attachments.map { "📎 \($0.label)" }
        return [request, (files + typed).joined(separator: "  ")]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

/// A user attachment projected from a typed app-server `UserInput` arm.
public struct CodexUserAttachmentV2: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case image
        case audio
        case skill
        case mention
        case file
        case raw
    }

    public var id: String
    public var kind: Kind
    public var label: String
    public var value: String
    public var detail: String?

    public init(
        id: String,
        kind: Kind,
        label: String,
        value: String,
        detail: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.value = value
        self.detail = detail
    }
}

public struct CodexUserContextV2: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case application
        case untrusted
        case unknown
    }

    public var id: String
    public var kind: Kind
    public var value: String

    public init(id: String, kind: Kind, value: String) {
        self.id = id
        self.kind = kind
        self.value = value
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
    public var memoryCitations: [CodexMemoryCitationV2]
    /// Source/provenance annotations attached to the assistant response. These
    /// are immutable canonical facts; opening a source is a host action.
    public var sourceCitations: [CodexTranscriptSourceCitationV2]
    /// Generated files/resources shown after the answer without eagerly
    /// materializing their bytes.
    public var outputResources: [CodexTranscriptOutputResourceV2]
    public init(id: String, text: String = "", isStreaming: Bool = true, sentAt: Date? = nil, memoryCitations: [CodexMemoryCitationV2] = [], sourceCitations: [CodexTranscriptSourceCitationV2] = [], outputResources: [CodexTranscriptOutputResourceV2] = []) {
        self.id = id; self.text = text; self.isStreaming = isStreaming; self.sentAt = sentAt
        self.memoryCitations = memoryCitations
        self.sourceCitations = sourceCitations
        self.outputResources = outputResources
    }
}

public struct CodexMemoryCitationV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var path: String
    public var lineStart: Int
    public var lineEnd: Int
    public var note: String
    public var sourceThreadIDs: [String]

    public init(
        id: String? = nil,
        path: String,
        lineStart: Int,
        lineEnd: Int,
        note: String,
        sourceThreadIDs: [String] = []
    ) {
        self.path = String(path.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_096))
        self.lineStart = max(1, lineStart)
        self.lineEnd = max(self.lineStart, lineEnd)
        self.note = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000))
        self.sourceThreadIDs = sourceThreadIDs.prefix(32).map { String($0.prefix(256)) }
        self.id = id ?? self.path + ":" + String(self.lineStart) + ":" + String(self.lineEnd)
    }
}

/// A completed image-generation output that remains visible with the assistant
/// response independently of the collapsible work transcript.
public struct CodexGeneratedImageV2: Identifiable, Sendable, Equatable {
    public var id: String
    /// A local path, file/data/HTTP URL, or raw base64 image payload.
    public var source: String
    public var revisedPrompt: String?
    public var hasTransparentBackground: Bool?

    public init(
        id: String,
        source: String,
        revisedPrompt: String? = nil,
        hasTransparentBackground: Bool? = nil
    ) {
        self.id = id
        self.source = source
        self.revisedPrompt = revisedPrompt
        self.hasTransparentBackground = hasTransparentBackground
    }
}

public struct CodexImageGenerationFailureV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var type: String
    public var limitID: String?
    public var resetsAt: Date?
    public var message: String

    public init(
        id: String,
        type: String,
        limitID: String? = nil,
        resetsAt: Date? = nil,
        message: String
    ) {
        self.id = id
        self.type = type
        self.limitID = limitID
        self.resetsAt = resetsAt
        self.message = message
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
    case structuredCard(CodexStructuredTranscriptCardV2)
    case approvalReview(CodexApprovalReviewCardV2)
    case hookActivity(CodexHookActivityV2)
    case recovery(CodexTranscriptRecoveryNoticeV2)
    case notice(CodexTurnNoticeV2)

    public var id: String {
        switch self {
        case .prose(let value): value.id
        case .workGroup(let value): value.id
        case .productToolCall(let value): value.id
        case .inlineActivity(let value): value.id
        case .structuredCard(let value): value.id
        case .approvalReview(let value): value.id
        case .hookActivity(let value): value.id
        case .recovery(let value): value.id
        case .notice(let value): value.id
        }
    }
}

public enum CodexStructuredTranscriptCardKindV2: String, Sendable, Equatable {
    case todo
    case proposedPlan
    case planImplementation
}

public enum CodexStructuredTranscriptCardStatusV2: Sendable, Equatable {
    case pending
    case inProgress
    case completed
    case failed
    case unknown(String)
}

public enum CodexStructuredTranscriptCardActionV2: String, Sendable, Equatable {
    case collapse
    case expand
    case implement
    case openPlan
}

public struct CodexStructuredTranscriptCardStepV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var status: CodexStructuredTranscriptCardStatusV2
    public var detail: String?

    public init(
        id: String,
        title: String,
        status: CodexStructuredTranscriptCardStatusV2 = .pending,
        detail: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
    }
}

public struct CodexStructuredTranscriptCardV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var kind: CodexStructuredTranscriptCardKindV2
    public var title: String
    public var explanation: String?
    public var steps: [CodexStructuredTranscriptCardStepV2]
    public var status: CodexStructuredTranscriptCardStatusV2

    public var completedStepCount: Int {
        steps.reduce(into: 0) { count, step in
            if step.status == .completed { count += 1 }
        }
    }

    public var summary: String {
        guard !steps.isEmpty else { return title }
        return String(completedStepCount) + " of " + String(steps.count) + " tasks completed"
    }

    public var availableActions: [CodexStructuredTranscriptCardActionV2] {
        switch kind {
        case .todo:
            return steps.isEmpty ? [] : [.collapse, .expand]
        case .proposedPlan:
            switch status {
            case .pending, .completed: return [.collapse, .expand, .implement]
            case .inProgress, .failed, .unknown: return [.collapse, .expand]
            }
        case .planImplementation:
            return [.openPlan]
        }
    }

    public init(
        id: String,
        kind: CodexStructuredTranscriptCardKindV2,
        title: String,
        explanation: String? = nil,
        steps: [CodexStructuredTranscriptCardStepV2] = [],
        status: CodexStructuredTranscriptCardStatusV2 = .pending
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.explanation = explanation
        self.steps = steps
        self.status = status
    }

    public static func todo(
        id: String,
        title: String = "Todo",
        steps: [CodexStructuredTranscriptCardStepV2],
        explanation: String? = nil,
        status: CodexStructuredTranscriptCardStatusV2 = .pending
    ) -> Self {
        .init(id: id, kind: .todo, title: title, explanation: explanation, steps: steps, status: status)
    }

    public static func proposedPlan(
        id: String,
        title: String = "Plan",
        steps: [CodexStructuredTranscriptCardStepV2],
        explanation: String? = nil,
        status: CodexStructuredTranscriptCardStatusV2 = .pending
    ) -> Self {
        .init(id: id, kind: .proposedPlan, title: title, explanation: explanation, steps: steps, status: status)
    }

    public static func planImplementation(
        id: String,
        title: String = "Implementation",
        steps: [CodexStructuredTranscriptCardStepV2],
        explanation: String? = nil,
        status: CodexStructuredTranscriptCardStatusV2 = .inProgress
    ) -> Self {
        .init(id: id, kind: .planImplementation, title: title, explanation: explanation, steps: steps, status: status)
    }
}

/// Short aliases keep the public surface discoverable for hosts that prefer
/// the product names used by the official renderer.
public typealias CodexTodoCardV2 = CodexStructuredTranscriptCardV2
public typealias CodexProposedPlanCardV2 = CodexStructuredTranscriptCardV2
public typealias CodexPlanImplementationCardV2 = CodexStructuredTranscriptCardV2
public typealias CodexTodoItemV2 = CodexStructuredTranscriptCardStepV2

public enum CodexApprovalReviewStatusV2: Sendable, Equatable {
    case inProgress
    case approved
    case denied
    case timedOut
    case aborted
    case unknown(String)
}

public struct CodexApprovalReviewCardV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var status: CodexApprovalReviewStatusV2
    public var rationale: String?
    public var riskLevel: String?
    public var targetItemID: String?
    public var targetSummary: String?
    public var isHighRisk: Bool { Self.highRisk(riskLevel) }
    public var interruptedTurn: Bool

    public var availableActions: [String] {
        var actions = ["expand details"]
        if status == .inProgress || interruptedTurn { actions.append("change permission mode") }
        return actions
    }

    public init(
        id: String,
        title: String = "Approval review",
        status: CodexApprovalReviewStatusV2,
        rationale: String? = nil,
        riskLevel: String? = nil,
        targetItemID: String? = nil,
        targetSummary: String? = nil,
        interruptedTurn: Bool = false
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.rationale = rationale
        self.riskLevel = riskLevel
        self.targetItemID = targetItemID
        self.targetSummary = targetSummary
        self.interruptedTurn = interruptedTurn
    }

    public init(
        id: String,
        review: CodexSchemaGuardianApprovalReview,
        targetItemID: String? = nil
    ) {
        self.init(
            id: id,
            status: Self.status(review.status),
            rationale: review.rationale,
            riskLevel: review.riskLevel?.rawValue,
            targetItemID: targetItemID,
            targetSummary: nil
        )
    }

    public var statusLabel: String {
        switch status {
        case .inProgress: "Reviewing"
        case .approved: "Approved"
        case .denied: "Denied"
        case .timedOut: "Timed out"
        case .aborted: "Review stopped"
        case .unknown: "Review status unavailable"
        }
    }

    private static func status(_ value: CodexSchemaGuardianApprovalReviewStatus) -> CodexApprovalReviewStatusV2 {
        switch value {
        case .inProgress: .inProgress
        case .approved: .approved
        case .denied: .denied
        case .timedOut: .timedOut
        case .aborted: .aborted
        case .unrecognized(let raw): .unknown(raw)
        }
    }

    private static func highRisk(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.caseInsensitiveCompare("high") == .orderedSame
            || value.caseInsensitiveCompare("critical") == .orderedSame
    }
}

public struct CodexHookActivityV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var eventName: String
    public var handler: String
    public var status: CodexWorkItemStatusV2
    public var durationMs: Int?
    public var entries: [String]
    public var statusMessage: String?
    public var outputIsTruncated: Bool

    public init(
        id: String,
        eventName: String,
        handler: String,
        status: CodexWorkItemStatusV2,
        durationMs: Int? = nil,
        entries: [String] = [],
        statusMessage: String? = nil,
        outputIsTruncated: Bool = false
    ) {
        self.id = id
        self.eventName = eventName
        self.handler = handler
        self.status = status
        self.durationMs = durationMs
        self.entries = entries
        self.statusMessage = statusMessage
        self.outputIsTruncated = outputIsTruncated
    }

    public var label: String {
        let event = eventName.isEmpty ? "Hook" : Self.humanize(eventName)
        let handlerLabel = handler.isEmpty ? "" : Self.humanize(handler)
        return handlerLabel.isEmpty ? event : event + " · " + handlerLabel
    }

    private static func humanize(_ value: String) -> String {
        let separated = value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        var result = ""
        for character in separated {
            if character.isUppercase, !result.isEmpty, result.last != " " { result.append(" ") }
            result.append(character)
        }
        return result.prefix(1).uppercased() + result.dropFirst()
    }
}

public enum CodexTranscriptRecoveryKindV2: Sendable, Equatable {
    case reconnecting(attempt: Int)
    case overload
    case historyRetry
    case turnRetry
    case writerConflict
    case rollback
    case streamFailure
    case unknown(String)
}

public extension CodexTranscriptRecoveryKindV2 {
    var label: String {
        switch self {
        case .reconnecting: "Reconnecting"
        case .overload: "Service busy"
        case .historyRetry: "History retry"
        case .turnRetry: "Turn retry"
        case .writerConflict: "Writer conflict"
        case .rollback: "Rollback"
        case .streamFailure: "Stream disconnected"
        case .unknown: "Recovery"
        }
    }
}

public struct CodexTranscriptRecoveryNoticeV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var kind: CodexTranscriptRecoveryKindV2
    public var message: String
    public var canRetry: Bool
    public var scope: String?
    public var attempt: Int?
    public var maximumAttempts: Int?
    public var countdownSeconds: Int?
    public var isTerminal: Bool
    public var retryLabel: String?

    public init(
        id: String,
        kind: CodexTranscriptRecoveryKindV2,
        message: String,
        canRetry: Bool = false,
        scope: String? = nil,
        attempt: Int? = nil,
        maximumAttempts: Int? = nil,
        countdownSeconds: Int? = nil,
        isTerminal: Bool = false,
        retryLabel: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.canRetry = canRetry
        self.scope = scope
        self.attempt = attempt.map { max(0, $0) }
        self.maximumAttempts = maximumAttempts.map { max(0, $0) }
        self.countdownSeconds = countdownSeconds.map { max(0, $0) }
        self.isTerminal = isTerminal
        self.retryLabel = retryLabel
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

extension CodexAgentDisplayStatusV2 {
    var transcriptLabel: String {
        switch self {
        case .starting: "Starting"
        case .working: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .closed: "Closed"
        }
    }
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
    public var readOnlyHint: Bool?
    public var contentBlocks: [CodexMCPContentBlockV2]

    public var widgets: [CodexMCPWidgetV2] {
        contentBlocks.compactMap { block in
            guard case .widget(let id, let uri, let payload) = block else { return nil }
            return .init(id: id ?? uri ?? "widget", uri: uri, payload: payload)
        }
    }

    public init(
        id: String,
        appName: String,
        server: String,
        tool: String,
        status: CodexWorkItemStatusV2,
        durationMs: Int? = nil,
        errorFirstLine: String? = nil,
        arguments: CodexJSONValue? = nil,
        result: CodexJSONValue? = nil,
        readOnlyHint: Bool? = nil,
        contentBlocks: [CodexMCPContentBlockV2] = []
    ) {
        self.id = id
        self.appName = appName
        self.server = server
        self.tool = tool
        self.status = status
        self.durationMs = durationMs
        self.errorFirstLine = errorFirstLine
        self.arguments = arguments
        self.result = result
        self.readOnlyHint = readOnlyHint
        self.contentBlocks = contentBlocks
    }
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

    /// Message order used by expanded transcript details. Named agents retain
    /// source order and duplicates; only otherwise-unlisted agents are sorted.
    var orderedMessageAgentNames: [String] {
        let namedAgents = Set(agentNames)
        return agentNames.filter { agentMessages[$0] != nil }
            + agentMessages.keys.filter { !namedAgents.contains($0) }.sorted()
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

public enum CodexTurnNoticeKindV2: Sendable, Equatable {
    case generic
    case modelReroute
    case personality
    case fork
    case worktree
    case remoteTask
    case review
    case hook
}

public struct CodexTurnNoticeV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var message: String
    public var kind: CodexTurnNoticeKindV2
    public var detail: String?
    public var target: CodexThreadReferenceV2?
    public var isBlocking: Bool
    public var actionLabel: String?

    public init(
        id: String,
        message: String,
        kind: CodexTurnNoticeKindV2 = .generic,
        detail: String? = nil,
        target: CodexThreadReferenceV2? = nil,
        isBlocking: Bool = false,
        actionLabel: String? = nil
    ) {
        self.id = id
        self.message = message
        self.kind = kind
        self.detail = detail
        self.target = target
        self.isBlocking = isBlocking
        self.actionLabel = actionLabel
    }
}

/// The semantic activity category used to summarize and render a work row.
public enum CodexWorkCategoryV2: Sendable, Hashable {
    case read, list, search, loadedTool, webSearch, run, edit, mcp(String)
    case collabCreated, collabClosed, collabWait, collabWorked, imageGeneration
}
