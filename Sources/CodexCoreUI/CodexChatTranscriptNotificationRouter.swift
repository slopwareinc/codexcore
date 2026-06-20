import Foundation
import CodexCore

public struct CodexChatTranscriptRouteContext: Equatable, Sendable {
    public var activityPrefix: String
    public var activeTurnID: String?
    public var includesTurnDiff: Bool
    public var turnSnapshot: CodexTurnSnapshot?

    public init(
        activityPrefix: String = "",
        activeTurnID: String? = nil,
        includesTurnDiff: Bool = true,
        turnSnapshot: CodexTurnSnapshot? = nil
    ) {
        self.activityPrefix = activityPrefix
        self.activeTurnID = activeTurnID
        self.includesTurnDiff = includesTurnDiff
        self.turnSnapshot = turnSnapshot
    }

    fileprivate func title(_ main: String, sideChat: String? = nil) -> String {
        guard !activityPrefix.isEmpty else { return main }
        return sideChat ?? "\(activityPrefix) \(main.lowercased())"
    }
}

public struct CodexChatTranscriptRouteResult: Equatable, Sendable {
    public var activity: CodexActivity?
    public var completedAssistantText: String?

    public init(activity: CodexActivity? = nil, completedAssistantText: String? = nil) {
        self.activity = activity
        self.completedAssistantText = completedAssistantText
    }
}

public struct CodexTranscriptItemHandler: Sendable {
    public var start: @Sendable (CodexChatMessage?, ThreadItem, inout CodexChatTranscriptState, CodexChatTranscriptRouteContext) -> CodexChatTranscriptRouteResult?
    public var complete: @Sendable (CodexChatMessage?, ThreadItem, inout CodexChatTranscriptState, CodexChatTranscriptRouteContext) -> CodexChatTranscriptRouteResult?

    public init(
        start: @escaping @Sendable (CodexChatMessage?, ThreadItem, inout CodexChatTranscriptState, CodexChatTranscriptRouteContext) -> CodexChatTranscriptRouteResult?,
        complete: @escaping @Sendable (CodexChatMessage?, ThreadItem, inout CodexChatTranscriptState, CodexChatTranscriptRouteContext) -> CodexChatTranscriptRouteResult?
    ) {
        self.start = start
        self.complete = complete
    }
}

public enum CodexChatTranscriptNotificationRouter {
    nonisolated(unsafe) public static var itemHandlers: [String: CodexTranscriptItemHandler] = [:]
    public static func apply(
        _ notification: CodexNotification,
        to transcript: inout CodexChatTranscriptState,
        context: CodexChatTranscriptRouteContext = CodexChatTranscriptRouteContext()
    ) -> CodexChatTranscriptRouteResult? {
        switch notification.payload {
        case .agentMessageDelta(let delta):
            if upsertStoreProjectedMessage(itemID: delta.itemId, to: &transcript, context: context) != nil {
                return CodexChatTranscriptRouteResult()
            }
            transcript.appendAssistantDelta(delta.delta, itemID: delta.itemId)
            return CodexChatTranscriptRouteResult()

        case .itemStarted(let payload):
            return applyStartedItem(payload.item, to: &transcript, context: context)

        case .itemCompleted(let payload):
            return applyCompletedItem(payload.item, to: &transcript, context: context)

        case .turnPlanUpdated(let payload):
            return applyTurnPlanUpdated(
                turnID: payload.turnId,
                fallbackPlan: payload.plan,
                fallbackExplanation: payload.explanation,
                to: &transcript,
                context: context
            )

        case .turnDiffUpdated(let payload):
            return applyTurnDiffUpdated(
                turnID: payload.turnId,
                fallbackDiff: payload.diff,
                to: &transcript,
                context: context
            )

        case .known(let method, let params):
            return applyKnown(method, params: params, to: &transcript, context: context)

        case .unknown(let method, let params):
            guard let known = CodexAppServerNotificationMethod(rawValue: method) else { return nil }
            return applyKnown(known, params: params, to: &transcript, context: context)

        default:
            return nil
        }
    }

