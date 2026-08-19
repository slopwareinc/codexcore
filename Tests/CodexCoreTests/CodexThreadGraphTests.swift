import XCTest

@testable import CodexCore

final class CodexThreadGraphTests: XCTestCase {
    func testNestedGraphReconcilesMetadataAndCollaborationOutOfOrder() throws {
        let snapshot = makeSnapshot(
            threadOrder: ["c", "a", "b"],
            threads: [
                thread("c", parent: "b", loaded: false),
                thread("a", loaded: true),
                thread("b", parent: "a", loaded: true),
            ],
            items: [
                collabItem(
                    parent: "a",
                    turn: "turn-a",
                    item: "spawn-b",
                    receivers: ["b"],
                    status: "completed",
                    agentStates: ["b": ("running", nil)]
                ),
                collabItem(
                    parent: "b",
                    turn: "turn-b",
                    item: "spawn-c",
                    receivers: ["c"],
                    status: "completed",
                    agentStates: ["c": ("pendingInit", "booting")]
                ),
            ]
        )

        let graph = CodexThreadGraphProjector.project(snapshot, hostID: "host")
        let a = key("a")
        let b = key("b")
        let c = key("c")
        XCTAssertEqual(graph.roots, [a])
        XCTAssertEqual(graph.nodes[a]?.children, [b])
        XCTAssertEqual(graph.nodes[b]?.children, [c])
        XCTAssertEqual(graph.nodes[c]?.depth, 2)
        XCTAssertEqual(graph.nodes[c]?.lifecycle, .pendingInit)
        XCTAssertEqual(graph.descendants(of: a), [b, c])
    }

    func testEveryWireLifecycleAndMessageRemainsExact() {
        let states = [
            "pendingInit", "running", "completed", "interrupted",
            "shutdown", "errored", "notFound", "futureState",
        ]
        let items = states.enumerated().map { index, state in
            collabItem(
                parent: "parent",
                turn: "turn",
                item: ItemID("item-\(index)"),
                receivers: [ThreadID("child-\(index)")],
                status: index == 5 ? "failed" : "completed",
                agentStates: ["child-\(index)": (state, "message-\(index)")]
            )
        }
        let snapshot = makeSnapshot(
            threadOrder: ["parent"],
            threads: [thread("parent")],
            items: items
        )
        let graph = CodexThreadGraphProjector.project(snapshot, hostID: "host")

        XCTAssertEqual(graph.nodes[key("child-0")]?.lifecycle, .pendingInit)
        XCTAssertEqual(graph.nodes[key("child-1")]?.lifecycle, .running)
        XCTAssertEqual(graph.nodes[key("child-2")]?.resultMessage, "message-2")
        XCTAssertEqual(graph.nodes[key("child-3")]?.lifecycle, .interrupted)
        XCTAssertEqual(graph.nodes[key("child-4")]?.lifecycle, .shutdown)
        XCTAssertEqual(graph.nodes[key("child-5")]?.errorMessage, "message-5")
        XCTAssertEqual(graph.nodes[key("child-6")]?.lifecycle, .notFound)
        XCTAssertEqual(graph.nodes[key("child-7")]?.lifecycle, .unknown("futureState"))
    }

    func testStartedAndCompletedAuthorityProduceOneStableActionIdentity() {
        let itemKey = ItemKey(threadID: "parent", turnID: "turn", itemID: "call")
        var started = collabItem(
            parent: "parent",
            turn: "turn",
            item: "call",
            receivers: ["child"],
            status: "inProgress",
            agentStates: ["child": ("pendingInit", nil)]
        )
        started = CanonicalItem(
            key: itemKey,
            kind: started.kind,
            payload: started.payload,
            authority: .started,
            startedAt: .init(10)
        )
        let completed = CanonicalItem(
            key: itemKey,
            kind: .collabAgentToolCall,
            payload: collabPayload(
                parent: "parent",
                receivers: ["child"],
                status: "completed",
                agentStates: ["child": ("completed", "done")]
            ),
            authority: .completed,
            startedAt: .init(10),
            completedAt: .init(20)
        )

        let first = CodexThreadGraphProjector.project(
            makeSnapshot(threadOrder: ["parent"], threads: [thread("parent")], items: [started]),
            hostID: "host"
        )
        let second = CodexThreadGraphProjector.project(
            makeSnapshot(threadOrder: ["parent"], threads: [thread("parent")], items: [completed]),
            hostID: "host"
        )
        XCTAssertEqual(first.actions.count, 1)
        XCTAssertEqual(second.actions.count, 1)
        XCTAssertEqual(first.actions[0].id, second.actions[0].id)
        XCTAssertEqual(first.actions[0].status, .inProgress)
        XCTAssertEqual(second.actions[0].status, .completed)
        XCTAssertEqual(second.actions[0].completedAt, .init(20))
    }

