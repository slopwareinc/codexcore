import XCTest
@testable import CodexCore

final class ThreadResourceProjectionTests: XCTestCase {
    func testProjectionCoversCanonicalResourceFamiliesInProtocolOrder() {
        let snapshot = fixtureSnapshot(revision: 7)
        let inventory = CodexThreadResourceProjection.project(
            snapshot: snapshot,
            threadID: "fixture-thread",
            supplementalFacts: [
                .init(
                    id: "pull-request:fixture-thread:main",
                    kind: .pullRequest,
                    title: "Pull request",
                    origin: .init(threadID: "fixture-thread"),
                    metadata: .init(url: "https://invalid.example/pr/1", branch: "main")
                ),
                .init(
                    id: "side-chat:fixture-thread:side",
                    kind: .sideChat,
                    title: "Side chat",
                    origin: .init(threadID: "fixture-thread")
                ),
            ]
        )

        XCTAssertEqual(inventory.threadID, "fixture-thread")
        XCTAssertEqual(inventory.revision, StateRevision(7))
        XCTAssertEqual(
            Set(inventory.resources.map(\.kind)),
            Set([
                .plan, .subagent, .editedFile, .outputFile, .generatedImage,
                .visualization, .artifact, .webActivity, .mcpResource, .mcpApp,
                .review, .pullRequest, .sideChat, .backgroundTerminal,
            ])
        )
        let origins = inventory.resources.compactMap { $0.origin.turnID?.rawValue }
        XCTAssertTrue(origins.allSatisfy { $0 == "fixture-turn" })
        XCTAssertTrue(inventory.resources.contains { $0.title == "fixture.swift" })
        XCTAssertTrue(inventory.resources.contains { $0.metadata.childThreadID == "child-1" })
        XCTAssertTrue(inventory.resources.contains { $0.metadata.url == "mcp://fixture/resource" })
    }

    func testStableOriginAndResourceIdentitySurviveLifecycleReplacement() {
        let threadID: ThreadID = "fixture-thread"
        let turnID: TurnID = "fixture-turn"
        let itemID: ItemID = "image-item"
        let key = ItemKey(threadID: threadID, turnID: turnID, itemID: itemID)
        let turnKey = TurnKey(threadID: threadID, turnID: turnID)
        let thread = CanonicalThread(id: threadID, turnOrder: [turnID])

        func snapshot(authority: ItemAuthority, source: String) -> CanonicalStateSnapshot {
            CanonicalStateSnapshot(
                revision: authority == .completed ? StateRevision(2) : StateRevision(1),
                threads: [threadID: thread],
                turns: [turnKey: CanonicalTurn(key: turnKey, itemOrder: [itemID])],
                items: [key: CanonicalItem(
                    key: key,
                    kind: .imageGeneration,
                    payload: ["status": .string(authority == .completed ? "completed" : "inProgress"), "result": .string(source)],
                    authority: authority
                )]
            )
        }

        let first = CodexThreadResourceProjection.project(
            snapshot: snapshot(authority: .started, source: "/workspace/partial.png"),
            threadID: threadID
        )
        let second = CodexThreadResourceProjection.project(
            snapshot: snapshot(authority: .completed, source: "/workspace/final.png"),
            threadID: threadID
        )
        let firstImage = first.resources.first { $0.kind == .generatedImage }
        let secondImage = second.resources.first { $0.kind == .generatedImage }

        XCTAssertEqual(firstImage?.id, secondImage?.id)
        XCTAssertEqual(firstImage?.origin, CodexThreadResourceOrigin(key))
        XCTAssertEqual(secondImage?.origin, CodexThreadResourceOrigin(key))
        XCTAssertEqual(secondImage?.metadata.path, "/workspace/final.png")
    }