    private static func applyStartedItem(
        _ item: ThreadItem,
        to transcript: inout CodexChatTranscriptState,
        context: CodexChatTranscriptRouteContext
    ) -> CodexChatTranscriptRouteResult? {
        let projectedMessage = storeProjectedMessage(for: item.id, context: context)
        if let handler = itemHandlers[item.type] {
            return handler.start(projectedMessage, item, &transcript, context)
        }
        switch item.type {
        case "commandExecution":
            guard let message = startedMessage(projectedMessage, item: item, transcript: &transcript), let run = message.commandRun else { return CodexChatTranscriptRouteResult() }
            return activity(.tool, title: context.title("Ran a command", sideChat: "Side chat ran command"), detail: run.command)
        case "fileChange", "patch":
            guard let message = startedMessage(projectedMessage, item: item, transcript: &transcript), let change = message.fileChange else { return CodexChatTranscriptRouteResult() }
            return activity(.tool, title: context.title("Editing files", sideChat: "Side chat editing files"), detail: change.displayPath)
        case "plan":
            guard let message = startedMessage(projectedMessage, item: item, transcript: &transcript), let plan = message.planUpdate else { return CodexChatTranscriptRouteResult() }
            return activity(.tool, title: context.title("Plan started", sideChat: "Side chat plan started"), detail: plan.summary)
        case "mcpToolCall", "toolCall":
            guard let message = startedMessage(projectedMessage, item: item, transcript: &transcript), let toolCall = message.toolCall else { return CodexChatTranscriptRouteResult() }
            return activity(.tool, title: context.title("Calling tool", sideChat: "Side chat calling tool"), detail: toolCall.displayName)
        case "agentMessage", "assistantMessage":
            return CodexChatTranscriptRouteResult()
        case "reasoning":
            guard startedMessage(projectedMessage, item: item, transcript: &transcript) != nil else {
                return CodexChatTranscriptRouteResult()
            }
            return activity(.tool, title: context.title("Thinking", sideChat: "Side chat thinking"), detail: "Reasoning")
        default:
            return nil
        }
    }

    private static func startedMessage(
        _ projectedMessage: CodexChatMessage?,
        item: ThreadItem,
        transcript: inout CodexChatTranscriptState
    ) -> CodexChatMessage? {
        guard let projectedMessage else {
            return transcript.startItem(item)
        }
        _ = transcript.upsertProjectedMessage(projectedMessage, itemID: item.id)
        return projectedMessage
    }

    private static func applyCompletedItem(
        _ item: ThreadItem,
        to transcript: inout CodexChatTranscriptState,
        context: CodexChatTranscriptRouteContext
    ) -> CodexChatTranscriptRouteResult? {
        let projectedMessage = storeProjectedMessage(for: item.id, context: context)
        if let handler = itemHandlers[item.type] {
            return handler.complete(projectedMessage, item, &transcript, context)
        }
        switch item.type {
        case "agentMessage", "assistantMessage":
            guard let message = projectedMessage ?? transcript.completeItem(item) else { return CodexChatTranscriptRouteResult() }
            if projectedMessage != nil {
                _ = transcript.upsertProjectedMessage(message, itemID: item.id)
            }
            return CodexChatTranscriptRouteResult(
                activity: CodexActivity(kind: .tool, title: context.title("Codex replied", sideChat: "Side chat replied"), detail: previewText(message.text)),
                completedAssistantText: message.text
            )
        case "userMessage":
            return CodexChatTranscriptRouteResult()
        case "reasoning":
            if let projectedMessage {
                _ = transcript.upsertProjectedMessage(projectedMessage, itemID: item.id)
            } else {
                _ = transcript.completeItem(item)
            }
            return CodexChatTranscriptRouteResult()
        case "commandExecution":
            if let projectedMessage {
                _ = transcript.upsertProjectedMessage(projectedMessage, itemID: item.id)
            } else {
                _ = transcript.completeItem(item)
            }
            return CodexChatTranscriptRouteResult()
        case "fileChange", "patch":
            let message: CodexChatMessage?
            if let projectedMessage {
                _ = transcript.upsertProjectedMessage(projectedMessage, itemID: item.id)
                message = projectedMessage
            } else {
                message = transcript.completeItem(item)
            }
            guard let change = message?.fileChange else { return CodexChatTranscriptRouteResult() }
            return activity(.tool, title: context.title("File change complete", sideChat: "Side chat file change complete"), detail: change.displayPath)
        case "mcpToolCall", "toolCall":
            let message: CodexChatMessage?
            if let projectedMessage {
                _ = transcript.upsertProjectedMessage(projectedMessage, itemID: item.id)
                message = projectedMessage
            } else {
                message = transcript.completeItem(item)
            }
            guard let toolCall = message?.toolCall else { return CodexChatTranscriptRouteResult() }
            let title = toolCall.error == nil ? context.title("Tool complete", sideChat: "Side chat tool complete") : context.title("Tool failed", sideChat: "Side chat tool failed")
            return activity(.tool, title: title, detail: toolCall.displayName)
        default:
            return nil
        }
    }