    func testCyclesAreReportedAndTraversalTerminates() {
        let snapshot = makeSnapshot(
            threadOrder: ["a", "b", "c"],
            threads: [
                thread("a", parent: "c"),
                thread("b", parent: "a"),
                thread("c", parent: "b"),
            ],
            items: []
        )
        let graph = CodexThreadGraphProjector.project(snapshot, hostID: "host")

        XCTAssertEqual(graph.cycleEdges.count, 1)
        XCTAssertEqual(Set(graph.descendants(of: key("a"))), Set([key("b"), key("c")]))
        XCTAssertEqual(graph.descendants(of: key("a")).count, 2)
    }

    func testSubAgentActivityCreatesPartialEdgeBeforeChildHydration() {
        let item = CanonicalItem(
            key: .init(threadID: "parent", turnID: "turn", itemID: "activity"),
            kind: .subAgentActivity,
            payload: [
                "agentThreadId": .string("child"),
                "agentPath": .string("/root/child"),
                "kind": .string("started"),
                "type": .string("subAgentActivity"),
            ],
            authority: .completed,
            consistency: .partial
        )
        let graph = CodexThreadGraphProjector.project(
            makeSnapshot(threadOrder: ["parent"], threads: [thread("parent")], items: [item]),
            hostID: "host"
        )

        XCTAssertEqual(graph.nodes[key("child")]?.parent, key("parent"))
        XCTAssertEqual(graph.nodes[key("child")]?.lifecycle, .running)
        XCTAssertFalse(graph.nodes[key("child")]?.isLoaded ?? true)
    }

    func testThreadStoragePathNeverBecomesLogicalAgentPath() {
        let child = CanonicalThread(
            id: "child",
            metadata: .init(
                agentNickname: "Cicero",
                parentThreadID: "parent",
                path: "/Users/test/.codex/sessions/rollout-child.jsonl",
                source: .dictionary([
                    "thread_spawn": .dictionary([
                        "agent_path": .string("/root/extra_subagent_4"),
                    ]),
                ])
            ),
            status: .idle,
            isLoaded: true,
            consistency: .authoritative
        )
        let graph = CodexThreadGraphProjector.project(
            makeSnapshot(
                threadOrder: ["parent", "child"],
                threads: [thread("parent"), child],
                items: []
            ),
            hostID: "host"
        )

        XCTAssertEqual(graph.nodes[key("child")]?.agentPath, "/root/extra_subagent_4")
    }

    func testPartialThreadOrderUsesStableSortedFallbackForGraphAndItems() {
        let graph = CodexThreadGraphProjector.project(
            makeSnapshot(
                threadOrder: ["root"],
                threads: [
                    thread("z", parent: "root"),
                    thread("root"),
                    thread("a", parent: "root"),
                ],
                items: [
                    collabItem(
                        parent: "z",
                        turn: "turn-z",
                        item: "item-z",
                        receivers: [],
                        status: "completed",
                        agentStates: [:]
                    ),
                    collabItem(
                        parent: "a",
                        turn: "turn-a",
                        item: "item-a",
                        receivers: [],
                        status: "completed",
                        agentStates: [:]
                    ),
                ]
            ),
            hostID: "host"
        )

        XCTAssertEqual(graph.nodes[key("root")]?.children, [key("a"), key("z")])
        XCTAssertEqual(
            graph.actions.map { $0.sourceItem.threadID },
            [ThreadID("a"), ThreadID("z")]
        )
    }