    func testMalformedResourcesUseSafeFallbacksAndNeverDropTheMCPCall() {
        let threadID: ThreadID = "fixture-thread"
        let turnID: TurnID = "fixture-turn"
        let turnKey = TurnKey(threadID: threadID, turnID: turnID)
        let malformedMCP = ItemKey(threadID: threadID, turnID: turnID, itemID: "mcp")
        let malformedFile = ItemKey(threadID: threadID, turnID: turnID, itemID: "file")
        let snapshot = CanonicalStateSnapshot(
            revision: StateRevision(4),
            threads: [threadID: CanonicalThread(id: threadID, turnOrder: [turnID])],
            turns: [turnKey: CanonicalTurn(key: turnKey, itemOrder: [malformedMCP.itemID, malformedFile.itemID])],
            items: [
                malformedMCP: CanonicalItem(
                    key: malformedMCP,
                    kind: .mcpToolCall,
                    payload: [
                        "server": .string("fixture"),
                        "tool": .string("broken"),
                        "result": .dictionary(["content": .array([.string("not-an-object")])]),
                    ],
                    authority: .completed
                ),
                malformedFile: CanonicalItem(
                    key: malformedFile,
                    kind: .fileChange,
                    payload: ["changes": .array([.dictionary(["kind": .string("modified")])])],
                    authority: .completed
                ),
            ]
        )

        let inventory = CodexThreadResourceProjection.project(
            snapshot: snapshot,
            threadID: threadID
        )

        XCTAssertGreaterThanOrEqual(inventory.malformedResourceCount, 2)
        XCTAssertTrue(inventory.resources.contains { $0.kind == .mcpResource && $0.metadata.tool == "broken" })
        XCTAssertTrue(inventory.resources.contains { $0.kind == .editedFile })
    }

    func testInvalidationUsesCanonicalAndSupplementalRevisionOnly() {
        let snapshot = fixtureSnapshot(revision: 10)
        let input = CodexThreadResourceProjectionInput(
            snapshot: snapshot,
            threadID: "fixture-thread",
            supplementalRevision: 4
        )
        let inventory = CodexThreadResourceProjector.project(input)

        XCTAssertFalse(CodexThreadResourceProjector.isInvalidated(previous: inventory, by: input))
        XCTAssertTrue(CodexThreadResourceProjector.isInvalidated(
            previous: inventory,
            by: .init(snapshot: fixtureSnapshot(revision: 11), threadID: "fixture-thread", supplementalRevision: 4)
        ))
        XCTAssertTrue(CodexThreadResourceProjector.isInvalidated(
            previous: inventory,
            by: .init(snapshot: snapshot, threadID: "other-thread", supplementalRevision: 4)
        ))
        XCTAssertTrue(CodexThreadResourceProjector.isInvalidated(
            previous: inventory,
            by: .init(snapshot: snapshot, threadID: "fixture-thread", supplementalRevision: 5)
        ))
    }

    func testRevisionCacheMakesRepeatedViewReadsRenderNeutral() {
        let input = CodexThreadResourceProjectionInput(
            snapshot: fixtureSnapshot(revision: 12),
            threadID: "fixture-thread",
            supplementalRevision: 8
        )
        var cache = CodexThreadResourceProjectionCache()

        XCTAssertTrue(cache.apply(input))
        XCTAssertFalse(cache.apply(input))
        XCTAssertEqual(cache.projectionCount, 1)
        XCTAssertEqual(cache.cacheHitCount, 1)
        XCTAssertEqual(cache.inventory?.key.supplementalRevision, 8)

        XCTAssertTrue(cache.apply(.init(
            snapshot: fixtureSnapshot(revision: 13),
            threadID: "fixture-thread",
            supplementalRevision: 8
        )))
        XCTAssertEqual(cache.projectionCount, 2)
    }

