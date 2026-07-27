import CodexCore
import Foundation

/// Pure canonical-state to transcript projection.
///
/// The projector owns no cache or reducer truth. Callers may retain the returned
/// presentation and pass it back for incremental work, or omit it to rebuild the
/// exact same presentation from canonical state.
public struct CodexCanonicalTranscriptProjector: Sendable {
    private let itemPresentationPolicy: CodexTranscriptItemPresentationPolicyV2?

    public init(
        itemPresentationPolicy: CodexTranscriptItemPresentationPolicyV2? = nil
    ) {
        self.itemPresentationPolicy = itemPresentationPolicy
    }

    public func rebuild(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        requests: [CodexPendingInteractionSnapshot] = [],
        requestRevision: UInt64 = 0
    ) -> CodexCanonicalTranscriptProjectionResult {
        // A nil previous value cannot produce a stale-revision error.
        try! project(
            snapshot: snapshot,
            threadID: threadID,
            requests: requests,
            requestRevision: requestRevision,
            previous: nil
        )
    }

    public func project(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        requests: [CodexPendingInteractionSnapshot] = [],
        requestRevision: UInt64 = 0,
        previous: CodexCanonicalTranscriptPresentation?
    ) throws -> CodexCanonicalTranscriptProjectionResult {
        // Canonical turn revisions aggregate every projected child item and
        // submission change. Comparing them with the previous presentation makes
        // incremental projection independent of retained change-set keys.
        if let previous,
           previous.threadID == threadID,
           snapshot.revision < previous.sourceRevision {
            throw CodexCanonicalTranscriptProjectionError.staleSourceRevision(
                previous: previous.sourceRevision,
                incoming: snapshot.revision
            )
        }

        let effectiveRequestRevision = requestRevision
        if let previous,
           previous.threadID == threadID,
           effectiveRequestRevision < previous.requestSourceRevision {
            throw CodexCanonicalTranscriptProjectionError.staleRequestRevision(
                previous: previous.requestSourceRevision,
                incoming: effectiveRequestRevision
            )
        }

        let fullRebuild = previous?.threadID != threadID
        let old = fullRebuild ? nil : previous
        let intents = unresolvedIntents(snapshot: snapshot, threadID: threadID)
        let intentByTurn = intentsByTurn(intents)
        let echoedIntentIDs = echoedIntentIDs(snapshot: snapshot, threadID: threadID)
        let visibleIntents = intents.filter { !echoedIntentIDs.contains($0.id) }
        let visibleIntentByTurn = intentsByTurn(visibleIntents)
        let order = projectedTurnOrder(
            snapshot: snapshot,
            threadID: threadID,
            intents: visibleIntents
        )
        let pendingRequests = requestPresentations(requests, threadID: threadID)

        let oldIDs = Set(old?.turnOrder ?? [])
        let newIDs = Set(order)
        let removed = oldIDs.subtracting(newIDs)
        var dirtyIDs: Set<TurnID> = []

        if fullRebuild {
            dirtyIDs.formUnion(order)
        } else {
            dirtyIDs.formUnion(newIDs.subtracting(oldIDs))
            for turnID in order {
                let prior = old?.sourceTurnRevisions[turnID] ?? .zero
                let key = TurnKey(threadID: threadID, turnID: turnID)
                if let revision = snapshot.turns[key]?.lastChangedRevision, prior < revision {
                    dirtyIDs.insert(turnID)
                }
                if (intentByTurn[turnID] ?? []).contains(where: { prior < $0.lastChangedRevision }) {
                    dirtyIDs.insert(turnID)
                }
            }
        }

        dirtyIDs.formUnion(requestDirtyTurns(previous: old?.pendingRequests ?? [], current: pendingRequests))
        dirtyIDs.formUnion(removed)

        let sourceRevisions = turnSourceRevisions(
            snapshot: snapshot,
            threadID: threadID,
            order: order,
            intentsByTurn: intentByTurn,
            recomputing: dirtyIDs,
            previous: old?.sourceTurnRevisions ?? [:]
        )

        var turnsByID = old?.turnsByID ?? [:]
        for removedID in removed {
            turnsByID.removeValue(forKey: removedID)
        }

        var upsertedTurns: [CodexTurnV2] = []
        for turnID in order where dirtyIDs.contains(turnID) {
            let key = TurnKey(threadID: threadID, turnID: turnID)
            let turn = snapshot.turns[key]
            let items = turn.map { canonicalTurn in
                canonicalTurn.itemOrder.compactMap { itemID in
                    snapshot.items[ItemKey(threadID: threadID, turnID: turnID, itemID: itemID)]
                }
            } ?? []
            guard let projected = projectTurn(
                turnID: turnID,
                canonical: turn,
                items: items,
                intents: visibleIntentByTurn[turnID] ?? []
            ) else {
                turnsByID.removeValue(forKey: turnID)
                continue
            }
            turnsByID[turnID] = projected
            upsertedTurns.append(projected)
        }

        // A dirty hint can name a missing turn. Never retain it just because an
        // earlier presentation happened to contain that identifier.
        for turnID in dirtyIDs where !newIDs.contains(turnID) {
            turnsByID.removeValue(forKey: turnID)
        }

        let presentation = CodexCanonicalTranscriptPresentation(
            threadID: threadID,
            sourceRevision: snapshot.revision,
            requestSourceRevision: effectiveRequestRevision,
            turnOrder: order,
            turnsByID: turnsByID,
            sourceTurnRevisions: sourceRevisions,
            pendingRequests: pendingRequests
        )
        let structureChanged = fullRebuild || old?.turnOrder != order
        let update = CodexCanonicalTranscriptRenderUpdate(
            threadID: threadID,
            sourceRevision: snapshot.revision,
            requestSourceRevision: effectiveRequestRevision,
            turnOrder: structureChanged ? order : nil,
            upsertedTurns: upsertedTurns,
            removedTurnIDs: removed,
            dirtyTurnIDs: dirtyIDs,
            pendingRequests: pendingRequests,
            isFullRebuild: fullRebuild
        )
        return .init(presentation: presentation, update: update)
    }
}

