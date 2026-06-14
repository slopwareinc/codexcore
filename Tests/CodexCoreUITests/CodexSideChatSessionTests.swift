import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexSideChatSessionTests: XCTestCase {
    func testOpenAppendAndResetOwnLocalSideChatState() {
        var session = CodexSideChatSession()
        let createdAt = Date(timeIntervalSince1970: 10)

        let opened = session.open(createdAt: createdAt)
        session.appendMessage(.user, "Inspect this branch")

        XCTAssertEqual(opened.kind, .notice)
        XCTAssertEqual(opened.title, "Opened side chat")
        XCTAssertEqual(opened.detail, "Focused branch ready")
        XCTAssertEqual(session.sideChat?.createdAt, createdAt)
        XCTAssertEqual(session.sideChat?.messages.map(\.text), ["Inspect this branch"])

        let reopened = session.open()
        XCTAssertEqual(reopened.detail, "Focused branch already available")

        session.reset()
        XCTAssertNil(session.sideChat)
        XCTAssertFalse(session.isSending)
    }

    func testRoutesTranscriptNotificationsThroughSharedRouter() throws {
        var session = CodexSideChatSession()
        let item = try threadItem(#"""
        {
          "id": "cmd-1",
          "type": "commandExecution",
          "command": ["git", "status"],
          "cwd": "/tmp/project",
          "status": "active"
        }
        """#)

        let update = session.apply(notification(.itemStarted(ItemStartedNotification(
            threadId: "side-thread",
            turnId: "turn-1",
            item: item
        ))))

        XCTAssertEqual(update?.activity?.title, "Side chat ran command")
        XCTAssertEqual(update?.activity?.detail, "git status")
        XCTAssertEqual(session.sideChat?.messages.count, 1)
        XCTAssertEqual(session.sideChat?.messages.first?.commandRun?.command, "git status")
    }

    func testSideChatPrefersStoreSnapshotForTranscriptNotifications() throws {
        var session = CodexSideChatSession()
        let item = try threadItem(#"""
        {
          "id": "cmd-1",
          "type": "commandExecution",
          "command": "payload command",
          "status": "active"
        }
        """#)
        let storeTurn = CodexTurnSnapshot(
            id: "turn-1",
            items: [
                .commandExecution(
                    id: "cmd-1",
                    command: "placeholder",
                    output: "",
                    status: "active",
                    timestamp: Date(timeIntervalSince1970: 99)
                )
            ],
            itemDetails: [
                "cmd-1": .commandExecution(CodexCommandExecutionDetail(
                    command: "swift test --filter SideChat",
                    cwd: "/repo",
                    output: "",
                    status: "active"
                ))
            ]
        )

        let update = session.apply(
            notification(.itemStarted(ItemStartedNotification(
                threadId: "side-thread",
                turnId: "turn-1",
                item: item
            ))),
            turnSnapshot: storeTurn
        )

        XCTAssertEqual(update?.activity?.detail, "swift test --filter SideChat")
        XCTAssertEqual(session.sideChat?.messages.first?.commandRun?.command, "swift test --filter SideChat")
        XCTAssertEqual(session.sideChat?.messages.first?.commandRun?.cwd, "/repo")
    }

    func testFallbackNotificationsAndTurnCompletionAreOwnedBySession() {
        var session = CodexSideChatSession()
        session.start(turnID: "turn-1")

        let started = session.apply(notification(.turnStarted(TurnStartedNotification(
            threadId: "side-thread",
            turn: AppServerTurn(id: "turn-1", status: .inProgress)
        ))))
        XCTAssertEqual(started?.activity?.title, "Side chat is working")
        XCTAssertTrue(session.isSending)

        let completed = session.apply(notification(.turnCompleted(TurnCompletedNotification(
            threadId: "side-thread",
            turn: AppServerTurn(id: "turn-1", status: .completed)
        ))))

        XCTAssertEqual(completed?.activity?.title, "Side chat complete")
        XCTAssertFalse(session.isSending)
    }

    func testMismatchedCompletionDoesNotFinishActiveSideChatTurn() {
        var session = CodexSideChatSession()
        session.start(turnID: "turn-1")

        let completed = session.apply(notification(.turnCompleted(TurnCompletedNotification(
            threadId: "side-thread",
            turn: AppServerTurn(id: "turn-2", status: .completed)
        ))))

        XCTAssertNil(completed)
        XCTAssertTrue(session.isSending)
        XCTAssertEqual(session.activeTurnID, "turn-1")
    }
}

private func threadItem(_ json: String) throws -> ThreadItem {
    let data = Data(json.utf8)
    return try JSONDecoder().decode(ThreadItem.self, from: data)
}

private func notification(_ payload: CodexNotificationPayload) -> CodexNotification {
    CodexNotification(
        method: payload.knownMethod?.rawValue ?? "unknown",
        payload: payload,
        rawParams: payload.rawParams
    )
}

private extension CodexNotificationPayload {
    var rawParams: [String: CodexJSONValue] {
        switch self {
        case .itemStarted(let payload), .itemCompleted(let payload):
            return [
                "threadId": .string(payload.threadId),
                "turnId": .string(payload.turnId),
                "item": .dictionary(payload.item.raw)
            ]
        case .turnStarted(let payload):
            return [
                "threadId": payload.threadId.map(CodexJSONValue.string) ?? .null,
                "turn": .dictionary(["id": .string(payload.turn.id), "status": .string(payload.turn.status?.rawValue ?? "")])
            ]
        case .turnCompleted(let payload):
            return [
                "threadId": .string(payload.threadId),
                "turn": .dictionary(["id": .string(payload.turn.id), "status": .string(payload.turn.status?.rawValue ?? "")])
            ]
        case .threadTokenUsageUpdated(let payload):
            return [
                "threadId": .string(payload.threadId),
                "turnId": payload.turnId.map(CodexJSONValue.string) ?? .null,
                "tokenUsage": .dictionary(payload.tokenUsage.raw)
            ]
        case .known(_, let params), .unknown(_, let params):
            return params
        default:
            return [:]
        }
    }
}