    func testProjectionBoundsLargeBinaryMetadata() {
        let threadID: ThreadID = "fixture-thread"
        let turnID: TurnID = "fixture-turn"
        let itemID: ItemID = "image"
        let key = ItemKey(threadID: threadID, turnID: turnID, itemID: itemID)
        let payload = [
            "status": CodexJSONValue.string("completed"),
            "result": CodexJSONValue.string(String(repeating: "A", count: 20_000)),
        ]
        let snapshot = CanonicalStateSnapshot(
            revision: StateRevision(1),
            threads: [threadID: CanonicalThread(id: threadID, turnOrder: [turnID])],
            turns: [TurnKey(threadID: threadID, turnID: turnID): CanonicalTurn(
                key: TurnKey(threadID: threadID, turnID: turnID),
                itemOrder: [itemID]
            )],
            items: [key: CanonicalItem(key: key, kind: .imageGeneration, payload: payload, authority: .completed)]
        )

        let resource = CodexThreadResourceProjection.project(snapshot: snapshot, threadID: threadID)
            .resources.first { $0.kind == .generatedImage }
        XCTAssertNil(resource?.metadata.url)
        XCTAssertNil(resource?.metadata.path)
    }

    func testUnknownResourceKindDecodesLosslesslyForSafeFallbackPresentation() throws {
        let encoded = try JSONEncoder().encode(CodexThreadResourceKind(rawValue: "future-resource"))
        let decoded = try JSONDecoder().decode(CodexThreadResourceKind.self, from: encoded)
        XCTAssertEqual(decoded.rawValue, "future-resource")
        if case .unknown(let value) = decoded {
            XCTAssertEqual(value, "future-resource")
        } else {
            XCTFail("Expected unknown resource kind")
        }
    }