// MARK: - Source selection

private extension CodexCanonicalTranscriptProjector {
    func unresolvedIntents(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID
    ) -> [SubmissionIntent] {
        snapshot.submissionIntents.values
            .filter { intent in
                guard intent.threadID == threadID else { return false }
                if case .reconciled = intent.state { return false }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.localOrdinal != rhs.localOrdinal { return lhs.localOrdinal < rhs.localOrdinal }
                return lhs.id < rhs.id
            }
    }

    func intentsByTurn(_ intents: [SubmissionIntent]) -> [TurnID: [SubmissionIntent]] {
        Dictionary(grouping: intents) { intent in
            intent.expectedTurnID ?? provisionalTurnID(intent.id)
        }
    }

    func echoedIntentIDs(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID
    ) -> Set<SubmissionIntentID> {
        var result: Set<SubmissionIntentID> = []
        for turn in snapshot.turns(in: threadID) {
            for itemID in turn.itemOrder {
                let key = ItemKey(threadID: threadID, turnID: turn.key.turnID, itemID: itemID)
                guard let item = snapshot.items[key],
                      item.kind == .userMessage,
                      let intentID = item.clientUserMessageID else { continue }
                result.insert(intentID)
            }
        }
        return result
    }

    func projectedTurnOrder(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        intents: [SubmissionIntent]
    ) -> [TurnID] {
        var result: [TurnID] = []
        var seen: Set<TurnID> = []
        if let thread = snapshot.threads[threadID] {
            for turnID in thread.turnOrder where snapshot.turns[TurnKey(threadID: threadID, turnID: turnID)] != nil {
                if seen.insert(turnID).inserted { result.append(turnID) }
            }
        }
        for intent in intents {
            let turnID = intent.expectedTurnID ?? provisionalTurnID(intent.id)
            if seen.insert(turnID).inserted { result.append(turnID) }
        }
        return result
    }

    func provisionalTurnID(_ intentID: SubmissionIntentID) -> TurnID {
        TurnID("local-\(intentID.rawValue)")
    }

    func turnSourceRevisions(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        order: [TurnID],
        intentsByTurn: [TurnID: [SubmissionIntent]],
        recomputing dirtyTurnIDs: Set<TurnID>,
        previous: [TurnID: StateRevision]
    ) -> [TurnID: StateRevision] {
        var result: [TurnID: StateRevision] = [:]
        for turnID in order {
            if !dirtyTurnIDs.contains(turnID), let previousRevision = previous[turnID] {
                result[turnID] = previousRevision
                continue
            }
            let turnKey = TurnKey(threadID: threadID, turnID: turnID)
            var revision = snapshot.turns[turnKey]?.lastChangedRevision ?? .zero
            if let turn = snapshot.turns[turnKey] {
                for itemID in turn.itemOrder {
                    let key = ItemKey(threadID: threadID, turnID: turnID, itemID: itemID)
                    if let itemRevision = snapshot.items[key]?.lastChangedRevision,
                       revision < itemRevision {
                        revision = itemRevision
                    }
                }
            }
            for intent in intentsByTurn[turnID] ?? [] where revision < intent.lastChangedRevision {
                revision = intent.lastChangedRevision
            }
            result[turnID] = revision
        }
        return result
    }

    func requestPresentations(
        _ requests: [CodexPendingInteractionSnapshot],
        threadID: ThreadID
    ) -> [CodexTranscriptRequestPresentation] {
        let pending: [CodexPendingInteractionSnapshot] = requests.filter { request in
            request.scope.threadID.map { ThreadID($0) } == threadID
        }
        let sorted: [CodexPendingInteractionSnapshot] = pending.sorted { lhs, rhs in
                if lhs.arrivalOrdinal != rhs.arrivalOrdinal {
                    return lhs.arrivalOrdinal < rhs.arrivalOrdinal
                }
                if lhs.key.connectionEpoch != rhs.key.connectionEpoch {
                    return lhs.key.connectionEpoch < rhs.key.connectionEpoch
                }
                return lhs.key.requestID.description < rhs.key.requestID.description
        }
        return sorted.map { request -> CodexTranscriptRequestPresentation in
            let turnID = request.scope.turnID.map { TurnID($0) }
            let itemID = request.scope.itemID.map { ItemID($0) }
            return CodexTranscriptRequestPresentation(
                id: request.key,
                kind: request.kind,
                turnID: turnID,
                itemID: itemID,
                summary: requestSummary(request.kind)
            )
        }
    }