    private static func storeProjectedMessage(
        for itemID: String,
        context: CodexChatTranscriptRouteContext
    ) -> CodexChatMessage? {
        guard let turn = context.turnSnapshot,
              let item = turn.items.first(where: { $0.id == itemID }) else {
            return nil
        }
        return CodexChatTranscriptProjection.message(for: item, detail: turn.itemDetails[itemID])
    }

    private static func applyKnown(
        _ method: CodexAppServerNotificationMethod,
        params: [String: CodexJSONValue],
        to transcript: inout CodexChatTranscriptState,
        context: CodexChatTranscriptRouteContext
    ) -> CodexChatTranscriptRouteResult? {
        guard let route = CodexNotificationMetadata.knownRoute(method: method, params: params) else {
            return nil
        }
        switch route {
        case .commandOutputDelta(let update):
            if upsertStoreProjectedMessage(itemID: update.item.itemID, to: &transcript, context: context) != nil {
                return CodexChatTranscriptRouteResult()
            }
            transcript.appendCommandOutput(update.text, itemID: update.item.itemID)
            return CodexChatTranscriptRouteResult()
        case .commandTerminalInteraction(let update):
            if upsertStoreProjectedMessage(itemID: update.item.itemID, to: &transcript, context: context) != nil {
                return CodexChatTranscriptRouteResult()
            }
            transcript.appendCommandOutput(update.text, itemID: update.item.itemID)
            return CodexChatTranscriptRouteResult()
        case .fileChangeOutputDelta(let update):
            if upsertStoreProjectedMessage(itemID: update.item.itemID, to: &transcript, context: context) != nil {
                return CodexChatTranscriptRouteResult()
            }
            transcript.appendFileChangeOutput(update.text, itemID: update.item.itemID)
            return CodexChatTranscriptRouteResult()
        case .fileChangePatchUpdated(let update):
            if let message = upsertStoreProjectedMessage(itemID: update.itemID, to: &transcript, context: context) {
                guard let change = message.fileChange else { return CodexChatTranscriptRouteResult() }
                return activity(.tool, title: context.title("Patch updated", sideChat: "Side chat patch updated"), detail: change.displayPath)
            }
            guard let message = CodexChatTranscriptProjection.message(
                forRawItemID: update.itemID,
                type: "fileChange",
                raw: params,
                fallbackStatus: "active"
            ),
                  let change = message.fileChange else {
                return CodexChatTranscriptRouteResult()
            }
            transcript.upsertProjectedMessage(message, itemID: update.itemID)
            return activity(.tool, title: context.title("Patch updated", sideChat: "Side chat patch updated"), detail: change.displayPath)
        case .turnDiffUpdated(let update) where context.includesTurnDiff:
            return applyTurnDiffUpdated(
                turnID: update.turnID,
                fallbackDiff: update.diff,
                to: &transcript,
                context: context
            )
        case .planDelta(let update):
            transcript.appendPlanDelta(update.text, itemID: update.item.itemID)
            return CodexChatTranscriptRouteResult()
        case .turnPlanUpdated(let update):
            return applyTurnPlanUpdated(
                turnID: update.turnID,
                fallbackPlan: update.plan,
                fallbackExplanation: update.explanation,
                to: &transcript,
                context: context
            )
        case .mcpToolCallProgress(let update):
            if upsertStoreProjectedMessage(itemID: update.item.itemID, to: &transcript, context: context) != nil {
                return CodexChatTranscriptRouteResult()
            }
            transcript.appendToolCallProgress(update.text, itemID: update.item.itemID)
            return CodexChatTranscriptRouteResult()
        case .reasoningTextDelta(let update):
            transcript.appendReasoningDelta(update.text, itemID: update.item.itemID, isSummary: false)
            return CodexChatTranscriptRouteResult()
        case .reasoningSummaryTextDelta(let update):
            transcript.appendReasoningDelta(update.text, itemID: update.item.itemID, isSummary: true)
            return CodexChatTranscriptRouteResult()
        case .notice(let update):
            guard let notice = CodexChatMessage.notice(
                itemID: update.itemID,
                method: update.method,
                raw: params,
                isStreaming: update.isStreaming
            ) else {
                return activity(.notice, title: CodexNotificationPresentation.methodTitle(update.method.rawValue), detail: "App-server notification")
            }
            transcript.upsertNotice(notice)
            return activity(.notice, title: context.title(notice.title, sideChat: "Side chat \(notice.title.lowercased())"), detail: notice.detail)
        default:
            return nil
        }
    }

