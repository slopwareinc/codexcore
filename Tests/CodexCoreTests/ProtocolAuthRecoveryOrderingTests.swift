import XCTest
@testable import CodexCore

final class ProtocolAuthRecoveryOrderingTests: XCTestCase {
    func testIdenticalStartCompletedStartPayloadsPreserveTheActivePhase() throws {
        let adapter = ProtocolStateAdapter()
        var graph = CanonicalStateGraph()
        var reducer = CanonicalStateReducer()
        let key = TurnKey(threadID: "chat", turnID: "turn")
        let params = try CodexJSONValue(encoding: CodexSchemaAuthRecoveryNotification(message: "Recovering", provider: "provider", threadID: "chat", turnID: "turn")).objectValue!
        for (method, expected) in [(CodexAppServerNotificationMethod.modelProviderAuthRecoveryStarted, true),
                                   (.modelProviderAuthRecoveryCompleted, false), (.modelProviderAuthRecoveryStarted, true)] {
            let adaptation = try adapter.adaptNotification(method: method, params: params)
            _ = reducer.apply(adaptation.mutations, to: &graph)
            XCTAssertEqual(graph.turns[key]?.extensions["providerAuthRecoveryActive"], .bool(expected))
        }
        XCTAssertNotNil(graph.turns[key]?.extensions["modelProvider/authRecoveryCompleted"])
    }
}