    func requestSummary(_ kind: CodexServerRequestKind) -> String {
        switch kind {
        case .commandApproval, .legacyExecCommandApproval: "Run command"
        case .fileChangeApproval, .legacyApplyPatchApproval: "Edit files"
        case .permissionsApproval: "Grant permissions"
        case .userInput: "Answer a question"
        case .mcpElicitation: "Respond to an app"
        case .dynamicToolCall: "Run a tool"
        case .tokenRefresh: "Refresh authentication"
        case .attestation: "Verify this device"
        case .currentTime: "Read current time"
        case .unknown: "Respond to Codex"
        }
    }

    func requestDirtyTurns(
        previous: [CodexTranscriptRequestPresentation],
        current: [CodexTranscriptRequestPresentation]
    ) -> Set<TurnID> {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let changedIDs = Set(previousByID.keys)
            .union(currentByID.keys)
            .filter { previousByID[$0] != currentByID[$0] }
        return Set(changedIDs.flatMap { id in
            [previousByID[id]?.turnID, currentByID[id]?.turnID].compactMap { $0 }
        })
    }
}

// MARK: - Turn projection

private extension CodexCanonicalTranscriptProjector {
    func projectTurn(
        turnID: TurnID,
        canonical: CanonicalTurn?,
        items: [CanonicalItem],
        intents: [SubmissionIntent]
    ) -> CodexTurnV2? {
        guard canonical != nil || !intents.isEmpty else { return nil }

        var turn = CodexTurnV2(
            id: turnID.rawValue,
            status: projectStatus(canonical: canonical, fallbackIntent: intents.first)
        )
        var activeReasoning: [(itemID: String, text: String)] = []
        var hasContextCompaction = canonical?.extensions["contextCompacted"] == .bool(true)
        var conversationSegments: [CodexTurnConversationSegmentV2] = []
        var currentSteeredMessage: CodexUserMessageV2?

        for item in items {
            let completed = item.authority == .completed || canonical?.status.isTerminal == true
            if let itemPresentationPolicy {
                let context = CodexTranscriptItemContextV2(
                    threadID: item.key.threadID,
                    turnID: item.key.turnID,
                    itemID: item.key.itemID,
                    kind: item.kind,
                    payload: item.payload,
                    status: workStatus(item, completed: completed)
                )
                switch itemPresentationPolicy.presentation(for: context) {
                case .standard:
                    break
                case .hidden:
                    continue
                case .inlineActivity(let activity):
                    appendInlineActivity(
                        activity,
                        segments: &conversationSegments,
                        to: &turn
                    )
                    continue
                }
            }
            switch item.kind {
            case .userMessage:
                guard let message = userMessage(item) else { continue }
                if turn.userMessage == nil {
                    turn.userMessage = message
                } else {
                    sealConversationSegment(
                        turn: &turn,
                        steeredMessage: &currentSteeredMessage,
                        segments: &conversationSegments,
                        closeWork: true
                    )
                    turn.steeredMessages.append(message)
                    currentSteeredMessage = message
                }
            case .hookPrompt:
                break
            case .agentMessage:
                appendAgent(item, completed: completed, to: &turn)
            case .plan:
                appendPlan(item, completed: completed, to: &turn)
            case .reasoning:
                if !completed {
                    let text = reasoningText(item)
                    activeReasoning.append((item.key.itemID.rawValue, text.isEmpty ? "Thinking" : text))
                }
            case .dynamicToolCall:
                appendProductTool(item, completed: completed, to: &turn)
            case .enteredReviewMode:
                appendNotice(id: item.key.itemID, message: "Entered review mode", to: &turn)
            case .exitedReviewMode:
                appendNotice(id: item.key.itemID, message: "Exited review mode", to: &turn)
            case .contextCompaction:
                hasContextCompaction = true
            case .imageView:
                appendNotice(id: item.key.itemID, message: "Viewed an image", to: &turn)
            case .sleep:
                appendNotice(id: item.key.itemID, message: "Waiting", to: &turn)
            case .commandExecution, .fileChange, .mcpToolCall, .collabAgentToolCall,
                    .subAgentActivity, .webSearch, .imageGeneration:
                for row in makeWorkRows(item, completed: completed) {
                    appendWorkRow(row, to: &turn)
                }
            case .unknown:
                appendNotice(id: item.key.itemID, message: "Activity", to: &turn)
            }
        }

        // Live `thread/compacted` has no item identity, while hydrated history
        // may contain a context-compaction item. Project both representations
        // through one stable turn-scoped row so reconnect cannot duplicate it.
        if hasContextCompaction {
            appendNotice(
                id: ItemID("context-compacted-\(turnID.rawValue)"),
                message: "Compacted context",
                to: &turn
            )
        }

        var remainingIntents = intents[...]
        if turn.userMessage == nil, let intent = remainingIntents.first {
            turn.userMessage = optimisticUserMessage(intent)
            appendIntentState(intent, to: &turn)
            remainingIntents = remainingIntents.dropFirst()
        }
        for intent in remainingIntents {
            sealConversationSegment(
                turn: &turn,
                steeredMessage: &currentSteeredMessage,
                segments: &conversationSegments,
                closeWork: true
            )
            let message = optimisticUserMessage(intent)
            turn.steeredMessages.append(message)
            currentSteeredMessage = message
            appendIntentState(intent, to: &turn)
        }

        sealConversationSegment(
            turn: &turn,
            steeredMessage: &currentSteeredMessage,
            segments: &conversationSegments,
            closeWork: false
        )
        turn.conversationSegments = conversationSegments
        turn.narrative = conversationSegments.flatMap(\.narrative)

        if canonical?.status.isTerminal == true {
            finishPresentation(&turn)
        } else if let reasoning = activeReasoning.last {
            turn.liveTail = reasoning.text
        } else {
            // Tool activity already owns one stable row inside the narrative.
            // A second derived tail duplicates the same work and diverges from
            // the official presentation. Only model-authored reasoning
            // summaries use the separate quiet live-tail line.
            turn.liveTail = nil
        }
        return turn
    }

