import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexTranscriptWidgetInventoryTests {
    @Test func inventoryDeclaresEveryAuditedRecordAndTypedSeams() {
        #expect(CodexTranscriptWidgetInventoryV1.isComplete)
        #expect(CodexTranscriptWidgetInventoryV1.ids.count == 16)
        #expect(Set(CodexTranscriptWidgetInventoryV1.ids) == Set(CodexTranscriptWidgetID.allCases))
        #expect(CodexTranscriptWidgetInventoryV1.records.allSatisfy { record in
            !record.eventAdapterIDs.isEmpty && !record.rendererIDs.isEmpty
        })
    }

    @Test func inventoryJSONIDsStayInLockstepWithTypedCoverage() throws {
        let data = try Data(contentsOf: repoRootURL().appendingPathComponent("docs/reference/official-transcript-widget-inventory.v1.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(root["records"] as? [[String: Any]])
        let ids = records.compactMap { $0["id"] as? String }
        #expect(ids.count == records.count)
        #expect(ids == CodexTranscriptWidgetInventoryV1.ids.map(\.rawValue))
    }

    @Test func eachInventoryFamilyHasAnExplicitRegistryBoundary() {
        let records = CodexTranscriptWidgetInventoryV1.records
        #expect(records.filter { $0.family == .plan }.count == 3)
        #expect(records.filter { $0.family == .mcp }.count == 2)
        #expect(records.filter { $0.family == .recovery }.count == 3)
        #expect(records.filter { $0.lazyHeavyContent }.map(\.id) == [
            .mcpTypedContent, .mcpAppWidget, .forkWorktreeRemoteHook,
            .attachmentsContextProvenance, .mathMermaidVisualization
        ])
    }

    @Test func fixtureReplayRoutesItemsAndExtensionsWithoutRawActivity() throws {
        let data = try Data(contentsOf: try #require(
            Bundle.module.url(forResource: "turn-issue-240-parity", withExtension: "jsonl")
        ))
        let registry = CodexTranscriptEventRegistry()
        var routed: [CodexTranscriptEvent] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let value = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            if let item = value["item"] as? [String: Any] {
                let itemJSON = try CodexJSONValue.fromJSONObject(item)
                let rawType = try #require(item["type"] as? String)
                let rawID = try #require(item["id"] as? String)
                let itemObject = try #require(itemJSON.objectValue)
                let itemModel = CanonicalItem(
                    key: .init(threadID: "fixture-thread", turnID: "fixture-turn", itemID: ItemID(rawID)),
                    kind: ThreadItemKind(rawValue: rawType),
                    payload: itemObject,
                    authority: .completed
                )
                if let event = registry.event(for: itemModel, completed: true) { routed.append(event) }
            } else if let extensionObject = value["extension"] as? [String: Any],
                      let key = extensionObject["key"] as? String {
                var payload = extensionObject
                payload.removeValue(forKey: "key")
                let json = try CodexJSONValue.fromJSONObject(payload)
                if let event = registry.event(forExtensionKey: key, value: json) {
                    routed.append(event)
                }
            }
        }
        #expect(routed.contains { if case .structuredCard = $0 { true } else { false } })
        #expect(routed.contains { if case .userContext = $0 { true } else { false } })
        #expect(routed.contains { if case .mcpContent = $0 { true } else { false } })
        #expect(routed.contains { if case .memoryCitations = $0 { true } else { false } })
        #expect(routed.contains { if case .approvalReview = $0 { true } else { false } })
        #expect(routed.contains { if case .hookActivity = $0 { true } else { false } })
        #expect(routed.contains { if case .notice = $0 { true } else { false } })
        #expect(routed.contains { if case .recovery = $0 { true } else { false } })
    }

    @Test func notificationReplayUsesTheSameTypedAdaptersAsHydration() {
        let registry = CodexTranscriptEventRegistry()
        let params: [String: CodexJSONValue] = [
            "threadId": .string("fixture-thread"),
            "turnId": .string("fixture-turn"),
            "reviewId": .string("review"),
            "review": .dictionary([
                "status": .string("timedOut"),
                "riskLevel": .string("high"),
                "rationale": .string("deadline")
            ])
        ]
        let events = registry.events(method: "item/autoApprovalReview/completed", params: params)
        guard case .approvalReview(let review)? = events.first else {
            Issue.record("Expected typed approval event")
            return
        }
        #expect(review.status == .timedOut)
        #expect(review.isHighRisk)
    }

    @Test func provenanceAdapterRetainsMemorySourcesAndOutputsTogether() {
        let item = CanonicalItem(
            key: .init(threadID: "fixture-thread", turnID: "fixture-turn", itemID: "answer"),
            kind: .agentMessage,
            payload: [
                "memoryCitation": .dictionary([
                    "entries": .array([.dictionary([
                        "path": .string("docs/fixture.md"),
                        "lineStart": .int(1),
                        "lineEnd": .int(2),
                        "note": .string("fixture")
                    ])])
                ]),
                "sources": .array([.dictionary([
                    "title": .string("Fixture source"),
                    "url": .string("https://invalid.example/source")
                ])]),
                "outputResources": .array([.dictionary([
                    "type": .string("file"),
                    "path": .string("/workspace/FixtureProject/output.txt"),
                    "name": .string("output.txt")
                ])])
            ],
            authority: .completed
        )
        let provenance = CodexTranscriptEventRegistry().provenance(for: item)
        #expect(provenance.memoryCitations.count == 1)
        #expect(provenance.sourceCitations.first?.location == "https://invalid.example/source")
        #expect(provenance.outputResources.first?.name == "output.txt")
    }

    @Test func mcpAppHostsAreLazySandboxedAndBounded() {
        var host = CodexMCPAppHostLifecycle(
            widget: .init(id: "fixture", uri: "mcp://fixture/app"),
            retentionLimitBytes: 128
        )
        #expect(!host.shouldPerformLayout)
        host.reveal()
        #expect(host.state == .loading)
        #expect(host.shouldPerformLayout)
        host.markReady(retainedPreviewBytes: 512)
        #expect(host.retainedPreviewBytes == 128)
        host.hide()
        #expect(!host.shouldPerformLayout)
        host.markFailed()
        #expect(host.state == .failed)
        #expect(host.retainedPreviewBytes == 0)
    }

    @Test func recoveryStateRequiresExplicitVerificationBeforeRetry() {
        var state = CodexTranscriptRecoveryState()
        state.markWriteUncertain(requestID: "request")
        #expect(!state.canRetryTurn)
        let blockedRetry = state.beginTurnRetry(requestID: "request")
        #expect(!blockedRetry)
        state.authorizeTurnRetry()
        #expect(state.canRetryTurn)
        let beganRetry = state.beginTurnRetry(requestID: "request")
        #expect(beganRetry)
        state.markRecovered()
        #expect(!state.canRetryTurn)
    }

    @Test func visualizationBlocksHaveTextFallbackAndStableStreamingIdentity() {
        let first = CodexBlockProjector.project(
            "::: visualization\nseries: fixture\n",
            streaming: true,
            cacheNamespace: "fixture"
        )
        let second = CodexBlockProjector.project(
            "::: visualization\nseries: fixture\nvalue: 1\n::: ",
            previous: first,
            streaming: true,
            cacheNamespace: "fixture"
        )
        guard case .visualization(let id, let source, let complete)? = first.first else {
            Issue.record("Expected visualization fallback")
            return
        }
        #expect(id == second.first?.id)
        #expect(source.contains("series"))
        #expect(!complete)
    }

    @Test func bookmarkNavigatorMovesByStableTurnIdentity() {
        var presentation = CodexThreadUIPresentation(
            threadID: "fixture-thread",
            transcript: .init(turns: [
                .init(id: "one", userMessage: .init(id: "u1", text: "One"), status: .done(durationMs: 1)),
                .init(id: "two", userMessage: .init(id: "u2", text: "Two"), status: .done(durationMs: 1)),
                .init(id: "three", userMessage: .init(id: "u3", text: "Three"), status: .done(durationMs: 1)),
            ]),
            bookmarkedTurnIDs: ["one", "three"]
        )
        var navigator = CodexTranscriptBookmarkNavigator()
        let first = navigator.move(in: presentation)
        let second = navigator.move(in: presentation)
        let exhausted = navigator.move(in: presentation)
        let backwards = navigator.move(in: presentation, backwards: true)
        #expect(first?.turnID == "one")
        #expect(second?.turnID == "three")
        #expect(exhausted?.turnID == nil)
        #expect(backwards?.turnID == "one")
        presentation.focusedItemID = CodexTranscriptNavigationProjection.focusTarget(in: presentation, turnID: "one", itemID: "message")
        #expect(presentation.focusedItemID == "one:message")
    }
}

private func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private extension CodexJSONValue {
    static func fromJSONObject(_ value: Any) throws -> CodexJSONValue {
        try JSONDecoder().decode(CodexJSONValue.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
