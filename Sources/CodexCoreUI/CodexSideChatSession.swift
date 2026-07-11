import CodexCore
import Foundation

public struct CodexSideChatSessionUpdate: Sendable, Equatable {
    public var activity: CodexActivity?
    public init(activity: CodexActivity? = nil) { self.activity = activity }
}

public struct CodexSideChatSession: Sendable {
    private var turnLifecycle = CodexTurnLifecycleSession()
    private var reducer: CodexTranscriptReducerV2?
    private var localSideChat: CodexSideChatState?

    public init() {}
    public var sideChat: CodexSideChatState? { localSideChat }
    public var isSending: Bool { turnLifecycle.isSending }
    public var activeTurnID: String? { turnLifecycle.activeTurnID }
    public var activeTurn: CodexTurnHandle? { turnLifecycle.activeTurn }

    @discardableResult
    public mutating func open(createdAt: Date = Date()) -> CodexActivity {
        let created = localSideChat == nil
        if created { localSideChat = CodexSideChatState(createdAt: createdAt) }
        return activity(.notice, title: "Opened side chat", detail: created ? "Focused branch ready" : "Focused branch already available")
    }

    public mutating func startPending() { turnLifecycle.startPending() }
    public mutating func start(turnID: String) { turnLifecycle.start(turnID: turnID) }
    public mutating func start(_ handle: CodexTurnHandle) {
        turnLifecycle.start(handle)
        prepareReducer(threadID: handle.threadId)
    }
    public mutating func failToStart() { turnLifecycle.failToStart() }
    public mutating func reset() { turnLifecycle.reset(); reducer = nil; localSideChat = nil }

    public mutating func beginSubmission(prompt: String) -> [CodexActivity] {
        let opened = open(); startPending()
        if let reducer { self.reducer?.submitLocalUserMessage(text: prompt, clientID: UUID().uuidString); sync(reducer) }
        return [opened, activity(.turn, title: "Side chat asked", detail: prompt)]
    }

    public mutating func failSubmission(message: String) -> CodexActivity {
        failToStart(); return activity(.turn, title: "Side chat failed to start", detail: message)
    }

    public mutating func apply(_ notification: CodexNotification, turnSnapshot _: CodexTurnSnapshot? = nil) -> CodexSideChatSessionUpdate? {
        let threadID = CodexNotificationMetadata.threadID(from: notification.rawParams) ?? activeTurn?.threadId
        guard let threadID else { return nil }
        prepareReducer(threadID: threadID)
        reducer?.apply(method: notification.method, params: .dictionary(notification.rawParams))
        if let reducer { sync(reducer) }
        if case .turnCompleted(let payload) = notification.payload { return finishTurn(id: payload.turn.id) }
        return CodexSideChatSessionUpdate()
    }

    @discardableResult
    public mutating func finishTurn(id turnID: String?) -> CodexSideChatSessionUpdate? {
        guard turnLifecycle.complete(turnID: turnID) else { return nil }
        return CodexSideChatSessionUpdate(activity: activity(.turn, title: "Side chat complete", detail: "Focused branch finished"))
    }

    private mutating func prepareReducer(threadID: String) {
        if reducer?.threadID != threadID { reducer = CodexTranscriptReducerV2(threadID: threadID) }
    }
    private mutating func sync(_ reducer: CodexTranscriptReducerV2) {
        if localSideChat == nil { localSideChat = CodexSideChatState() }
        localSideChat?.transcript = reducer.transcript
    }
    private func activity(_ kind: CodexActivity.Kind, title: String, detail: String) -> CodexActivity {
        CodexActivity(kind: kind, title: title, detail: detail)
    }
}