    func projectStatus(
        canonical: CanonicalTurn?,
        fallbackIntent: SubmissionIntent?
    ) -> CodexTurnStatusV2 {
        if let canonical {
            switch canonical.status {
            case .inProgress, .unknown:
                return .working(since: canonical.startedAt?.rawValue)
            case .completed:
                return .done(durationMs: turnDuration(canonical))
            case .interrupted:
                return .failed(message: canonical.error?.message ?? "Turn interrupted")
            case .failed:
                return .failed(message: canonical.error?.message ?? "Turn failed")
            }
        }
        guard let fallbackIntent else { return .working(since: nil) }
        switch fallbackIntent.state {
        case .failed(let message): return .failed(message: message)
        case .pending, .reconciled, .indeterminate: return .working(since: nil)
        }
    }

    func userMessage(_ item: CanonicalItem) -> CodexUserMessageV2? {
        let clientID = item.clientUserMessageID?.rawValue ?? item.payload.string("clientId")
        let rawText = item.payload.textContent
        guard !isRealtimeDelegationEnvelope(rawText) else { return nil }
        let decoded = CodexFileReferencePromptCodec.decode(rawText)
        return CodexUserMessageV2(
            id: item.key.itemID.rawValue,
            clientID: clientID,
            text: decoded?.request ?? rawText,
            rawText: rawText,
            referencedFiles: decoded?.files ?? [],
            isOptimistic: false
        )
    }

    func isRealtimeDelegationEnvelope(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("<realtime_delegation")
    }

    func optimisticUserMessage(_ intent: SubmissionIntent) -> CodexUserMessageV2 {
        let rawText = inputText(intent.input)
        let decoded = CodexFileReferencePromptCodec.decode(rawText)
        return CodexUserMessageV2(
            id: "local-\(intent.id.rawValue)",
            clientID: intent.id.rawValue,
            text: decoded?.request ?? rawText,
            rawText: rawText,
            referencedFiles: decoded?.files ?? [],
            isOptimistic: true
        )
    }

    func inputText(_ input: [CodexJSONValue]) -> String {
        input.compactMap { value -> String? in
            if case .string(let text) = value { return text }
            guard let object = value.object else { return nil }
            return object.string("text") ?? object.string("content")
        }.joined()
    }

    func appendIntentState(_ intent: SubmissionIntent, to turn: inout CodexTurnV2) {
        let message: String?
        switch intent.state {
        case .indeterminate(let detail): message = detail ?? "Delivery status unknown"
        case .failed(let detail): message = detail
        case .pending, .reconciled: message = nil
        }
        guard let message else { return }
        turn.narrative.append(.notice(.init(id: "intent-\(intent.id.rawValue)-status", message: message)))
    }

    func sealConversationSegment(
        turn: inout CodexTurnV2,
        steeredMessage: inout CodexUserMessageV2?,
        segments: inout [CodexTurnConversationSegmentV2],
        closeWork: Bool
    ) {
        if closeWork {
            closeWorkGroup(&turn)
        }
        let segmentID = steeredMessage.map {
            "\(turn.id):steer:\($0.clientID ?? $0.id)"
        } ?? "\(turn.id):initial"
        segments.append(.init(
            id: segmentID,
            steeredMessage: steeredMessage,
            narrative: turn.narrative
        ))
        turn.narrative.removeAll(keepingCapacity: true)
        steeredMessage = nil
    }

