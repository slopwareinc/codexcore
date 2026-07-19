import XCTest
@testable import CodexCore

final class StateInvalidationTests: XCTestCase {
    func testThreadAndTurnScopesIncludeDescendantItems() {
        let thread: ThreadID = "thread"
        let turn = TurnKey(threadID: thread, turnID: "turn")
        let item = ItemKey(threadID: thread, turnID: turn.turnID, itemID: "item")
        let invalidation = StateInvalidation(
            revision: StateRevision(1),
            fields: .itemContent,
            itemKeys: [item]
        )

        XCTAssertTrue(invalidation.affects(.thread(thread, fields: .itemContent)))
        XCTAssertTrue(invalidation.affects(.turn(turn, fields: .itemContent)))
        XCTAssertTrue(invalidation.affects(.item(item, fields: .itemContent)))
        XCTAssertFalse(invalidation.affects(.global(fields: .itemContent)))
        XCTAssertFalse(invalidation.affects(.thread("other", fields: .itemContent)))
        XCTAssertFalse(invalidation.affects(.thread(thread, fields: .threadStatus)))
    }

    func testGlobalScopeRejectsEntityInvalidations() {
        let global = StateInvalidation(
            revision: StateRevision(1),
            fields: .connection
        )
        let entity = StateInvalidation(
            revision: StateRevision(2),
            fields: .threadMetadata,
            threadIDs: ["thread"]
        )

        XCTAssertTrue(global.affects(.global(fields: .connection)))
        XCTAssertTrue(global.affects(.all))
        XCTAssertFalse(entity.affects(.global(fields: .threadMetadata)))
    }

    func testCanonicalBatchMapsFieldsAndAffectedEntities() {
        let item = ItemKey(threadID: "thread", turnID: "turn", itemID: "item")
        let batch = CanonicalStateChangeBatch(
            baseRevision: .zero,
            revision: StateRevision(1),
            changes: [
                .turnCompleted(item.turnKey),
                .itemDeltaAppended(item),
                .planReplaced(item.turnKey),
            ]
        )

        let invalidation = StateInvalidation(batch)

        XCTAssertEqual(invalidation.revision, StateRevision(1))
        XCTAssertEqual(invalidation.fields, [.turnStatus, .itemContent, .plan])
        XCTAssertEqual(invalidation.threadIDs, [item.threadID])
        XCTAssertEqual(invalidation.turnKeys, [item.turnKey])
        XCTAssertEqual(invalidation.itemKeys, [item])
    }

    func testDestructiveThreadRollbackInvalidatesTurnStructure() {
        let thread: ThreadID = "thread"
        let invalidation = StateInvalidation(CanonicalStateChangeBatch(
            baseRevision: .zero,
            revision: StateRevision(1),
            changes: [.threadTurnsReplaced(thread)]
        ))

        XCTAssertEqual(invalidation.fields, .turnStructure)
        XCTAssertTrue(invalidation.affects(.thread(thread, fields: .turnStructure)))
    }

    func testEmptyEntitySelectionsNeverMatch() {
        let invalidation = StateInvalidation(
            revision: StateRevision(1),
            fields: .itemContent,
            itemKeys: [.init(threadID: "thread", turnID: "turn", itemID: "item")]
        )

        XCTAssertFalse(invalidation.affects(.init(entities: .threads([]), fields: .itemContent)))
        XCTAssertFalse(invalidation.affects(.init(entities: .turns([]), fields: .itemContent)))
        XCTAssertFalse(invalidation.affects(.init(entities: .items([]), fields: .itemContent)))
    }
}
