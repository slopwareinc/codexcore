import CodexCore
import Foundation

/// Typed semantic events consumed by transcript projection. The registry is a
/// seam between lossless canonical payloads and presentation grammar; it never
/// mutates canonical state and it deliberately omits malformed values.
public enum CodexTranscriptEvent: Sendable, Equatable {
    case structuredCard(CodexStructuredTranscriptCardV2)
    case userContext(attachments: [CodexUserAttachmentV2], context: [CodexUserContextV2])
    case memoryCitations([CodexMemoryCitationV2])
    case mcpContent([CodexMCPContentBlockV2])
    case approvalReview(CodexApprovalReviewCardV2)
    case hookActivity(CodexHookActivityV2)
    case recovery(CodexTranscriptRecoveryNoticeV2)
    case notice(CodexTurnNoticeV2)
}

public struct CodexTranscriptEventInput: Sendable, Equatable {
    public let item: CanonicalItem
    public let completed: Bool

    public init(item: CanonicalItem, completed: Bool) {
        self.item = item
        self.completed = completed
    }
}

/// One narrow adapter at the canonical-item seam. Adapters are value types so
/// a host can add product-specific event interpretation without introducing a
/// central renderer switch or sharing mutable state across turns.
public struct CodexTranscriptEventAdapter: Sendable {
    public let kind: ThreadItemKind
    private let body: @Sendable (CodexTranscriptEventInput) -> CodexTranscriptEvent?

    public init(
        kind: ThreadItemKind,
        body: @escaping @Sendable (CodexTranscriptEventInput) -> CodexTranscriptEvent?
    ) {
        self.kind = kind
        self.body = body
    }

    public func event(for input: CodexTranscriptEventInput) -> CodexTranscriptEvent? {
        body(input)
    }
}

/// Registry for typed transcript adapters. The built-in adapters are keyed by
/// `ThreadItemKind`, while unknown kinds fail closed instead of becoming a raw
/// JSON or generic Activity row.
public struct CodexTranscriptEventRegistry: Sendable {
    private let adapters: [ThreadItemKind: CodexTranscriptEventAdapter]

    public init(adapters: [CodexTranscriptEventAdapter] = CodexTranscriptEventRegistry.defaultAdapters) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.kind, $0) })
    }

    public func event(for item: CanonicalItem, completed: Bool) -> CodexTranscriptEvent? {
        adapters[item.kind]?.event(for: .init(item: item, completed: completed))
    }

    /// Turns store notification-backed extension facts as typed events. These
    /// extensions are canonical facts; this method only chooses their display
    /// representation and safely ignores malformed dictionaries.
    public func events(for turn: CanonicalTurn) -> [CodexTranscriptEvent] {
        var events: [CodexTranscriptEvent] = turn.extensions.keys.sorted().compactMap { key in
            guard let value = turn.extensions[key] else { return nil }
            return Self.event(forExtensionKey: key, value: value)
        }
        if let error = turn.error?.typedCodexErrorInfo,
           let recovery = Self.recovery(for: error, turn: turn) {
            events.append(.recovery(recovery))
        }
        return events
    }

    public static let defaultAdapters: [CodexTranscriptEventAdapter] = [
        .init(kind: .plan) { input in
            Self.planEvent(from: input.item.payload, completed: input.completed, itemID: input.item.key.itemID.rawValue)
        },
        .init(kind: .agentMessage) { input in
            Self.memoryEvent(from: input.item.payload)
        },
        .init(kind: .userMessage) { input in
            Self.userContextEvent(from: input.item.payload)
        },
        .init(kind: .mcpToolCall) { input in
            Self.mcpEvent(from: input.item.payload)
        },
    ]
}

private extension CodexTranscriptEventRegistry {
    static func planEvent(
        from payload: [String: CodexJSONValue],
        completed: Bool,
        itemID: String
    ) -> CodexTranscriptEvent? {
        let rawKind = payload.string("cardType")
            ?? payload.string("kind")
            ?? payload.string("type")
        let kind: CodexStructuredTranscriptCardKindV2 = switch rawKind?.lowercased() {
        case "todo", "todos", "todo_list": .todo
        case "planimplementation", "plan_implementation", "implementation": .planImplementation
        default: .proposedPlan
        }
        let title = payload.string("title")
            ?? payload.string("text")
            ?? payload.string("objective")
        let steps = parseSteps(
            payload.array("steps") ?? payload.array("plan") ?? [],
            itemID: itemID
        )
        guard title?.isEmpty == false || !steps.isEmpty else { return nil }
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            .codexTranscriptNonEmpty ?? (kind == .todo ? "Todo" : "Plan")
        let explanation = payload.string("explanation")
            ?? payload.string("description")
        let status = cardStatus(
            payload.string("status"),
            completed: completed,
            steps: steps
        )
        return .structuredCard(.init(
            id: itemID,
            kind: kind,
            title: resolvedTitle,
            explanation: explanation?.codexTranscriptNonEmpty,
            steps: steps,
            status: status
        ))
    }