    func appendAgent(_ item: CanonicalItem, completed: Bool, to turn: inout CodexTurnV2) {
        let id = item.key.itemID.rawValue
        let text = completed
            ? (item.payload.string("text") ?? "")
            : (item.payload.string("text") ?? "") + item.liveOverlay.agentMessage.joined()
        let message = CodexAssistantTextV2(id: id, text: text, isStreaming: !completed)
        switch item.payload.string("phase") {
        case "commentary":
            closeWorkGroup(&turn)
            upsertNarrative(.prose(message), to: &turn)
        case "final_answer":
            turn.finalAnswer = message
        default:
            if let previous = turn.finalAnswer, previous.id != id {
                turn.narrative.append(.prose(previous))
            }
            turn.finalAnswer = message
        }
    }

    func appendPlan(_ item: CanonicalItem, completed: Bool, to turn: inout CodexTurnV2) {
        let base = item.payload.string("text") ?? ""
        let text = completed ? base : base + item.liveOverlay.plan.joined()
        guard !text.isEmpty else { return }
        closeWorkGroup(&turn)
        upsertNarrative(
            .prose(.init(id: item.key.itemID.rawValue, text: text, isStreaming: !completed)),
            to: &turn
        )
    }

    func reasoningText(_ item: CanonicalItem) -> String {
        var values = item.payload.stringArrayText("summary")
        for index in item.liveOverlay.reasoningSummary.keys.sorted() {
            values += item.liveOverlay.reasoningSummary[index]?.joined() ?? ""
        }
        return values.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func appendProductTool(_ item: CanonicalItem, completed: Bool, to turn: inout CodexTurnV2) {
        closeWorkGroup(&turn)
        let value = CodexProductToolCallV2(
            id: item.key.itemID.rawValue,
            tool: item.payload.string("tool") ?? "Tool",
            namespace: item.payload.string("namespace"),
            arguments: item.payload["arguments"],
            status: workStatus(item, completed: completed),
            contentItems: item.payload.array("contentItems") ?? [],
            success: item.payload.bool("success")
        )
        upsertNarrative(.productToolCall(value), to: &turn)
    }

    func appendNotice(id: ItemID, message: String, to turn: inout CodexTurnV2) {
        closeWorkGroup(&turn)
        upsertNarrative(.notice(.init(id: id.rawValue, message: message)), to: &turn)
    }

    func appendInlineActivity(
        _ activity: CodexInlineActivityV2,
        segments: inout [CodexTurnConversationSegmentV2],
        to turn: inout CodexTurnV2
    ) {
        closeWorkGroup(&turn)
        for index in segments.indices {
            segments[index].narrative.removeAll { entry in
                guard case .inlineActivity(let existing) = entry else { return false }
                return existing.id == activity.id
            }
        }
        upsertNarrative(.inlineActivity(activity), to: &turn)
    }

    func upsertNarrative(_ entry: CodexNarrativeEntry, to turn: inout CodexTurnV2) {
        if let index = turn.narrative.firstIndex(where: { $0.id == entry.id }) {
            turn.narrative[index] = entry
        } else {
            turn.narrative.append(entry)
        }
    }

    func finishPresentation(_ turn: inout CodexTurnV2) {
        turn.liveTail = nil
        turn.finalAnswer?.isStreaming = false
        finishNarrative(&turn.narrative)
        for index in turn.conversationSegments.indices {
            finishNarrative(&turn.conversationSegments[index].narrative)
        }
    }

    func finishNarrative(_ narrative: inout [CodexNarrativeEntry]) {
        for index in narrative.indices {
            switch narrative[index] {
            case .prose(var prose):
                prose.isStreaming = false
                narrative[index] = .prose(prose)
            case .workGroup(var group):
                group.isLive = false
                narrative[index] = .workGroup(group)
            case .inlineActivity(var activity):
                if activity.status == .inProgress {
                    activity.status = .completed
                    narrative[index] = .inlineActivity(activity)
                }
            case .productToolCall, .notice:
                break
            }
        }
    }

}

// MARK: - Work grammar

private extension CodexCanonicalTranscriptProjector {
    func makeWorkRows(_ item: CanonicalItem, completed: Bool) -> [CodexWorkRowV2] {
        let id = item.key.itemID.rawValue
        let state = workStatus(item, completed: completed)
        switch item.kind {
        case .commandExecution:
            let parentCommand = item.payload.string("command") ?? "Command"
            let baseOutput = item.payload.string("aggregatedOutput") ?? ""
            let output = completed ? baseOutput : baseOutput + item.liveOverlay.commandOutput.joined()
            let actions = commandActions(item.payload, fallbackCommand: parentCommand)
            return actions.enumerated().map { index, action in
                .command(.init(
                    id: actions.count > 1 ? "\(id):\(index)" : id,
                    command: action.command,
                    label: commandLabel(action, inProgress: state == .inProgress),
                    action: action.category,
                    status: state,
                    targets: action.target.map { [$0] } ?? [],
                    exitCode: item.payload.int("exitCode"),
                    durationMs: itemDuration(item),
                    output: output.isEmpty ? nil : output
                ))
            }
        case .fileChange:
            let files = item.payload.array("changes")?.compactMap { $0.object?.string("path") } ?? []
            return [.fileChange(.init(
                id: id,
                files: files,
                status: state,
                durationMs: itemDuration(item),
                diff: item.payload.string("diff")
            ))]
        case .mcpToolCall:
            let app = item.payload.object("appContext")?.string("appName")
                ?? item.payload.string("server")
                ?? "Tool"
            return [.mcpToolCall(.init(
                id: id,
                appName: app,
                server: item.payload.string("server") ?? app,
                tool: item.payload.string("tool") ?? "Tool",
                status: state,
                durationMs: itemDuration(item),
                errorFirstLine: state == .failed ? mcpError(item.payload) : nil,
                arguments: item.payload["arguments"],
                result: item.payload["result"]
            ))]
        case .webSearch:
            guard let query = item.payload.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else { return [] }
            return [.webSearch(.init(id: id, query: query, status: state))]
        case .collabAgentToolCall:
            return collabToolRows(item, fallbackState: state).map(CodexWorkRowV2.collabAgent)
        case .subAgentActivity:
            guard let row = subagentActivityRow(item, state: state) else { return [] }
            return [.collabAgent(row)]
        case .imageGeneration:
            return [.other(.init(id: id, label: "Generating an image", status: state))]
        default:
            return []
        }
    }

