import CodexCore
import Foundation

/// Pure canonical-state to transcript projection.
///
/// The projector owns no cache or reducer truth. Callers may retain the returned
/// presentation and pass it back for incremental work, or omit it to rebuild the
/// exact same presentation from canonical state.
public struct CodexCanonicalTranscriptProjector: Sendable {
    private let itemPresentationPolicy: CodexTranscriptItemPresentationPolicyV2?
    private let fileChangeProjector: CodexCanonicalFileChangeProjector

    public init(
        itemPresentationPolicy: CodexTranscriptItemPresentationPolicyV2? = nil
    ) {
        self.itemPresentationPolicy = itemPresentationPolicy
        self.fileChangeProjector = .init()
    }

    init(
        itemPresentationPolicy: CodexTranscriptItemPresentationPolicyV2? = nil,
        fileChangeDiffPreparer: CodexFileChangeDiffPreparer
    ) {
        self.itemPresentationPolicy = itemPresentationPolicy
        self.fileChangeProjector = .init(diffPreparer: fileChangeDiffPreparer)
    }

    func projectCore(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        requests: [CodexPendingInteractionSnapshot] = [],
        requestRevision: UInt64 = 0,
        previous: CodexCanonicalTranscriptPresentation?,
        excludedTurnIDs: Set<TurnID> = [],
        selectedTurnCostRecording: CodexSelectedTurnDisplayCostRecording? = nil,
        checkpoint: () throws -> Void
    ) rethrows -> CodexCanonicalTranscriptProjectionResult {
        try checkpoint()
        let effectiveRequestRevision = requestRevision
        let fullRebuild = previous?.threadID != threadID
        let old = fullRebuild ? nil : previous
        let intents = unresolvedIntents(snapshot: snapshot, threadID: threadID)
        let intentByTurn = intentsByTurn(intents)
        let echoedIntentIDs = try echoedIntentIDs(
            snapshot: snapshot,
            threadID: threadID,
            checkpoint: checkpoint
        )
        let visibleIntents = intents.filter { !echoedIntentIDs.contains($0.id) }
        let visibleIntentByTurn = intentsByTurn(visibleIntents)
        let order = try projectedTurnOrder(
            snapshot: snapshot,
            threadID: threadID,
            intents: visibleIntents,
            checkpoint: checkpoint
        ).filter { !excludedTurnIDs.contains($0) }
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
                try checkpoint()
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

        let sourceRevisions = try turnSourceRevisions(
            snapshot: snapshot,
            threadID: threadID,
            order: order,
            intentsByTurn: intentByTurn,
            recomputing: dirtyIDs,
            previous: old?.sourceTurnRevisions ?? [:],
            checkpoint: checkpoint
        )

        var turnsByID = old?.turnsByID ?? [:]
        for removedID in removed {
            try checkpoint()
            turnsByID.removeValue(forKey: removedID)
        }

        var upsertedTurns: [CodexTurnV2] = []
        for turnID in order where dirtyIDs.contains(turnID) {
            try checkpoint()
            let key = TurnKey(threadID: threadID, turnID: turnID)
            let turn = snapshot.turns[key]
            var items: [CanonicalItem] = []
            if let turn {
                items.reserveCapacity(turn.itemOrder.count)
                for itemID in turn.itemOrder {
                    try checkpoint()
                    let itemKey = ItemKey(
                        threadID: threadID,
                        turnID: turnID,
                        itemID: itemID
                    )
                    if let item = snapshot.items[itemKey] {
                        items.append(item)
                    }
                }
            }
            guard let projected = try projectTurn(
                turnID: turnID,
                canonical: turn,
                items: items,
                intents: visibleIntentByTurn[turnID] ?? [],
                previous: old?.turnsByID[turnID],
                checkpoint: checkpoint
            ) else {
                turnsByID.removeValue(forKey: turnID)
                continue
            }
            let displayCost = try selectedTurnCostRecording?.record(
                turnID, projected: projected, items: items,
                intents: visibleIntentByTurn[turnID] ?? [], checkpoint: checkpoint)
            turnsByID[turnID] = projected
            upsertedTurns.append(projected)
            if case .exceedsLimit? = displayCost { break }
        }

        // A dirty hint can name a missing turn. Never retain it just because an
        // earlier presentation happened to contain that identifier.
        for turnID in dirtyIDs where !newIDs.contains(turnID) {
            try checkpoint()
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
        try checkpoint()
        return .init(presentation: presentation, update: update)
    }
}

// MARK: - Turn projection

private extension CodexCanonicalTranscriptProjector {
    func projectTurn(
        turnID: TurnID,
        canonical: CanonicalTurn?,
        items: [CanonicalItem],
        intents: [SubmissionIntent],
        previous: CodexTurnV2?,
        checkpoint: () throws -> Void
    ) rethrows -> CodexTurnV2? {
        guard canonical != nil || !intents.isEmpty else { return nil }

        let previousFileRows = try previousFileRows(
            in: previous,
            checkpoint: checkpoint
        )
        var turn = CodexTurnV2(
            id: turnID.rawValue,
            status: projectStatus(canonical: canonical, fallbackIntent: intents.first)
        )
        var activeReasoning: [(itemID: String, text: String)] = []
        var hasContextCompaction = canonical?.extensions["contextCompacted"] == .bool(true)
        var conversationSegments: [CodexTurnConversationSegmentV2] = []
        var currentSteeredMessage: CodexUserMessageV2?

        for item in items {
            try checkpoint()
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
                let presentation = itemPresentationPolicy.presentation(for: context)
                try checkpoint()
                switch presentation {
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
                if let path = item.payload.string("path")?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    appendInlineActivity(
                        .init(
                            id: item.key.itemID.rawValue,
                            label: "Viewed an image",
                            systemImage: "photo.on.rectangle.angled",
                            imagePath: path,
                            status: workStatus(item, completed: completed)
                        ),
                        segments: &conversationSegments,
                        to: &turn
                    )
                } else {
                    appendNotice(id: item.key.itemID, message: "Viewed an image", to: &turn)
                }
            case .sleep:
                appendNotice(id: item.key.itemID, message: "Waiting", to: &turn)
            case .imageGeneration:
                for row in try makeWorkRows(
                    item,
                    completed: completed,
                    previousFileRow: previousFileRows[item.key.itemID.rawValue],
                    checkpoint: checkpoint
                ) {
                    appendWorkRow(row, to: &turn)
                }
                if completed,
                   workStatus(item, completed: true) == .completed,
                   let source = generatedImageSource(item) {
                    let image = CodexGeneratedImageV2(
                        id: item.key.itemID.rawValue,
                        source: source,
                        revisedPrompt: item.payload.string("revisedPrompt")
                    )
                    if let index = turn.generatedImages.firstIndex(where: { $0.id == image.id }) {
                        turn.generatedImages[index] = image
                    } else {
                        turn.generatedImages.append(image)
                    }
                }
            case .collabAgentToolCall:
                let state = workStatus(item, completed: completed)
                if item.payload.string("tool") == "wait" {
                    reconcileAgentWait(item, state: state, narrative: &turn.narrative)
                    continue
                }
                for row in try makeWorkRows(
                    item,
                    completed: completed,
                    previousFileRow: previousFileRows[item.key.itemID.rawValue],
                    checkpoint: checkpoint
                ) {
                    appendWorkRow(row, to: &turn)
                }
            case .commandExecution, .fileChange, .mcpToolCall, .subAgentActivity, .webSearch:
                for row in try makeWorkRows(
                    item,
                    completed: completed,
                    previousFileRow: previousFileRows[item.key.itemID.rawValue],
                    checkpoint: checkpoint
                ) {
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
            try checkpoint()
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

    func previousFileRows(
        in turn: CodexTurnV2?,
        checkpoint: () throws -> Void
    ) rethrows -> [String: CodexFileChangeRowV2] {
        guard let turn else { return [:] }
        var result: [String: CodexFileChangeRowV2] = [:]
        for entry in turn.narrative {
            try checkpoint()
            guard case .workGroup(let group) = entry else { continue }
            for row in group.rows {
                try checkpoint()
                guard case .fileChange(let value) = row else { continue }
                result[value.id] = value
            }
        }
        return result
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
        let decoded = CodexComposerPromptCodec.decode(rawText)
        return CodexUserMessageV2(
            id: item.key.itemID.rawValue,
            clientID: clientID,
            text: decoded?.request ?? rawText,
            rawText: rawText,
            referencedFiles: decoded?.files ?? [],
            responseAnnotations: decoded?.responseAnnotations ?? [],
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
        let decoded = CodexComposerPromptCodec.decode(rawText)
        return CodexUserMessageV2(
            id: "local-\(intent.id.rawValue)",
            clientID: intent.id.rawValue,
            text: decoded?.request ?? rawText,
            rawText: rawText,
            referencedFiles: decoded?.files ?? [],
            responseAnnotations: decoded?.responseAnnotations ?? [],
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
                for rowIndex in group.rows.indices {
                    guard case .collabAgent(var agent) = group.rows[rowIndex],
                          agent.displayStatus == .starting || agent.displayStatus == .working
                    else { continue }
                    agent.status = .completed
                    agent.displayStatus = .done
                    group.rows[rowIndex] = .collabAgent(agent)
                }
                refresh(&group)
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
    func makeWorkRows(
        _ item: CanonicalItem,
        completed: Bool,
        previousFileRow: CodexFileChangeRowV2?,
        checkpoint: () throws -> Void
    ) rethrows -> [CodexWorkRowV2] {
        let id = item.key.itemID.rawValue
        let state = workStatus(item, completed: completed)
        switch item.kind {
        case .commandExecution:
            let parentCommand = item.payload.string("command") ?? "Command"
            let baseOutput = item.payload.string("aggregatedOutput") ?? ""
            let output = completed ? baseOutput : baseOutput + item.liveOverlay.commandOutput.joined()
            let actions = CodexCommandActionPresentation.project(
                (item.payload.array("commandActions") ?? []).compactMap(\.object),
                fallbackCommand: parentCommand
            )
            return actions.enumerated().map { index, action in
                .command(.init(
                    id: actions.count > 1 ? "\(id):\(index)" : id,
                    command: action.command,
                    label: action.label(inProgress: state == .inProgress),
                    action: action.category,
                    status: state,
                    exitCode: item.payload.int("exitCode"),
                    durationMs: itemDuration(item),
                    output: output.isEmpty ? nil : output
                ))
            }
        case .fileChange:
            return [.fileChange(try fileChangeProjector.project(
                item: item,
                status: state,
                durationMs: itemDuration(item),
                previous: previousFileRow,
                checkpoint: checkpoint
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
        if item.payload.int("exitCode").map({ $0 != 0 }) == true {
            return .failed
        }
        guard let rawStatus = item.payload.string("status") else {
            return completed ? .completed : .inProgress
        }
        switch rawStatus {
        case "inProgress":
            return .inProgress
        case "completed":
            return .completed
        case "failed":
            return .failed
        case "declined":
            return .declined
        default:
            return .unknown(rawStatus)
        }
    }

    /// The official renderer prefers the durable saved path but accepts the
    /// image payload itself when app-server did not persist a local file.
    func generatedImageSource(_ item: CanonicalItem) -> String? {
        for key in ["savedPath", "result"] {
            let value = item.payload.string(key)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty { return value }
        }
        return nil
    }

    func collabToolRows(
        _ item: CanonicalItem,
        fallbackState: CodexWorkItemStatusV2
    ) -> [CodexCollabAgentRowV2] {
        let action: CodexCollabActionV2 = switch item.payload.string("tool") {
        case "spawnAgent": .created
        case "sendInput", "resumeAgent": .sentInput
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
        state _: CodexWorkItemStatusV2
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
            status: action == .interrupted ? .completed : .inProgress,
            displayStatus: action == .interrupted ? .done : .working
        )
    }

    /// The official renderer treats v1 `wait` as lifecycle input, never as a
    /// second visible activity. It reconciles the stable per-thread rows built
    /// from v1 spawn/send calls and v2 activity events.
    func reconcileAgentWait(
        _ item: CanonicalItem,
        state: CodexWorkItemStatusV2,
        narrative: inout [CodexNarrativeEntry]
    ) {
        let states = item.payload.object("agentsStates") ?? [:]
        let receiverIDs = orderedUnion(
            item.payload.array("receiverThreadIds")?.compactMap(\.stringValue) ?? [],
            states.keys.sorted()
        )
        let waitCompleted = item.payload.string("status") == "completed" || state == .completed

        for entryIndex in narrative.indices {
            guard case .workGroup(var group) = narrative[entryIndex] else { continue }
            var changed = false
            for rowIndex in group.rows.indices {
                guard case .collabAgent(var agent) = group.rows[rowIndex] else { continue }
                let matchingIDs = agent.agentThreadIDs.filter(receiverIDs.contains)

                var resolvedStatus: CodexWorkItemStatusV2?
                var resolvedDisplayStatus: CodexAgentDisplayStatusV2?
                for threadID in matchingIDs {
                    guard let rawState = states[threadID]?.object else { continue }
                    resolvedStatus = agentWorkStatus(rawState.string("status"), fallback: state)
                    resolvedDisplayStatus = agentDisplayStatus(rawState.string("status"), fallback: state)
                    if let message = rawState.string("message"), !message.isEmpty {
                        let name = agent.agentNames.first ?? shortAgentName(threadID)
                        agent.agentMessages[name] = message
                    }
                }

                // The official bundle applies a completed wait after ingesting
                // `agentsStates` and resolves every still-live child, even if a
                // stale state snapshot still says `running`.
                let effectiveDisplayStatus = resolvedDisplayStatus ?? agent.displayStatus
                if waitCompleted,
                   effectiveDisplayStatus == .starting || effectiveDisplayStatus == .working {
                    resolvedStatus = .completed
                    resolvedDisplayStatus = .done
                }
                guard let resolvedStatus, let resolvedDisplayStatus else { continue }
                agent.status = resolvedStatus
                agent.displayStatus = resolvedDisplayStatus
                group.rows[rowIndex] = .collabAgent(agent)
                changed = true
            }
            if changed {
                refresh(&group)
                narrative[entryIndex] = .workGroup(group)
            }
        }
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
        guard let rawStatus else { return fallback }
        return switch rawStatus.lowercased() {
        case "completed", "done", "shutdown", "closed": .completed
        case "errored", "error", "failed": .failed
        case "interrupted": .completed
        case "declined": .declined
        case "pendinginit", "pending_init", "running", "working": .inProgress
        default: .unknown(rawStatus)
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
        case "errored", "error", "failed": .failed
        case "interrupted": .done
        case .some:
            .failed
        default:
            switch fallback {
            case .inProgress: .working
            case .completed: .done
            case .failed, .declined, .unknown: .failed
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