    static func parseSteps(
        _ values: [CodexJSONValue],
        itemID: String
    ) -> [CodexStructuredTranscriptCardStepV2] {
        values.enumerated().compactMap { index, value in
            guard case .dictionary(let object) = value else { return nil }
            let title = object.string("step")
                ?? object.string("title")
                ?? object.string("text")
            guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  title.utf8.count <= 16_384
            else { return nil }
            let status = cardStatus(object.string("status"), completed: false, steps: [])
            return .init(
                id: object.string("id") ?? "(itemID):step:(index)",
                title: title,
                status: status,
                detail: object.string("detail")?.codexTranscriptBounded
            )
        }
    }

    static func cardStatus(
        _ raw: String?,
        completed: Bool,
        steps: [CodexStructuredTranscriptCardStepV2]
    ) -> CodexStructuredTranscriptCardStatusV2 {
        switch raw?.lowercased() {
        case "pending", "todo": return CodexStructuredTranscriptCardStatusV2.pending
        case "inprogress", "in_progress", "running": return .inProgress
        case "completed", "complete", "done": return .completed
        case "failed", "error": return .failed
        case .some(let value): return .unknown(value)
        case nil:
            if completed { return .completed }
            if steps.contains(where: { $0.status == .inProgress }) { return .inProgress }
            return .pending
        }
    }

    static func userContextEvent(from payload: [String: CodexJSONValue]) -> CodexTranscriptEvent? {
        var attachments: [CodexUserAttachmentV2] = []
        if let content = payload.array("content") {
            attachments = content.enumerated().compactMap { index, value in
                let input = CodexInput(jsonValue: value)
                return attachment(input: input, index: index)
            }
        }
        var context: [CodexUserContextV2] = []
        if let object = payload.object("additionalContext") ?? payload.object("context") {
            context = object.keys.sorted().compactMap { key in
                guard let value = object[key]?.stringValue?.codexTranscriptBounded else { return nil }
                let rawKind = object[key]?.object?.string("kind") ?? key
                let kind: CodexUserContextV2.Kind = switch rawKind.lowercased() {
                case "application", "app": .application
                case "untrusted": .untrusted
                default: .unknown
                }
                return .init(id: key, kind: kind, value: value)
            }
        }
        guard !attachments.isEmpty || !context.isEmpty else { return nil }
        return .userContext(attachments: attachments, context: context)
    }

    static func attachment(input: CodexInput, index: Int) -> CodexUserAttachmentV2? {
        switch input {
        case .text:
            return nil
        case .image(let url, let detail):
            return .init(id: "image:\(index):\(url)", kind: .image, label: "Image", value: url, detail: detail?.rawValue)
        case .localImage(let path, let detail):
            return .init(id: "image:\(index):\(path)", kind: .image, label: URL(fileURLWithPath: path).lastPathComponent, value: path, detail: detail?.rawValue)
        case .audio(let url):
            return .init(id: "audio:\(index):\(url)", kind: .audio, label: "Audio", value: url)
        case .localAudio(let path):
            return .init(id: "audio:\(index):\(path)", kind: .audio, label: URL(fileURLWithPath: path).lastPathComponent, value: path)
        case .skill(let name, let path):
            return .init(id: "skill:\(path)", kind: .skill, label: name, value: path)
        case .mention(let name, let path):
            return .init(id: "mention:\(path)", kind: .mention, label: name, value: path)
        case .raw:
            return nil
        }
    }

    static func memoryEvent(from payload: [String: CodexJSONValue]) -> CodexTranscriptEvent? {
        guard let object = payload.object("memoryCitation") else { return nil }
        let sourceThreads = object.array("threadIds")?.compactMap(\.stringValue) ?? []
        let entries = object.array("entries")?.compactMap { value -> CodexMemoryCitationV2? in
            guard case .dictionary(let entry) = value,
                  let path = entry.string("path")?.codexTranscriptNonEmpty,
                  let start = entry.int("lineStart"),
                  let end = entry.int("lineEnd"),
                  let note = entry.string("note")?.codexTranscriptBounded
            else { return nil }
            return .init(
                path: path,
                lineStart: start,
                lineEnd: end,
                note: note,
                sourceThreadIDs: sourceThreads
            )
        } ?? []
        return entries.isEmpty ? nil : .memoryCitations(entries)
    }