    func workStatus(_ item: CanonicalItem, completed: Bool) -> CodexWorkItemStatusV2 {
        if item.payload.string("status") == "failed"
            || item.payload.int("exitCode").map({ $0 != 0 }) == true {
            return .failed
        }
        return completed ? .completed : .inProgress
    }

    struct ProjectedCommandAction {
        var category: CodexWorkCategoryV2
        var command: String
        var target: String?
        var query: String?
        var path: String?
    }

    func commandActions(
        _ item: [String: CodexJSONValue],
        fallbackCommand: String
    ) -> [ProjectedCommandAction] {
        let actions = (item.array("commandActions") ?? []).compactMap(\.object).map { action in
            let type = action.string("type")?.lowercased()
            let command = action.string("command") ?? fallbackCommand
            switch type {
            case "read", "fileread":
                let path = action.string("path")
                let name = action.string("name")
                    ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
                let skill = skillDisplayName(name: name, path: path)
                return ProjectedCommandAction(
                    category: skill == nil ? .read : .loadedTool,
                    command: command,
                    target: skill ?? name,
                    path: path
                )
            case "listfiles", "list":
                return ProjectedCommandAction(
                    category: .list,
                    command: command,
                    path: action.string("path")
                )
            case "search", "searchfiles":
                return ProjectedCommandAction(
                    category: .search,
                    command: command,
                    query: action.string("query"),
                    path: action.string("path")
                )
            default:
                return ProjectedCommandAction(category: .run, command: command)
            }
        }
        return actions.isEmpty
            ? [ProjectedCommandAction(category: .run, command: fallbackCommand)]
            : actions
    }

    func skillDisplayName(name: String?, path: String?) -> String? {
        guard name?.lowercased() == "skill.md" || path?.lowercased().hasSuffix("/skill.md") == true,
              let path else { return nil }
        let skillName = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
        guard !skillName.isEmpty else { return nil }
        let displayName = skillName.lowercased() == "github" ? "GitHub" : skillName
        return "\(displayName) skill"
    }

    func commandLabel(_ action: ProjectedCommandAction, inProgress: Bool) -> String {
        switch action.category {
        case .read:
            return "\(inProgress ? "Reading" : "Read") \(action.target ?? "a file")"
        case .loadedTool:
            return "\(inProgress ? "Reading" : "Read") \(action.target ?? "a tool")"
        case .search:
            let query = action.query?.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = action.path?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let query, !query.isEmpty, let path, !path.isEmpty {
                return "\(inProgress ? "Searching" : "Searched") for \(query) in \(path)"
            }
            if let query, !query.isEmpty {
                return "\(inProgress ? "Searching" : "Searched") for \(query)"
            }
            return inProgress ? "Searching for files" : "Searched for files"
        case .list:
            if let path = action.path?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return "\(inProgress ? "Listing" : "Listed") files in \(path)"
            }
            return inProgress ? "Listing files" : "Listed files"
        default:
            return inProgress ? "Running command" : "Ran \(shortCommand(action.command))"
        }
    }

    func collabToolRows(
        _ item: CanonicalItem,
        fallbackState: CodexWorkItemStatusV2
    ) -> [CodexCollabAgentRowV2] {
        let action: CodexCollabActionV2 = switch item.payload.string("tool") {
        case "spawnAgent": .created
        case "sendInput": .sentInput
        case "closeAgent": .closed
        default: .waited
        }
        let states = item.payload.object("agentsStates") ?? [:]
        let receiverIDs = orderedUnion(
            item.payload.array("receiverThreadIds")?.compactMap(\.stringValue) ?? [],
            states.keys.sorted()
        )
        guard !receiverIDs.isEmpty else {
            return [.init(
                id: item.key.itemID.rawValue,
                action: action,
                agentNames: [],
                instructions: item.payload.string("prompt"),
                status: fallbackState,
                displayStatus: action == .closed ? .closed : agentDisplayStatus(nil, fallback: fallbackState)
            )]
        }
        return receiverIDs.map { threadID in
            let name = shortAgentName(threadID)
            let rawState = states[threadID]?.object
            let message = rawState?.string("message")
            let messages = message.flatMap { $0.isEmpty ? nil : [name: $0] } ?? [:]
            return .init(
                id: "agent:\(threadID)",
                action: action,
                agentNames: [name],
                agentThreadIDs: [threadID],
                instructions: item.payload.string("prompt"),
                agentMessages: messages,
                status: agentWorkStatus(rawState?.string("status"), fallback: fallbackState),
                displayStatus: action == .closed
                    ? .closed
                    : agentDisplayStatus(rawState?.string("status"), fallback: fallbackState)
            )
        }
    }

