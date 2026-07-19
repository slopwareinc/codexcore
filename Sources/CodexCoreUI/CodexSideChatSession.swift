import CodexCore
import Foundation

public struct CodexSideChatSessionUpdate: Sendable, Equatable {
    public var activity: CodexActivity?
    public init(activity: CodexActivity? = nil) { self.activity = activity }
}

public struct CodexSideChatSession: Sendable {
    private var turnLifecycle = CodexTurnLifecycleSession()
    private var localSideChat: CodexSideChatState?
    private var sideChatThreadID: ThreadID?

    public init() {}
    public var sideChat: CodexSideChatState? { localSideChat }
    public var isSending: Bool { turnLifecycle.isSending }
    public var activeTurnID: String? { turnLifecycle.activeTurnID }
    public var threadID: ThreadID? { sideChatThreadID }

    @discardableResult
    public mutating func open(createdAt: Date = Date()) -> CodexActivity {
        let created = localSideChat == nil
        if created { localSideChat = CodexSideChatState(createdAt: createdAt) }
        return activity(.notice, title: "Opened side chat", detail: created ? "Focused branch ready" : "Focused branch already available")
    }

    public mutating func startPending() { turnLifecycle.startPending() }
    public mutating func start(turnID: String, threadID: ThreadID) {
        turnLifecycle.start(turnID: turnID)
        sideChatThreadID = threadID
    }
    public mutating func failToStart() { turnLifecycle.failToStart() }
    public mutating func reset() {
        turnLifecycle.reset()
        sideChatThreadID = nil
        localSideChat = nil
    }

    public mutating func beginSubmission(prompt: String) -> [CodexActivity] {
        let opened = open(); startPending()
        return [opened, activity(.turn, title: "Side chat asked", detail: prompt)]
    }

    public mutating func failSubmission(message: String) -> CodexActivity {
        failToStart(); return activity(.turn, title: "Side chat failed to start", detail: message)
    }

    /// Refreshes side-chat lifecycle from the canonical graph. Transcript
    /// content is deliberately not copied here: the side-chat presentation
    /// store observes the same leased thread and owns that disposable cache.
    @discardableResult
    public mutating func applyCanonicalSnapshot(
        _ snapshot: CanonicalStateSnapshot,
        threadID explicitThreadID: ThreadID? = nil
    ) -> CodexSideChatSessionUpdate? {
        guard let threadID = explicitThreadID ?? sideChatThreadID,
              let activeTurnID,
              let turn = snapshot.turns[TurnKey(
                threadID: threadID,
                turnID: TurnID(activeTurnID)
              )],
              turn.status.isTerminal
        else { return nil }
        return finishTurn(id: activeTurnID)
    }

    @discardableResult
    public mutating func finishTurn(id turnID: String?) -> CodexSideChatSessionUpdate? {
        guard turnLifecycle.complete(turnID: turnID) else { return nil }
        return CodexSideChatSessionUpdate(activity: activity(.turn, title: "Side chat complete", detail: "Focused branch finished"))
    }

    private func activity(_ kind: CodexActivity.Kind, title: String, detail: String) -> CodexActivity {
        CodexActivity(kind: kind, title: title, detail: detail)
    }
}
