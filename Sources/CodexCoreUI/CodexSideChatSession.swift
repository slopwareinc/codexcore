import Foundation
import CodexCore

public struct CodexSideChatSessionUpdate: Sendable, Equatable {
    public var activity: CodexActivity?

    public init(activity: CodexActivity? = nil) {
        self.activity = activity
    }
}

public struct CodexSideChatSession: Sendable {
    private var turnLifecycle = CodexTurnLifecycleSession()
    private var transcript = CodexChatTranscriptState()
    private var localSideChat: CodexSideChatState?

    public init() {}

    public var sideChat: CodexSideChatState? {
        localSideChat
    }

    public var messages: [CodexChatMessage] {
        transcript.messages
    }

    public var isSending: Bool {
        turnLifecycle.isSending
    }

    public var activeTurnID: String? {
        turnLifecycle.activeTurnID
    }

    public var activeTurn: CodexTurnHandle? {
        turnLifecycle.activeTurn
    }

    @discardableResult
    public mutating func open(createdAt: Date = Date()) -> CodexActivity {
        if localSideChat == nil {
            localSideChat = CodexSideChatState(createdAt: createdAt)
            return activity(.notice, title: "Opened side chat", detail: "Focused branch ready")
        }
        return activity(.notice, title: "Opened side chat", detail: "Focused branch already available")
    }

    public mutating func startPending() {
        turnLifecycle.startPending()
    }

    public mutating func start(turnID: String) {
        turnLifecycle.start(turnID: turnID)
    }

    public mutating func start(_ handle: CodexTurnHandle) {
        turnLifecycle.start(handle)
    }

    public mutating func failToStart() {
        turnLifecycle.failToStart()
    }

    public mutating func reset() {
        turnLifecycle.reset()
        transcript.reset()
        localSideChat = nil
    }

    public mutating func appendMessage(_ role: CodexChatMessage.Role, _ text: String, detail: String? = nil) {
        transcript.appendMessage(role, text, detail: detail)
        syncLocalSideChat()
    }

    public mutating func beginSubmission(prompt: String) -> [CodexActivity] {
        let openActivity = open()
        startPending()
        appendMessage(.user, prompt)
        return [
            openActivity,
            activity(.turn, title: "Side chat asked", detail: prompt)
        ]
    }

    public mutating func failSubmission(message: String) -> CodexActivity {
        failToStart()
        appendMessage(.system, "Failed to start side chat: \(message)")
        return activity(.turn, title: "Side chat failed to start", detail: message)
    }

    public mutating func apply(
        _ notification: CodexNotification,
        turnSnapshot: CodexTurnSnapshot? = nil
    ) -> CodexSideChatSessionUpdate? {
        if let transcriptResult = CodexChatTranscriptNotificationRouter.apply(
            notification,
            to: &transcript,
            context: CodexChatTranscriptRouteContext(
                activityPrefix: "Side chat",
                activeTurnID: turnLifecycle.activeTurnID,
                includesTurnDiff: false,
                turnSnapshot: turnSnapshot
            )
        ) {
            syncLocalSideChat()
            return CodexSideChatSessionUpdate(activity: transcriptResult.activity)
        }

        switch notification.payload {
        case .itemStarted(let payload):
            guard payload.item.type != "agentMessage", payload.item.type != "assistantMessage" else {
                return CodexSideChatSessionUpdate()
            }
            return CodexSideChatSessionUpdate(activity: activity(.tool, title: "Side chat working", detail: CodexNotificationPresentation.itemTypeTitle(payload.item.type)))
        case .itemCompleted(let payload):
            return CodexSideChatSessionUpdate(activity: activity(.tool, title: "Side chat \(CodexNotificationPresentation.itemTypeTitle(payload.item.type))", detail: "Completed"))
        case .threadTokenUsageUpdated:
            return CodexSideChatSessionUpdate(activity: activity(.token, title: "Side chat usage updated", detail: "Updated"))
        case .turnStarted:
            return CodexSideChatSessionUpdate(activity: activity(.turn, title: "Side chat is working", detail: "Turn started"))
        case .turnCompleted(let payload):
            return finishTurn(id: payload.turn.id)
        case .known(let method, let params):
            guard method == .turnCompleted else { return nil }
            return finishTurn(id: CodexNotificationMetadata.turnID(from: params))
        case .unknown(let method, let params):
            guard let known = CodexAppServerNotificationMethod(rawValue: method) else {
                return CodexSideChatSessionUpdate(activity: activity(.notice, title: CodexNotificationPresentation.methodTitle(method), detail: "Side chat notification"))
            }
            guard known == .turnCompleted else { return nil }
            return finishTurn(id: CodexNotificationMetadata.turnID(from: params))
        default:
            return nil
        }
    }

    @discardableResult
    public mutating func finishTurn(id turnID: String?) -> CodexSideChatSessionUpdate? {
        guard turnLifecycle.complete(turnID: turnID) else { return nil }
        transcript.finishStreamingMessages()
        syncLocalSideChat()
        return CodexSideChatSessionUpdate(activity: activity(.turn, title: "Side chat complete", detail: "Focused branch finished"))
    }

    private mutating func syncLocalSideChat() {
        if localSideChat == nil {
            localSideChat = CodexSideChatState(createdAt: Date())
        }
        localSideChat?.messages = transcript.messages
    }

    private func activity(_ kind: CodexActivity.Kind, title: String, detail: String) -> CodexActivity {
        CodexActivity(kind: kind, title: title, detail: detail)
    }

}