    func subagentActivityRow(
        _ item: CanonicalItem,
        state: CodexWorkItemStatusV2
    ) -> CodexCollabAgentRowV2? {
        let action: CodexCollabActionV2
        switch item.payload.string("kind") {
        case "started": action = .started
        case "interacted": action = .interacted
        case "interrupted": action = .interrupted
        default: return nil
        }
        let threadID = item.payload.string("agentThreadId")
        let name = displayAgentName(item.payload.string("agentPath") ?? threadID ?? "agent")
        return .init(
            id: threadID.map { "agent:\($0)" } ?? item.key.itemID.rawValue,
            action: action,
            agentNames: [name],
            agentThreadIDs: threadID.map { [$0] } ?? [],
            instructions: nil,
            status: state,
            displayStatus: action == .interrupted ? .failed : .working
        )
    }

    func appendWorkRow(_ row: CodexWorkRowV2, to turn: inout CodexTurnV2) {
        if case .collabAgent(let incoming) = row,
           mergeCollab(incoming, narrative: &turn.narrative) {
            return
        }
        if case .workGroup(var group)? = turn.narrative.last,
           canAppend(row, to: group) {
            group.rows.append(row)
            refresh(&group)
            turn.narrative[turn.narrative.count - 1] = .workGroup(group)
            return
        }
        let header = CodexWorkGroupHeaderV2.synthesize(rows: [row])
        guard !header.isEmpty else { return }
        turn.narrative.append(.workGroup(.init(
            id: "group-\(row.id)",
            header: header,
            rows: [row],
            isLive: row.isInProgress
        )))
    }

    func closeWorkGroup(_ turn: inout CodexTurnV2) {
        guard case .workGroup(var group)? = turn.narrative.last else { return }
        group.isLive = false
        turn.narrative[turn.narrative.count - 1] = .workGroup(group)
    }

    func canAppend(_ row: CodexWorkRowV2, to group: CodexWorkGroupV2) -> Bool {
        guard case .collabAgent(let incoming) = row,
              case .collabAgent(let previous)? = group.rows.last else { return true }
        return (incoming.action == .waited) == (previous.action == .waited)
    }

    func mergeCollab(
        _ incoming: CodexCollabAgentRowV2,
        narrative: inout [CodexNarrativeEntry]
    ) -> Bool {
        let incomingIDs = Set(incoming.agentThreadIDs)
        var soleLive: (entry: Int, row: Int)?
        var liveCount = 0
        for entryIndex in narrative.indices {
            guard case .workGroup(let group) = narrative[entryIndex] else { continue }
            for rowIndex in group.rows.indices {
                guard case .collabAgent(let existing) = group.rows[rowIndex] else { continue }
                if existing.status == .inProgress {
                    liveCount += 1
                    soleLive = (entryIndex, rowIndex)
                }
                let existingIDs = Set(existing.agentThreadIDs)
                let idsIntersect = !incomingIDs.isEmpty
                    && !existingIDs.isEmpty
                    && !incomingIDs.isDisjoint(with: existingIDs)
                let namesIntersect = !Set(incoming.agentNames).isDisjoint(with: Set(existing.agentNames))
                if idsIntersect || (incomingIDs.isEmpty && existingIDs.isEmpty && namesIntersect) {
                    updateCollab(existing, with: incoming, entry: entryIndex, row: rowIndex, narrative: &narrative)
                    return true
                }
            }
        }
        if incoming.action != .created,
           incoming.action != .started,
           liveCount == 1,
           let soleLive,
           case .workGroup(let group) = narrative[soleLive.entry],
           case .collabAgent(let existing) = group.rows[soleLive.row] {
            updateCollab(existing, with: incoming, entry: soleLive.entry, row: soleLive.row, narrative: &narrative)
            return true
        }
        return false
    }

    func updateCollab(
        _ existing: CodexCollabAgentRowV2,
        with incoming: CodexCollabAgentRowV2,
        entry: Int,
        row: Int,
        narrative: inout [CodexNarrativeEntry]
    ) {
        guard case .workGroup(var group) = narrative[entry] else { return }
        var merged = existing
        merged.action = incoming.action
        merged.status = incoming.status
        merged.displayStatus = incoming.displayStatus
        merged.agentNames = preferredAgentNames(existing.agentNames, incoming.agentNames)
        merged.agentThreadIDs = orderedUnion(existing.agentThreadIDs, incoming.agentThreadIDs)
        merged.instructions = incoming.instructions ?? existing.instructions
        merged.agentMessages.merge(incoming.agentMessages) { _, new in new }
        if merged.timeline.last != incoming.action { merged.timeline.append(incoming.action) }
        group.rows[row] = .collabAgent(merged)
        refresh(&group)
        narrative[entry] = .workGroup(group)
    }