    func testVisualizationDirectivesAndFilesProjectAsTypedResources() {
        let threadID: ThreadID = "fixture-thread"
        let turnID: TurnID = "fixture-turn"
        let turnKey = TurnKey(threadID: threadID, turnID: turnID)
        let messageKey = ItemKey(threadID: threadID, turnID: turnID, itemID: "message")
        let fileKey = ItemKey(threadID: threadID, turnID: turnID, itemID: "file")
        let path = "/custom/codex-home/visualizations/2026/08/29/fixture-thread/path-probe.html"
        let snapshot = CanonicalStateSnapshot(
            revision: StateRevision(1),
            threads: [threadID: CanonicalThread(id: threadID, turnOrder: [turnID])],
            turns: [turnKey: CanonicalTurn(key: turnKey, itemOrder: [messageKey.itemID, fileKey.itemID])],
            items: [
                messageKey: CanonicalItem(
                    key: messageKey,
                    kind: .agentMessage,
                    payload: ["text": .string(#"visualize{"path":"\#(path)","mode":"wide"}"#)],
                    authority: .completed
                ),
                fileKey: CanonicalItem(
                    key: fileKey,
                    kind: .fileChange,
                    payload: ["changes": .array([.dictionary(["path": .string(path)])])],
                    authority: .completed
                ),
            ]
        )

        let inventory = CodexThreadResourceProjection.project(snapshot: snapshot, threadID: threadID)
        let visualizations = inventory.resources.filter { $0.kind == .visualization }

        XCTAssertEqual(visualizations.count, 1)
        XCTAssertTrue(visualizations.allSatisfy { $0.metadata.path == path })
        XCTAssertTrue(visualizations.contains { $0.metadata.statusDetail == "wide" })
        XCTAssertTrue(inventory.resources.contains { $0.kind == .editedFile })
    }

    func testVisualizationDirectiveParserRejectsTraversalAndUnsafeNames() {
        XCTAssertTrue(CodexVisualizationDirectiveProjection.directives(
            in: #"visualize{"path":"../escape.html"}"#
        ).isEmpty)
        XCTAssertTrue(CodexVisualizationDirectiveProjection.directives(
            in: #"visualize{"path":"/tmp/Unsafe Name.html"}"#
        ).isEmpty)
        XCTAssertEqual(CodexVisualizationDirectiveProjection.directives(
            in: #"::codex-inline-vis{path="/safe/render-probe.html" title="Probe" mode="wide"}"#
        ), [.init(path: "/safe/render-probe.html", title: "Probe", isWide: true)])
    }

    private func fixtureSnapshot(revision: UInt64) -> CanonicalStateSnapshot {
        let threadID: ThreadID = "fixture-thread"
        let turnID: TurnID = "fixture-turn"
        let turnKey = TurnKey(threadID: threadID, turnID: turnID)
        let thread = CanonicalThread(id: threadID, turnOrder: [turnID])
        let plan = CanonicalTurn(
            key: turnKey,
            status: .completed,
            itemOrder: [
                "spawn", "file", "image", "web", "mcp", "dynamic", "review",
            ].map { ItemID($0) },
            plan: [
                .init(step: "Inspect", status: .completed),
                .init(step: "Ship", status: .pending),
            ],
            planExplanation: "Fixture plan"
        )
        let itemKey: (String) -> ItemKey = { id in
            ItemKey(threadID: threadID, turnID: turnID, itemID: ItemID(id))
        }
        let items: [ItemKey: CanonicalItem] = [
            itemKey("spawn"): CanonicalItem(
                key: itemKey("spawn"),
                kind: .collabAgentToolCall,
                payload: [
                    "tool": .string("spawnAgent"),
                    "receiverThreadIds": .array([.string("child-1")]),
                    "agentsStates": .dictionary(["child-1": .dictionary(["status": .string("running")])]),
                ],
                authority: .completed
            ),
            itemKey("file"): CanonicalItem(
                key: itemKey("file"),
                kind: .fileChange,
                payload: ["changes": .array([.dictionary(["path": .string("Sources/fixture.swift")])])],
                authority: .completed
            ),
            itemKey("image"): CanonicalItem(
                key: itemKey("image"),
                kind: .imageGeneration,
                payload: ["status": .string("completed"), "savedPath": .string("/workspace/image.png")],
                authority: .completed
            ),
            itemKey("web"): CanonicalItem(
                key: itemKey("web"),
                kind: .webSearch,
                payload: ["query": .string("CodexCore")],
                authority: .completed
            ),
            itemKey("mcp"): CanonicalItem(
                key: itemKey("mcp"),
                kind: .mcpToolCall,
                payload: [
                    "server": .string("fixture-server"),
                    "tool": .string("lookup"),
                    "mcpAppResourceUri": .string("mcp://fixture/app"),
                    "result": .dictionary([
                        "content": .array([
                            .dictionary([
                                "type": .string("resource_link"),
                                "uri": .string("mcp://fixture/resource"),
                                "title": .string("Fixture resource"),
                            ]),
                        ]),
                    ]),
                ],
                authority: .completed
            ),
            itemKey("dynamic"): CanonicalItem(
                key: itemKey("dynamic"),
                kind: .dynamicToolCall,
                payload: [
                    "outputFiles": .array([.string("/workspace/output.md")]),
                    "visualization": .dictionary(["url": .string("mcp://fixture/chart")]),
                    "artifact": .dictionary(["url": .string("mcp://fixture/artifact"), "title": .string("Fixture artifact")]),
                ],
                authority: .completed
            ),
            itemKey("review"): CanonicalItem(
                key: itemKey("review"),
                kind: .enteredReviewMode,
                payload: ["review": .string("fixture-review")],
                authority: .completed
            ),
        ]
        return CanonicalStateSnapshot(
            revision: StateRevision(revision),
            backgroundTerminals: [threadID: .init(
                threadID: threadID,
                terminals: [
                    .init(
                        processID: "process-1",
                        command: "swift test",
                        cwd: .string("/workspace"),
                        itemID: "spawn"
                    ),
                ]
            )],
            threads: [threadID: thread],
            turns: [turnKey: plan],
            items: items
        )
    }
}