    static func mcpEvent(from payload: [String: CodexJSONValue]) -> CodexTranscriptEvent? {
        var blocks: [CodexMCPContentBlockV2] = []
        if let result = payload.object("result") {
            blocks += result.array("content")?.compactMap(CodexMCPContentBlockAdapter.decode) ?? []
            if let structured = result.object("structuredContent") {
                blocks.append(.structured(Self.boundedObject(structured)))
            }
        }
        if let content = payload.array("contentItems") {
            blocks += content.compactMap(CodexMCPContentBlockAdapter.decode)
        }
        return blocks.isEmpty ? nil : .mcpContent(blocks)
    }

    static func event(forExtensionKey key: String, value: CodexJSONValue) -> CodexTranscriptEvent? {
        if key.hasPrefix("autoApprovalReview:"),
           let object = value.object {
            let review = object.object("review") ?? object
            guard let status = review.string("status") else { return nil }
            let reviewStatus = approvalStatus(status)
            let id = object.string("reviewId") ?? String(key.dropFirst("autoApprovalReview:".count))
            let title: String
            switch reviewStatus {
            case .denied: title = "Approval denied"
            case .timedOut: title = "Approval timed out"
            case .approved: title = "Approval approved"
            case .aborted: title = "Approval review stopped"
            case .inProgress: title = "Approval review"
            case .unknown: title = "Approval review"
            }
            return .approvalReview(.init(
                id: id,
                title: title,
                status: reviewStatus,
                rationale: review.string("rationale"),
                riskLevel: review.string("riskLevel"),
                targetItemID: object.string("targetItemId")
            ))
        }
        if key.hasPrefix("hook:"), let object = value.object {
            let run = object.object("run") ?? object
            let status = workStatus(run.string("status"))
            let entries = run.array("entries")?.compactMap { entry -> String? in
                guard case .dictionary(let value) = entry else { return nil }
                return value.string("text")?.codexTranscriptBounded
            } ?? []
            return .hookActivity(.init(
                id: run.string("id") ?? key,
                eventName: run.string("eventName") ?? "Hook",
                handler: run.string("handlerType") ?? "",
                status: status,
                durationMs: run.int("durationMs"),
                entries: entries,
                statusMessage: run.string("statusMessage")?.codexTranscriptBounded
            ))
        }
        if key == "model/rerouted", let object = value.object {
            let from = object.string("fromModel") ?? "previous model"
            let to = object.string("toModel") ?? "another model"
            return .notice(.init(id: key, message: "Model changed from \(from) to \(to)"))
        }
        if key == "model/safetyBuffering/updated", let object = value.object,
           object.bool("showBufferingUi") == true {
            return .notice(.init(id: key, message: "Model is buffering the response"))
        }
        // The item-backed representation already emits the stable
        // `context-compacted-<turn>` notice. Do not add a second entry when the
        // live extension and hydrated item are reconciled.
        if key == "contextCompacted" { return nil }
        if key == "lastErrorWillRetry", value == .bool(true) {
            return .recovery(.init(id: key, kind: .turnRetry, message: "Retrying this turn", canRetry: true))
        }
        if key == "writerConflict" { return .recovery(.init(id: key, kind: .writerConflict, message: "Another writer changed this thread", canRetry: true)) }
        return nil
    }

    static func recovery(
        for error: CodexTurnErrorInfo,
        turn: CanonicalTurn
    ) -> CodexTranscriptRecoveryNoticeV2? {
        let id = "turn-recovery:\(turn.key.turnID.rawValue)"
        switch error {
        case .serverOverloaded:
            return .init(
                id: id,
                kind: .overload,
                message: "The service is busy; retrying this turn",
                canRetry: true
            )
        case .responseStreamConnectionFailed, .responseStreamDisconnected, .httpConnectionFailed:
            return .init(
                id: id,
                kind: .streamFailure,
                message: "Response stream disconnected; reconnecting",
                canRetry: true
            )
        case .responseTooManyFailedAttempts:
            return .init(
                id: id,
                kind: .historyRetry,
                message: "The response could not be recovered automatically",
                canRetry: true
            )
        case .threadRollbackFailed:
            return .init(
                id: id,
                kind: .rollback,
                message: "Rollback was not applied; the thread remains unchanged",
                canRetry: true
            )
        case .contextWindowExceeded:
            return .init(
                id: id,
                kind: .historyRetry,
                message: "Context limit reached; retry after compacting history",
                canRetry: true
            )
        case .activeTurnNotSteerable:
            return .init(
                id: id,
                kind: .turnRetry,
                message: "This turn cannot accept another steer yet",
                canRetry: true
            )
        case .usageLimitExceeded, .sessionBudgetExceeded, .cyberPolicy,
             .internalServerError, .unauthorized, .badRequest, .sandboxError,
             .other, .unknown:
            return nil
        }
    }