    func refresh(_ group: inout CodexWorkGroupV2) {
        group.header = CodexWorkGroupHeaderV2.synthesize(rows: group.rows)
        group.isLive = group.rows.contains(where: \.isInProgress)
    }

    func orderedUnion(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen: Set<String> = []
        return (lhs + rhs).filter { seen.insert($0).inserted }
    }

    func shortCommand(_ command: String) -> String {
        guard let range = command.range(of: "-lc ") else { return command }
        return String(command[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " '\"") )
    }

    func shortAgentName(_ threadID: String) -> String {
        let suffix = threadID.split(separator: "-").last.map(String.init) ?? threadID
        return "agent-\(suffix.prefix(6))"
    }

    func displayAgentName(_ value: String) -> String {
        let leaf = value.split(separator: "/").last.map(String.init) ?? value
        return leaf.replacingOccurrences(of: "_", with: " ").capitalized
    }

    func preferredAgentNames(_ existing: [String], _ incoming: [String]) -> [String] {
        let existingNamed = existing.filter { !$0.hasPrefix("agent-") }
        let incomingNamed = incoming.filter { !$0.hasPrefix("agent-") }
        if !incomingNamed.isEmpty { return orderedUnion(existingNamed, incomingNamed) }
        if !existingNamed.isEmpty { return existingNamed }
        return orderedUnion(existing, incoming)
    }

    func agentWorkStatus(
        _ rawStatus: String?,
        fallback: CodexWorkItemStatusV2
    ) -> CodexWorkItemStatusV2 {
        switch rawStatus?.lowercased() {
        case "completed", "done", "shutdown", "closed": .completed
        case "errored", "error", "failed", "interrupted": .failed
        case "pendinginit", "pending_init", "running", "working": .inProgress
        default: fallback
        }
    }

    func agentDisplayStatus(
        _ rawStatus: String?,
        fallback: CodexWorkItemStatusV2
    ) -> CodexAgentDisplayStatusV2 {
        switch rawStatus?.lowercased() {
        case "pendinginit", "pending_init", "pending": .starting
        case "running", "working": .working
        case "completed", "done": .done
        case "shutdown", "closed", "cancelled", "canceled": .closed
        case "errored", "error", "failed", "interrupted": .failed
        default:
            switch fallback {
            case .inProgress: .working
            case .completed: .done
            case .failed: .failed
            }
        }
    }

    func mcpError(_ item: [String: CodexJSONValue]) -> String? {
        if let error = item.string("error") { return error.firstLine }
        if let error = item.object("result")?.object("structuredContent")?.string("error") {
            return error.firstLine
        }
        return item.object("result")?.array("content")?
            .compactMap { $0.object?.string("text") }
            .first?
            .firstLine
    }

    func clampedInt(_ duration: DurationMilliseconds) -> Int {
        if duration.rawValue > Int64(Int.max) { return Int.max }
        return max(0, Int(duration.rawValue))
    }

    func turnDuration(_ turn: CanonicalTurn) -> Int? {
        if let duration = turn.duration { return clampedInt(duration) }
        guard let start = turn.startedAt?.rawValue,
              let end = turn.completedAt?.rawValue,
              end >= start else { return nil }
        let seconds = end - start
        if seconds > Int64(Int.max / 1_000) { return Int.max }
        return Int(seconds) * 1_000
    }

    func itemDuration(_ item: CanonicalItem) -> Int? {
        if let duration = item.payload.int("durationMs") { return max(0, duration) }
        guard let start = item.startedAt?.rawValue,
              let end = item.completedAt?.rawValue,
              end >= start else { return nil }
        let milliseconds = end - start
        if milliseconds > Int64(Int.max) { return Int.max }
        return Int(milliseconds)
    }
}

// MARK: - Lossless payload access

private extension CodexJSONValue {
    var object: [String: CodexJSONValue]? {
        if case .dictionary(let value) = self { value } else { nil }
    }

    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }
}

private extension Dictionary where Key == String, Value == CodexJSONValue {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func object(_ key: String) -> [String: CodexJSONValue]? { self[key]?.object }
    func array(_ key: String) -> [CodexJSONValue]? {
        if case .array(let value) = self[key] { value } else { nil }
    }
    func int(_ key: String) -> Int? {
        if case .int(let value) = self[key] { value } else { nil }
    }
    func bool(_ key: String) -> Bool? {
        if case .bool(let value) = self[key] { value } else { nil }
    }
    var textContent: String {
        array("content")?.compactMap { $0.object?.string("text") }.joined()
            ?? string("text")
            ?? ""
    }
    func stringArrayText(_ key: String) -> String {
        array(key)?.compactMap { $0.stringValue ?? $0.object?.string("text") }.joined() ?? ""
    }
}

private extension String {
    var firstLine: String { components(separatedBy: .newlines).first ?? self }
}
