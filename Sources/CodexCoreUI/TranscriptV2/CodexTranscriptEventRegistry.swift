import CodexCore
import Foundation

/// Typed semantic events consumed by transcript projection. The registry is a
/// seam between lossless canonical payloads and presentation grammar; it never
/// mutates canonical state and it deliberately omits malformed values.
public enum CodexTranscriptEvent: Sendable, Equatable {
    case structuredCard(CodexStructuredTranscriptCardV2)
    case userContext(attachments: [CodexUserAttachmentV2], context: [CodexUserContextV2])
    case memoryCitations([CodexMemoryCitationV2])
    case sourceCitations([CodexTranscriptSourceCitationV2])
    case outputResources([CodexTranscriptOutputResourceV2])
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
    public let identifier: String
    public let kind: ThreadItemKind
    private let body: @Sendable (CodexTranscriptEventInput) -> CodexTranscriptEvent?

    public init(
        identifier: String? = nil,
        kind: ThreadItemKind,
        body: @escaping @Sendable (CodexTranscriptEventInput) -> CodexTranscriptEvent?
    ) {
        self.identifier = identifier ?? kind.rawValue
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

    /// Returns every bounded provenance arm for an assistant item. This is
    /// intentionally additive to `event(for:)`: older hosts can keep matching
    /// the narrow memory-citation event while newer hosts retain sources and
    /// generated outputs on the same answer.
    public func provenance(for item: CanonicalItem) -> CodexTranscriptProvenanceV2 {
        Self.provenance(from: item.payload)
    }

    /// Adapts one already-reduced extension fact. Hosts that receive a
    /// notification through a custom transport can use this without creating
    /// a synthetic canonical turn.
    public func event(
        forExtensionKey key: String,
        value: CodexJSONValue
    ) -> CodexTranscriptEvent? {
        Self.event(forExtensionKey: key, value: value)
    }

    /// Replays a notification through the same typed adapters used by
    /// hydrated turns.  This is deliberately a pure convenience boundary for
    /// live streams; canonical reduction still belongs to `ProtocolStateAdapter`.
    public func events(
        method: String,
        params: [String: CodexJSONValue]
    ) -> [CodexTranscriptEvent] {
        if method == "item/autoApprovalReview/started"
            || method == "item/autoApprovalReview/completed" {
            let reviewID = params.string("reviewId") ?? params.string("reviewID") ?? "review"
            let key = "autoApprovalReview:\(reviewID)"
            return Self.event(forExtensionKey: key, value: .dictionary(params)).map { [$0] } ?? []
        }
        if method == "autoApprovalReview/strictReviewRequired" {
            guard let event = Self.event(
                forExtensionKey: "autoApprovalReview:strictReviewRequired",
                value: .dictionary(params)
            ) else { return [] }
            let recovery = CodexTranscriptRecoveryNoticeV2(
                id: "autoApprovalReview:strictReviewRequired:recovery",
                kind: .turnRetry,
                message: "Auto-review stopped this turn after repeated denials. Add more context or choose a different permission mode to continue.",
                canRetry: true,
                scope: "turn",
                isTerminal: true,
                retryLabel: "Retry with context"
            )
            return [event, .recovery(recovery)]
        }
        if method == "hook/started" || method == "hook/completed" {
            let hookID = params.object("run")?.string("id") ?? params.string("id") ?? "hook"
            return Self.event(forExtensionKey: "hook:\(hookID)", value: .dictionary(params)).map { [$0] } ?? []
        }
        if method == "model/rerouted" {
            return Self.event(forExtensionKey: method, value: .dictionary(params)).map { [$0] } ?? []
        }
        if method == "turn/plan/updated" {
            let turnID = params.string("turnId") ?? "turn"
            var payload = params
            payload["cardType"] = .string("proposed-plan")
            return Self.planEvent(from: payload, completed: false, itemID: "plan:\(turnID)").map { [$0] } ?? []
        }
        if method == "item/started" || method == "item/completed" {
            guard let itemObject = params.object("item"),
                  let itemID = itemObject.string("id"),
                  let threadID = params.string("threadId"),
                  let turnID = params.string("turnId"),
                  let type = itemObject.string("type")
            else { return [] }
            let item = CanonicalItem(
                key: .init(threadID: ThreadID(threadID), turnID: TurnID(turnID), itemID: ItemID(itemID)),
                kind: ThreadItemKind(rawValue: type),
                payload: itemObject,
                authority: method == "item/completed" ? .completed : .started
            )
            return event(for: item, completed: method == "item/completed").map { [$0] } ?? []
        }
        return []
    }

    public var adapterIdentifiers: Set<String> {
        Set(adapters.values.map(\.identifier))
    }

    /// Turns store notification-backed extension facts as typed events. These
    /// extensions are canonical facts; this method only chooses their display
    /// representation and safely ignores malformed dictionaries.
    public func events(for turn: CanonicalTurn) -> [CodexTranscriptEvent] {
        var events: [CodexTranscriptEvent] = turn.extensions.keys.sorted().flatMap { key in
            guard let value = turn.extensions[key],
                  let event = Self.event(forExtensionKey: key, value: value) else { return [CodexTranscriptEvent]() }
            if key == "autoApprovalReview:strictReviewRequired" {
                let recovery = CodexTranscriptRecoveryNoticeV2(
                    id: key + ":recovery",
                    kind: .turnRetry,
                    message: "Auto-review stopped this turn after repeated denials. Add more context or choose a different permission mode to continue.",
                    canRetry: true,
                    scope: "turn",
                    isTerminal: true,
                    retryLabel: "Retry with context"
                )
                return [event, .recovery(recovery)]
            }
            return [event]
        }
        if let error = turn.error?.typedCodexErrorInfo,
           let recovery = Self.recovery(for: error, turn: turn) {
            events.append(.recovery(recovery))
        }
        return events
    }

    public func events(
        for turn: CanonicalTurn,
        thread: CanonicalThread?
    ) -> [CodexTranscriptEvent] {
        var events = events(for: turn)
        guard let thread else { return events }
        if let source = thread.metadata.forkedFromID?.rawValue {
            events.append(.notice(.init(
                id: "thread-forked-from",
                message: "Forked from chat \(Self.shortID(source))",
                kind: .fork
            )))
        }
        if let parent = thread.metadata.parentThreadID?.rawValue {
            events.append(.notice(.init(
                id: "thread-parent",
                message: "Remote task from chat \(Self.shortID(parent))",
                kind: .remoteTask
            )))
        }
        if let provider = thread.metadata.modelProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty {
            events.append(.notice(.init(id: "thread-model-provider", message: "Model provider: \(provider)", kind: .modelReroute)))
        }
        if !thread.connectedEnvironmentIDs.isEmpty {
            events.append(.notice(.init(
                id: "thread-environment",
                message: "Worktree environment connected",
                kind: .worktree
            )))
        }
        if let settings = thread.settings,
           let personality = settings.string("personality")?.codexTranscriptNonEmpty {
            events.append(.notice(.init(id: "thread-personality", message: "Personality: \(personality)", kind: .personality)))
        }
        if thread.history.isStaleAfterReconnect {
            events.append(.recovery(.init(
                id: "history-reconnect",
                kind: .historyRetry,
                message: "History is being restored after reconnect",
                canRetry: true
            )))
        }
        if thread.consistency == .uncertain {
            events.append(.recovery(.init(
                id: "thread-recovery",
                kind: .historyRetry,
                message: "Thread state is being reconciled",
                canRetry: true
            )))
        }
        return events
    }

    public static let defaultAdapters: [CodexTranscriptEventAdapter] = [
        .init(identifier: "plan", kind: .plan) { input in
            Self.planEvent(from: input.item.payload, completed: input.completed, itemID: input.item.key.itemID.rawValue)
        },
        .init(identifier: "memory-citation", kind: .agentMessage) { input in
            Self.provenanceEvent(from: input.item.payload)
        },
        .init(identifier: "user-context", kind: .userMessage) { input in
            Self.userContextEvent(from: input.item.payload)
        },
        .init(identifier: "mcp-tool-call", kind: .mcpToolCall) { input in
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
            ?? payload.string("itemType")
            ?? payload.string("kind")
            ?? payload.string("type")
        let normalizedRawKind = rawKind?.lowercased()
        let hasExplicitCardKind = [
            "todo", "todos", "todo_list", "todo-list",
            "proposed-plan", "proposed_plan", "proposedplan",
            "planimplementation", "plan_implementation", "plan-implementation", "implementation"
        ].contains(normalizedRawKind)
        let kind: CodexStructuredTranscriptCardKindV2 = switch rawKind?.lowercased() {
        case "todo", "todos", "todo_list", "todo-list": .todo
        case "planimplementation", "plan_implementation", "plan-implementation", "implementation": .planImplementation
        default: .proposedPlan
        }
        let title = payload.string("title")
            ?? payload.string("text")
            ?? payload.string("objective")
        let steps = parseSteps(
            payload.array("steps") ?? payload.array("plan") ?? payload.array("items") ?? [],
            itemID: itemID
        )
        // A legacy `plan` item containing only markdown is ordinary narrative;
        // turn-level plan updates and explicit card discriminators are handled
        // by the structured adapter. This preserves the stable legacy row ID
        // while preventing a duplicate raw plan card in hydrated history.
        if !hasExplicitCardKind, steps.isEmpty,
           payload.string("cardType") == nil,
           payload.string("itemType") == nil,
           payload.string("kind") == nil {
            return nil
        }
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
            if case .string(let title) = value,
               let title = title.trimmingCharacters(in: .whitespacesAndNewlines).codexTranscriptNonEmpty {
                return .init(id: "\(itemID):step:\(index)", title: title)
            }
            guard case .dictionary(let object) = value else { return nil }
            let title = object.string("step")
                ?? object.string("title")
                ?? object.string("text")
            guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  title.utf8.count <= 16_384
            else { return nil }
            let status = object.bool("completed") == true
                ? CodexStructuredTranscriptCardStatusV2.completed
                : cardStatus(object.string("status"), completed: false, steps: [])
            return .init(
                id: object.string("id") ?? itemID + ":step:" + String(index),
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
                return attachment(input: input, raw: value, index: index)
            }
        }
        var context: [CodexUserContextV2] = []
        if let object = payload.object("additionalContext") ?? payload.object("context") {
            context = object.keys.sorted().compactMap { key in
                let entry = object[key]
                let entryObject = entry?.object
                let value = (entryObject?.string("value") ?? entry?.stringValue)?.codexTranscriptBounded
                guard let value else { return nil }
                let rawKind = entryObject?.string("kind") ?? key
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

    static func attachment(
        input: CodexInput,
        raw: CodexJSONValue,
        index: Int
    ) -> CodexUserAttachmentV2? {
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
            return rawAttachment(raw, index: index)
        }
    }

    static func rawAttachment(_ raw: CodexJSONValue, index: Int) -> CodexUserAttachmentV2? {
        guard case .dictionary(let object) = raw,
              let rawType = object.string("type")?.lowercased()
        else { return nil }
        let value = object.string("url")
            ?? object.string("path")
            ?? object.string("file_id")
            ?? object.string("fileId")
        guard let value, !value.isEmpty else { return nil }
        let kind: CodexUserAttachmentV2.Kind
        let label: String
        switch rawType {
        case "image_url", "input_image":
            kind = .image; label = object.string("name") ?? "Image"
        case "audio_url", "input_audio", "audio":
            kind = .audio; label = object.string("name") ?? "Audio"
        case "file", "file_url", "input_file":
            kind = .file; label = object.string("name") ?? URL(fileURLWithPath: value).lastPathComponent
        case "skill":
            kind = .skill; label = object.string("name") ?? "Skill"
        case "mention":
            kind = .mention; label = object.string("name") ?? "Mention"
        default:
            return nil
        }
        return .init(
            id: "\(rawType):\(index):\(value)",
            kind: kind,
            label: label,
            value: value,
            detail: object.string("detail")
        )
    }

    static func memoryEvent(from payload: [String: CodexJSONValue]) -> CodexTranscriptEvent? {
        guard let object = payload.object("memoryCitation") ?? payload.object("memory_citation") else { return nil }
        let sourceThreads = (object.array("threadIds") ?? object.array("thread_ids"))?.compactMap(\.stringValue) ?? []
        let entries = object.array("entries")?.compactMap { value -> CodexMemoryCitationV2? in
            guard case .dictionary(let entry) = value,
                  let path = entry.string("path")?.codexTranscriptNonEmpty,
                  let start = entry.int("lineStart") ?? entry.int("line_start"),
                  let end = entry.int("lineEnd") ?? entry.int("line_end"),
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

    static func provenance(from payload: [String: CodexJSONValue]) -> CodexTranscriptProvenanceV2 {
        .init(
            memoryCitations: memoryEvent(from: payload).flatMap { event in
                guard case .memoryCitations(let values) = event else { return nil }
                return values
            } ?? [],
            sourceCitations: sourceCitations(from: payload) ?? [],
            outputResources: outputResources(from: payload) ?? []
        )
    }

    static func provenanceEvent(from payload: [String: CodexJSONValue]) -> CodexTranscriptEvent? {
        let value = provenance(from: payload)
        if !value.memoryCitations.isEmpty { return .memoryCitations(value.memoryCitations) }
        if !value.sourceCitations.isEmpty { return .sourceCitations(value.sourceCitations) }
        if !value.outputResources.isEmpty { return .outputResources(value.outputResources) }
        return nil
    }

    static func sourceCitations(from payload: [String: CodexJSONValue]) -> [CodexTranscriptSourceCitationV2]? {
        let values = payload.array("sources")
            ?? payload.array("sourceCitations")
            ?? payload.array("source_citations")
            ?? payload.object("annotations")?.array("sources")
        guard let values else { return nil }
        return values.enumerated().compactMap { index, value in
            guard case .dictionary(let object) = value,
                  let location = (object.string("url") ?? object.string("uri") ?? object.string("path"))?.codexTranscriptNonEmpty
            else { return nil }
            let title = object.string("title") ?? object.string("name") ?? location
            return .init(
                id: object.string("id") ?? "source:\(index):\(location)",
                title: title,
                location: location,
                snippet: object.string("snippet") ?? object.string("text") ?? object.string("description"),
                sourceKind: object.string("kind") ?? object.string("type") ?? "source"
            )
        }
    }

    static func outputResources(from payload: [String: CodexJSONValue]) -> [CodexTranscriptOutputResourceV2]? {
        let values = payload.array("outputResources")
            ?? payload.array("output_resources")
            ?? payload.array("resources")
        guard let values else { return nil }
        return values.enumerated().compactMap { index, value in
            guard case .dictionary(let object) = value,
                  let location = (object.string("url") ?? object.string("uri") ?? object.string("path"))?.codexTranscriptNonEmpty
            else { return nil }
            let rawKind = (object.string("kind") ?? object.string("type") ?? "resource").lowercased()
            let kind: CodexTranscriptOutputResourceV2.Kind = switch rawKind {
            case "file", "file_url", "fileurl": .file
            case "image", "image_url", "imageurl": .image
            case "audio", "audio_url", "audiourl": .audio
            case "resource", "resource_link", "resourcelink": .resource
            default: .unknown
            }
            return .init(
                id: object.string("id") ?? "output:\(index):\(location)",
                kind: kind,
                name: object.string("name")
                    ?? (location.hasPrefix("http")
                        ? (URL(string: location)?.lastPathComponent ?? "Output")
                        : (URL(fileURLWithPath: location).lastPathComponent.isEmpty
                            ? "Output" : URL(fileURLWithPath: location).lastPathComponent)),
                location: location,
                mimeType: object.string("mimeType") ?? object.string("mime_type"),
                sizeBytes: object.int("sizeBytes") ?? object.int("size_bytes"),
                isPreviewable: object.bool("previewable") ?? (kind == .image || kind == .audio)
            )
        }
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
        // MCP Apps are represented by a resource URI on the tool item even
        // when the result has no eager content. Keep a typed widget placeholder
        // so the host can load its sandbox only when the row is revealed.
        if let uri = payload.string("mcpAppResourceUri")
            ?? payload.object("appContext")?.string("resourceUri") {
            blocks.append(.widget(
                id: payload.string("id"),
                uri: uri,
                payload: [:]
            ))
        }
        return blocks.isEmpty ? nil : .mcpContent(blocks)
    }

    static func event(forExtensionKey key: String, value: CodexJSONValue) -> CodexTranscriptEvent? {
        let normalizedKey = key
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "/", with: "")
            .lowercased()
        if key == "autoApprovalReview:strictReviewRequired", let object = value.object {
            return .approvalReview(.init(
                id: key,
                title: "Turn ended by Auto-review",
                status: .inProgress,
                rationale: object.string("reason")
                    ?? object.string("message")
                    ?? "Auto-review stopped this turn after repeated denials. Add more context or choose a different permission mode to continue.",
                riskLevel: object.string("riskLevel"),
                targetItemID: object.string("targetItemId") ?? object.string("itemId"),
                targetSummary: object.string("target"),
                interruptedTurn: true
            ))
        }
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
                targetItemID: object.string("targetItemId") ?? review.string("targetItemId"),
                targetSummary: review.string("command") ?? review.string("file")
            ))
        }
        if key.hasPrefix("hook:"), let object = value.object {
            let run = object.object("run") ?? object
            let status = workStatus(run.string("status"))
            let rawEntries = run.array("entries") ?? []
            let entries = rawEntries.prefix(128).compactMap { entry -> String? in
                guard case .dictionary(let value) = entry else { return nil }
                return value.string("text")?.codexTranscriptBounded
            }
            return .hookActivity(.init(
                id: run.string("id") ?? key,
                eventName: run.string("eventName") ?? "Hook",
                handler: run.string("handlerType") ?? "",
                status: status,
                durationMs: run.int("durationMs"),
                entries: entries,
                statusMessage: run.string("statusMessage")?.codexTranscriptBounded,
                outputIsTruncated: rawEntries.count > entries.count || rawEntries.count > 128
            ))
        }
        if (key == "model/rerouted" || normalizedKey == "modelrerouted"), let object = value.object {
            let from = object.string("fromModel") ?? "previous model"
            let to = object.string("toModel") ?? "another model"
            let reason = object.string("reason")
            let detail = reason.map { "Reason: \($0)" }
            let highRisk = reason?.localizedCaseInsensitiveContains("highRisk") == true
                || reason?.localizedCaseInsensitiveContains("cyber") == true
            return .notice(.init(
                id: key,
                message: "Model changed from \(from) to \(to)",
                kind: .modelReroute,
                detail: detail,
                isBlocking: highRisk,
                actionLabel: highRisk ? "Open risk explanation" : nil
            ))
        }
        if (key == "model/safetyBuffering/updated" || normalizedKey == "modelsafetybufferingupdated"), let object = value.object,
           object.bool("showBufferingUi") == true {
            return .notice(.init(
                id: key,
                message: "Model is buffering the response",
                kind: .modelReroute,
                detail: object.array("reasons")?.compactMap(\.stringValue).joined(separator: ", ")
            ))
        }
        if (key == "model/verification" || normalizedKey == "modelverification"), let object = value.object {
            let values = object.array("verifications")?.compactMap(\.stringValue) ?? []
            let detail = values.isEmpty ? nil : values.joined(separator: ", ")
            return .notice(.init(
                id: key,
                message: "Model verification updated",
                kind: .modelReroute,
                detail: detail,
                isBlocking: values.contains { $0.localizedCaseInsensitiveContains("cyber") },
                actionLabel: values.contains { $0.localizedCaseInsensitiveContains("cyber") } ? "Open risk explanation" : nil
            ))
        }
        if (key == "personality" || normalizedKey == "personalitychanged"), let personality = value.stringValue?.codexTranscriptNonEmpty {
            return .notice(.init(id: key, message: "Personality: \(personality)", kind: .personality))
        }
        if (key == "forkedFromId" || normalizedKey == "forkedfromconversation"), let source = value.stringValue?.codexTranscriptNonEmpty {
            return .notice(.init(id: key, message: "Forked from chat \(shortID(source))", kind: .fork))
        }
        if (key == "worktree" || normalizedKey == "worktreeinit"), let object = value.object {
            let name = object.string("name") ?? object.string("path")
            let status = object.string("status")
            return name.map { value in
                let message = status.map { "Worktree \($0): \(value)" } ?? "Working in \(value)"
                return .notice(.init(id: key, message: message, kind: .worktree))
            }
        }
        if (key == "remoteTask" || normalizedKey == "remotetaskcreated"), let object = value.object {
            let state = object.string("status") ?? "connected"
            let target = object.string("threadId") ?? object.string("threadID")
            return .notice(.init(
                id: key,
                message: "Remote task \(state)",
                kind: .remoteTask,
                target: target.map { .init(hostID: object.string("hostId"), threadID: $0) }
            ))
        }
        if key == "remoteTask", let state = value.stringValue?.codexTranscriptNonEmpty {
            return .notice(.init(id: key, message: "Remote task \(state)", kind: .remoteTask))
        }
        if (key == "historyRetry" || normalizedKey == "historyretry"), value == .bool(true) {
            return .recovery(.init(id: key, kind: .historyRetry, message: "Retrying history", canRetry: true, scope: "history", retryLabel: "Retry history"))
        }
        // The item-backed representation already emits the stable
        // `context-compacted-<turn>` notice. Do not add a second entry when the
        // live extension and hydrated item are reconciled.
        if key == "contextCompacted" { return nil }
        if (key == "lastErrorWillRetry" || normalizedKey == "lasterrorwillretry"), value == .bool(true) {
            return .recovery(.init(id: key, kind: .turnRetry, message: "Retrying this turn", canRetry: true, scope: "turn", retryLabel: "Retry turn"))
        }
        if key == "auto-review-interruption-warning" || normalizedKey == "autoreviewinterruptionwarning" {
            let detail = value.object?.string("message") ?? value.stringValue
                ?? "Auto-review stopped this turn after repeated denials. Add more context or choose a different permission mode to continue."
            return .recovery(.init(
                id: key,
                kind: .turnRetry,
                message: detail,
                canRetry: true,
                scope: "turn",
                isTerminal: true,
                retryLabel: "Retry with context"
            ))
        }
        if key == "writerConflict" || normalizedKey == "writerconflict" {
            let detail = (value.object?.string("message") ?? value.stringValue)?.codexTranscriptBounded
            return .recovery(.init(
                id: key,
                kind: .writerConflict,
                message: detail.map { "Another writer changed this thread: \($0)" } ?? "Another writer changed this thread",
                canRetry: true,
                scope: "thread",
                retryLabel: "Verify"
            ))
        }
        if key == "threadRollback" || key == "rollback" || normalizedKey == "threadrollback" {
            let detail = (value.object?.string("message") ?? value.stringValue)?.codexTranscriptBounded
            return .recovery(.init(
                id: key,
                kind: .rollback,
                message: detail.map { "Rollback: \($0)" } ?? "Rollback applied",
                canRetry: detail != nil,
                scope: "thread",
                retryLabel: detail != nil ? "Retry after confirmation" : nil
            ))
        }
        return nil
    }

    static func recovery(
        for error: CodexTurnErrorInfo,
        turn: CanonicalTurn
    ) -> CodexTranscriptRecoveryNoticeV2? {
        let id = "turn-recovery:\(turn.key.turnID.rawValue)"
        let attempt = turn.extensions.int("attempt") ?? turn.extensions.int("retryAttempt")
        let maximumAttempts = turn.extensions.int("maximumAttempts") ?? turn.extensions.int("maxAttempts")
        let countdown = turn.extensions.int("countdownSeconds") ?? turn.extensions.int("retryAfterSeconds")
        let scope = "turn:\(turn.key.turnID.rawValue)"
        switch error {
        case .serverOverloaded:
            return .init(
                id: id,
                kind: .overload,
                message: "The service is busy; retrying this turn",
                canRetry: true,
                scope: scope,
                attempt: attempt,
                maximumAttempts: maximumAttempts,
                countdownSeconds: countdown,
                isTerminal: maximumAttempts.map { (attempt ?? 0) >= $0 } ?? false,
                retryLabel: "Retry turn"
            )
        case .responseStreamConnectionFailed, .responseStreamDisconnected, .httpConnectionFailed:
            return .init(
                id: id,
                kind: .streamFailure,
                message: "Response stream disconnected; reconnecting",
                canRetry: true,
                scope: scope,
                attempt: attempt,
                maximumAttempts: maximumAttempts,
                countdownSeconds: countdown,
                retryLabel: "Retry turn"
            )
        case .responseTooManyFailedAttempts:
            return .init(
                id: id,
                kind: .historyRetry,
                message: "The response could not be recovered automatically",
                canRetry: true,
                scope: scope,
                attempt: attempt,
                maximumAttempts: maximumAttempts,
                isTerminal: true,
                retryLabel: "Retry turn"
            )
        case .threadRollbackFailed:
            return .init(
                id: id,
                kind: .rollback,
                message: "Rollback was not applied; the thread remains unchanged",
                canRetry: true,
                scope: "thread",
                isTerminal: true,
                retryLabel: "Retry after confirmation"
            )
        case .contextWindowExceeded:
            return .init(
                id: id,
                kind: .historyRetry,
                message: "Context limit reached; retry after compacting history",
                canRetry: true,
                scope: "history",
                retryLabel: "Retry after compacting"
            )
        case .activeTurnNotSteerable:
            return .init(
                id: id,
                kind: .turnRetry,
                message: "This turn cannot accept another steer yet",
                canRetry: true,
                scope: scope,
                retryLabel: "Retry turn"
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
        case "failed", "error", "blocked", "stopped": .failed
        case "declined": .declined
        case .some(let value): .unknown(value)
        case nil: .completed
        }
    }

    static func shortID(_ value: String) -> String {
        String((value.split(separator: "-").last.map(String.init) ?? value).prefix(8))
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
            // Keep the call's ordering and a safe explanation without exposing
            // arbitrary JSON. Malformed non-object values still fail closed.
            return .unknown(type: type)
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
        let prefix = value.utf8.prefix(CodexMCPContentBlockAdapter.maximumTextBytes)
        var result = String(decoding: prefix, as: UTF8.self)
        result += "\n… content truncated"
        return result
    }
}