    static func approvalStatus(_ value: String) -> CodexApprovalReviewStatusV2 {
        switch value.lowercased() {
        case "inprogress", "in_progress", "started": .inProgress
        case "approved", "allow": .approved
        case "denied", "rejected": .denied
        case "timedout", "timed_out", "timeout": .timedOut
        case "aborted", "cancelled", "canceled": .aborted
        default: .unknown(value)
        }
    }

    static func workStatus(_ value: String?) -> CodexWorkItemStatusV2 {
        switch value?.lowercased() {
        case "running", "inprogress", "in_progress": .inProgress
        case "completed", "complete", "done": .completed
        case "failed", "error": .failed
        case "declined": .declined
        case .some(let value): .unknown(value)
        case nil: .completed
        }
    }

    static func boundedObject(_ object: [String: CodexJSONValue]) -> [String: CodexJSONValue] {
        object.reduce(into: [:]) { result, pair in
            guard result.count < 64 else { return }
            result[pair.key] = pair.value
        }
    }
}

public enum CodexMCPContentBlockAdapter {
    public static let maximumTextBytes = 100_000

    public static func decode(_ value: CodexJSONValue) -> CodexMCPContentBlockV2? {
        guard case .dictionary(let object) = value,
              let type = object.string("type")?.lowercased()
        else { return nil }
        switch type {
        case "text":
            guard let text = object.string("text")?.codexTranscriptBounded else { return nil }
            return .text(text)
        case "image":
            guard let source = object.string("data") ?? object.string("url") ?? object.string("path"),
                  !source.isEmpty
            else { return nil }
            return .image(source: source, mimeType: object.string("mimeType"), alt: object.string("alt") ?? object.string("name"))
        case "audio":
            guard let source = object.string("data") ?? object.string("url") ?? object.string("path"),
                  !source.isEmpty
            else { return nil }
            return .audio(source: source, mimeType: object.string("mimeType"))
        case "resource":
            let resource = object.object("resource") ?? object
            guard let uri = resource.string("uri")?.codexTranscriptNonEmpty else { return nil }
            return .resource(uri: uri, mimeType: resource.string("mimeType"), text: resource.string("text")?.codexTranscriptBounded)
        case "resource_link", "resourcelink":
            guard let uri = object.string("uri")?.codexTranscriptNonEmpty else { return nil }
            return .resourceLink(uri: uri, name: object.string("name")?.codexTranscriptBounded, mimeType: object.string("mimeType"))
        case "structured", "structuredcontent":
            guard let content = object.object("data") ?? object.object("structuredContent") else { return nil }
            return .structured(content)
        case "widget", "mcp_app", "mcpapp":
            let payload = object.object("payload") ?? object.object("data") ?? [:]
            return .widget(id: object.string("id"), uri: object.string("uri") ?? object.string("resourceUri"), payload: payload)
        default:
            return nil
        }
    }
}

private extension Dictionary where Key == String, Value == CodexJSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }

    func int(_ key: String) -> Int? {
        guard case .int(let value)? = self[key] else { return nil }
        return value
    }

    func bool(_ key: String) -> Bool? {
        guard case .bool(let value)? = self[key] else { return nil }
        return value
    }

    func object(_ key: String) -> [String: CodexJSONValue]? {
        guard case .dictionary(let value)? = self[key] else { return nil }
        return value
    }

    func array(_ key: String) -> [CodexJSONValue]? {
        guard case .array(let value)? = self[key] else { return nil }
        return value
    }
}

private extension CodexJSONValue {
    var object: [String: CodexJSONValue]? {
        guard case .dictionary(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

private extension String {
    var codexTranscriptNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var codexTranscriptBounded: String? {
        guard let value = codexTranscriptNonEmpty else { return nil }
        guard value.utf8.count > CodexMCPContentBlockAdapter.maximumTextBytes else { return value }
        var result = String(value.prefix(100_000))
        result += "\n… content truncated"
        return result
    }
}