    private static func upsertStoreProjectedMessage(
        itemID: String,
        to transcript: inout CodexChatTranscriptState,
        context: CodexChatTranscriptRouteContext
    ) -> CodexChatMessage? {
        guard let message = storeProjectedMessage(for: itemID, context: context) else { return nil }
        transcript.upsertProjectedMessage(message, itemID: itemID)
        return message
    }

    private static func applyTurnPlanUpdated(
        turnID: String,
        fallbackPlan: [TurnPlanStep]?,
        fallbackExplanation: String?,
        to transcript: inout CodexChatTranscriptState,
        context: CodexChatTranscriptRouteContext
    ) -> CodexChatTranscriptRouteResult? {
        let turn = context.turnSnapshot ?? CodexTurnSnapshot(
            id: turnID,
            status: context.activeTurnID == turnID ? .running : .completed,
            plan: fallbackPlan,
            planExplanation: fallbackExplanation
        )
        guard let message = CodexChatTranscriptProjection.turnPlanMessage(for: turn),
              let plan = message.planUpdate else {
            return CodexChatTranscriptRouteResult()
        }
        transcript.upsertPlan(plan)
        let title = "Plan updated (\(plan.completedStepCount)/\(plan.steps.count))"
        let detail = plan.steps.first(where: \.isActive)?.step ?? plan.explanation ?? "Plan revised"
        return activity(.tool, title: context.title(title, sideChat: "Side chat plan updated"), detail: detail)
    }

    private static func applyTurnDiffUpdated(
        turnID: String,
        fallbackDiff: String?,
        to transcript: inout CodexChatTranscriptState,
        context: CodexChatTranscriptRouteContext
    ) -> CodexChatTranscriptRouteResult? {
        guard context.includesTurnDiff else { return nil }
        let turn = context.turnSnapshot ?? CodexTurnSnapshot(
            id: turnID,
            status: context.activeTurnID == turnID ? .running : .completed,
            diff: fallbackDiff
        )
        guard let message = CodexChatTranscriptProjection.turnDiffMessage(for: turn),
              let change = message.fileChange else {
            return CodexChatTranscriptRouteResult()
        }
        transcript.upsertFileChange(change)
        let fileCount = change.diff.components(separatedBy: "diff --git").count - 1
        return activity(
            .tool,
            title: context.title("Diff updated", sideChat: "Side chat diff updated"),
            detail: fileCount > 0 ? "\(fileCount) file(s) changed" : "Working tree changed"
        )
    }

    private static func activity(_ kind: CodexActivity.Kind, title: String, detail: String) -> CodexChatTranscriptRouteResult {
        CodexChatTranscriptRouteResult(activity: CodexActivity(kind: kind, title: title, detail: detail))
    }

    private static func previewText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