    func testDuplicateThreadOrderEntriesDoNotChangeProjection() {
        let threads = [
            thread("root"),
            thread("child", parent: "root"),
        ]
        let uniqueGraph = CodexThreadGraphProjector.project(
            makeSnapshot(threadOrder: ["root", "child"], threads: threads, items: []),
            hostID: "host"
        )
        let duplicateGraph = CodexThreadGraphProjector.project(
            makeSnapshot(
                threadOrder: ["root", "root", "child", "root", "child"],
                threads: threads,
                items: []
            ),
            hostID: "host"
        )

        XCTAssertEqual(duplicateGraph, uniqueGraph)
    }

    func testWaitTargetDeduplicationPreservesFirstOccurrenceOrder() {
        let first = key("first")
        let second = key("second")

        XCTAssertEqual(
            CodexThreadGraphService.stableUniqueTargets([
                first, second, first, first, second,
            ]),
            [first, second]
        )
    }
}

extension CodexThreadGraphTests {
    fileprivate func key(_ id: String) -> CodexThreadGraphKey {
        .init(hostID: "host", threadID: ThreadID(id))
    }

    fileprivate func thread(
        _ id: ThreadID,
        parent: ThreadID? = nil,
        loaded: Bool = false
    ) -> CanonicalThread {
        CanonicalThread(
            id: id,
            metadata: .init(parentThreadID: parent),
            status: loaded ? .idle : .notLoaded,
            isLoaded: loaded,
            consistency: loaded ? .authoritative : .partial
        )
    }

    fileprivate func makeSnapshot(
        threadOrder: [ThreadID],
        threads: [CanonicalThread],
        items: [CanonicalItem]
    ) -> CanonicalStateSnapshot {
        var turns: [TurnKey: CanonicalTurn] = [:]
        var threadMap = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        for group in Dictionary(grouping: items, by: { $0.key.turnKey }) {
            turns[group.key] = CanonicalTurn(
                key: group.key,
                status: .completed,
                itemOrder: group.value.map { $0.key.itemID },
                itemsCoverage: .full,
                itemsConsistency: .authoritative
            )
            if var thread = threadMap[group.key.threadID] {
                thread = CanonicalThread(
                    id: thread.id,
                    metadata: thread.metadata,
                    status: thread.status,
                    turnOrder: [group.key.turnID],
                    isLoaded: thread.isLoaded,
                    consistency: thread.consistency
                )
                threadMap[thread.id] = thread
            }
        }
        return .init(
            revision: .init(42),
            threadOrder: threadOrder,
            threads: threadMap,
            turns: turns,
            items: Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })
        )
    }

    fileprivate func collabItem(
        parent: ThreadID,
        turn: TurnID,
        item: ItemID,
        receivers: [ThreadID],
        status: String,
        agentStates: [String: (String, String?)]
    ) -> CanonicalItem {
        CanonicalItem(
            key: .init(threadID: parent, turnID: turn, itemID: item),
            kind: .collabAgentToolCall,
            payload: collabPayload(
                parent: parent.rawValue,
                receivers: receivers.map(\.rawValue),
                status: status,
                agentStates: agentStates
            ),
            authority: status == "inProgress" ? .started : .completed,
            consistency: .authoritative
        )
    }

    fileprivate func collabPayload(
        parent: String,
        receivers: [String],
        status: String,
        agentStates: [String: (String, String?)]
    ) -> [String: CodexJSONValue] {
        var states: [String: CodexJSONValue] = [:]
        for (id, state) in agentStates {
            states[id] = .dictionary([
                "status": .string(state.0),
                "message": state.1.map(CodexJSONValue.string) ?? .null,
            ])
        }
        return [
            "type": .string("collabAgentToolCall"),
            "tool": .string("spawnAgent"),
            "status": .string(status),
            "senderThreadId": .string(parent),
            "receiverThreadIds": .array(receivers.map(CodexJSONValue.string)),
            "prompt": .string("work"),
            "model": .string("gpt"),
            "reasoningEffort": .string("high"),
            "agentsStates": .dictionary(states),
        ]
    }
}
