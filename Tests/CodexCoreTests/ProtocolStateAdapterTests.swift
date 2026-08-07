import XCTest
@testable import CodexCore

final class ProtocolStateAdapterTests: XCTestCase {
    private let adapter = ProtocolStateAdapter()

    func testGA145NotificationDispositionInventoryIsExhaustive() throws {
        XCTAssertEqual(
            CodexAppServerNotificationMethod.allCases.count,
            CodexAppServerProtocolInventory.notificationMethodCount
        )
        XCTAssertEqual(CodexAppServerProtocolInventory.notificationMethodCount, 70)
        XCTAssertEqual(
            Set(CodexAppServerNotificationMethod.allCases.map(\.rawValue)).count,
            CodexAppServerNotificationMethod.allCases.count
        )

        for method in CodexAppServerNotificationMethod.allCases {
            let expected = expectedDisposition(for: method)
            do {
                let adaptation = try adapter.adaptNotification(method: method, params: [:])
                XCTAssertEqual(adaptation.disposition, expected, method.rawValue)
            } catch let error as ProtocolStateAdapterError {
                // State and diagnostic methods validate their payload before
                // returning a disposition. Operation-only and resolution
                // methods must not decode the empty inventory probe.
                XCTAssertTrue(
                    expected == .state || expected == .diagnostic,
                    "Unexpected decode for \(method.rawValue): \(error)"
                )
            }
        }
    }

    func testEveryGA145StateNotificationHasAValidFixtureAndProducesAMutation() throws {
        let fixtures = try stateNotificationFixtures()
        let stateMethods = Set(CodexAppServerNotificationMethod.allCases.filter {
            expectedDisposition(for: $0) == .state
        })

        XCTAssertEqual(fixtures.count, 42)
        XCTAssertEqual(
            Set(fixtures.keys),
            stateMethods,
            "The fixture inventory must change whenever the exhaustive disposition switch changes"
        )

        for method in CodexAppServerNotificationMethod.allCases where stateMethods.contains(method) {
            let params = try XCTUnwrap(fixtures[method], "Missing 0.145.0 GA fixture for \(method.rawValue)")
            let adaptation = try adapter.adaptNotification(method: method, params: params)

            XCTAssertEqual(adaptation.disposition, .state, method.rawValue)
            XCTAssertFalse(
                adaptation.mutations.isEmpty,
                "State notification \(method.rawValue) must produce at least one canonical mutation"
            )
        }
    }

    func testThreadStartedBuildsAuthoritativeLosslessSnapshot() throws {
        let params = try objectFixture(
            #"""
            {
              "thread": {
                "cliVersion": "0.145.0-alpha.20",
                "canAcceptDirectInput": false,
                "createdAt": 1700000000,
                "cwd": "/tmp/project",
                "ephemeral": false,
                "historyMode": "paginated",
                "id": "thread-1",
                "modelProvider": "openai",
                "name": "Fixture thread",
                "preview": "hello",
                "sessionId": "session-1",
                "source": "cli",
                "status": {
                  "type": "active",
                  "activeFlags": ["waitingOnApproval", "futureFlag"]
                },
                "turns": [
                  {
                    "id": "turn-1",
                    "items": [
                      {
                        "type": "futureWidget",
                        "id": "item-1",
                        "nested": {"value": 7},
                        "futureItemField": true
                      }
                    ],
                    "itemsView": "full",
                    "startedAt": 1700000001,
                    "status": "inProgress",
                    "futureTurnField": "kept"
                  }
                ],
                "updatedAt": 1700000002,
                "futureThreadField": {"version": 2}
              }
            }
            """#
        )

        let adaptation = try adapter.adaptNotification(method: .threadStarted, params: params)

        XCTAssertEqual(adaptation.disposition, .state)
        XCTAssertEqual(adaptation.mutations.count, 2)

        guard case .threadSnapshotReplaced(let thread) = adaptation.mutations[0] else {
            return XCTFail("Expected authoritative thread snapshot")
        }
        XCTAssertEqual(thread.id, "thread-1")
        XCTAssertEqual(thread.metadata.name, "Fixture thread")
        XCTAssertEqual(thread.metadata.canAcceptDirectInput, false)
        XCTAssertEqual(thread.metadata.cwd, .string("/tmp/project"))
        XCTAssertEqual(thread.history.mode, .paginated)
        XCTAssertEqual(thread.isLoaded, true)
        XCTAssertEqual(thread.consistency, .authoritative)
        XCTAssertEqual(
            thread.metadata.extensions["futureThreadField"],
            .dictionary(["version": .int(2)])
        )
        XCTAssertNil(thread.metadata.extensions["canAcceptDirectInput"])
        guard case .active(let flags) = thread.status else {
            return XCTFail("Expected active thread status")
        }
        XCTAssertEqual(flags, [.waitingOnApproval, .unknown("futureFlag")])

        guard case .turnSnapshot(let turn, let items, let policy) = adaptation.mutations[1] else {
            return XCTFail("Expected turn snapshot")
        }
        XCTAssertEqual(turn.key, TurnKey(threadID: "thread-1", turnID: "turn-1"))
        XCTAssertEqual(turn.itemsCoverage, .full)
        XCTAssertEqual(turn.extensions["futureTurnField"], .string("kept"))
        XCTAssertEqual(policy, .mergePreservingExistingOrder)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .unknown("futureWidget"))
        XCTAssertEqual(items[0].key.itemID, "item-1")
        XCTAssertEqual(items[0].payload["futureItemField"], .bool(true))
        XCTAssertEqual(items[0].payload["nested"], .dictionary(["value": .int(7)]))
    }

    func testDeltaFixturesPreserveExactCoordinatesAndRepeatedChunks() throws {
        let params = try objectFixture(
            #"{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","delta":"same"}"#
        )

        let first = try adapter.adaptNotification(method: .itemAgentMessageDelta, params: params)
        let second = try adapter.adaptNotification(method: .itemAgentMessageDelta, params: params)

        let expected = CanonicalStateMutation.itemDelta(
            key: ItemKey(threadID: "thread-1", turnID: "turn-1", itemID: "item-1"),
            delta: .agentMessage("same")
        )
        XCTAssertEqual(first.mutations, [expected])
        XCTAssertEqual(second.mutations, [expected])

        let terminal = try adapter.adaptNotification(
            method: .itemCommandExecutionTerminalInteraction,
            params: objectFixture(
                #"{"threadId":"thread-1","turnId":"turn-1","itemId":"item-2","processId":"42","stdin":"yes\n"}"#
            )
        )
        XCTAssertEqual(
            terminal.mutations,
            [.itemDelta(
                key: ItemKey(threadID: "thread-1", turnID: "turn-1", itemID: "item-2"),
                delta: .terminalInteraction(processID: "42", stdin: "yes\n")
            )]
        )
    }

    func testItemCompletionKeepsMillisecondAuthorityAndAdditivePayload() throws {
        let adaptation = try adapter.adaptNotification(
            method: .itemCompleted,
            params: objectFixture(
                #"{"threadId":"thread-1","turnId":"turn-1","completedAtMs":1700000000123,"item":{"type":"agentMessage","id":"message-1","text":"done","futurePayload":{"v":1}}}"#
            )
        )

        guard case .itemCompleted(let item) = try XCTUnwrap(adaptation.mutations.first) else {
            return XCTFail("Expected completed item")
        }
        XCTAssertEqual(item.key, ItemKey(threadID: "thread-1", turnID: "turn-1", itemID: "message-1"))
        XCTAssertEqual(item.kind, .agentMessage)
        XCTAssertEqual(item.authority, .completed)
        XCTAssertEqual(item.completedAt, ProtocolMilliseconds(1_700_000_000_123))
        XCTAssertEqual(item.consistency, .authoritative)
        XCTAssertEqual(item.payload["futurePayload"], .dictionary(["v": .int(1)]))
    }

    func testTerminalSummaryItemDoesNotOverwriteAFullLivePayload() throws {
        let adaptation = try adapter.adaptNotification(
            method: .turnCompleted,
            params: objectFixture(
                #"{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed","itemsView":"summary","items":[{"type":"agentMessage","id":"message-1","text":"summary"}]}}"#
            )
        )

        guard case .turnCompleted(let turn, let items, let policy) = try XCTUnwrap(
            adaptation.mutations.first
        ) else {
            return XCTFail("Expected completed turn")
        }
        XCTAssertEqual(turn.itemsCoverage, .summary)
        XCTAssertEqual(turn.itemsConsistency, .partial)
        XCTAssertEqual(items.first?.authority, .completed)
        XCTAssertEqual(items.first?.consistency, .partial)
        XCTAssertEqual(policy, .mergePreservingExistingOrder)
    }

    func testLifecycleFixturesRemainTypedAndSparse() throws {
        XCTAssertEqual(
            try adapter.adaptNotification(
                method: .threadArchived,
                params: objectFixture(#"{"threadId":"thread-1"}"#)
            ).mutations,
            [.threadLifecycleUpdated(
                id: "thread-1",
                isArchived: .set(true),
                isLoaded: .unchanged
            )]
        )
        XCTAssertEqual(
            try adapter.adaptNotification(
                method: .threadEnvironmentConnected,
                params: objectFixture(#"{"threadId":"thread-1","environmentId":"env-1"}"#)
            ).mutations,
            [.threadEnvironmentConnection(id: "thread-1", environmentID: "env-1", connected: true)]
        )
        XCTAssertEqual(
            try adapter.adaptNotification(
                method: .threadNameUpdated,
                params: objectFixture(#"{"threadId":"thread-1","threadName":null}"#)
            ).mutations,
            [.threadNameReplaced(id: "thread-1", name: nil)]
        )
        XCTAssertEqual(
            try adapter.adaptNotification(
                method: .threadDeleted,
                params: objectFixture(#"{"threadId":"thread-1"}"#)
            ).mutations,
            [.threadRemoved("thread-1")]
        )
    }

    func testAccountPlanAndUsageFixturesProduceCanonicalMutations() throws {
        let account = try adapter.adaptNotification(
            method: .accountUpdated,
            params: objectFixture(
                #"{"authMode":"chatgpt","planType":"plus","futureAccountField":7}"#
            )
        )
        guard case .accountPatched(let patch) = try XCTUnwrap(account.mutations.first) else {
            return XCTFail("Expected account patch")
        }
        XCTAssertEqual(patch.authMode, .set("chatgpt"))
        XCTAssertEqual(patch.planType, .set("plus"))
        XCTAssertEqual(patch.extensions["futureAccountField"], .int(7))

        let clearedAccount = try adapter.adaptNotification(
            method: .accountUpdated,
            params: objectFixture(#"{"authMode":null,"planType":null}"#)
        )
        guard case .accountPatched(let clearedPatch) = try XCTUnwrap(clearedAccount.mutations.first) else {
            return XCTFail("Expected cleared account patch")
        }
        XCTAssertEqual(clearedPatch.authMode, .clear)
        XCTAssertEqual(clearedPatch.planType, .clear)

        let futureAccount = try adapter.adaptNotification(
            method: .accountUpdated,
            params: objectFixture(#"{"authMode":"futureAuth","planType":"futurePlan"}"#)
        )
        guard case .accountPatched(let futurePatch) = try XCTUnwrap(futureAccount.mutations.first) else {
            return XCTFail("Expected forward-compatible account patch")
        }
        XCTAssertEqual(futurePatch.authMode, .set("futureAuth"))
        XCTAssertEqual(futurePatch.planType, .set("futurePlan"))

        let plan = try adapter.adaptNotification(
            method: .turnPlanUpdated,
            params: objectFixture(
                #"{"threadId":"thread-1","turnId":"turn-1","explanation":"why","plan":[{"step":"inspect","status":"completed"},{"step":"build","status":"inProgress"}]}"#
            )
        )
        XCTAssertEqual(
            plan.mutations,
            [.planReplaced(
                turn: TurnKey(threadID: "thread-1", turnID: "turn-1"),
                steps: [
                    CanonicalPlanStep(step: "inspect", status: .completed),
                    CanonicalPlanStep(step: "build", status: .inProgress),
                ],
                explanation: "why"
            )]
        )

        let usage = try adapter.adaptNotification(
            method: .threadTokenUsageUpdated,
            params: objectFixture(
                #"""
                {
                  "threadId":"thread-1",
                  "turnId":"turn-1",
                  "tokenUsage":{
                    "last":{
                      "inputTokens":1,
                      "cacheWriteInputTokens":5,
                      "cachedInputTokens":2,
                      "outputTokens":3,
                      "reasoningOutputTokens":4,
                      "totalTokens":10
                    },
                    "total":{
                      "inputTokens":11,
                      "cachedInputTokens":12,
                      "outputTokens":13,
                      "reasoningOutputTokens":14,
                      "totalTokens":50
                    },
                    "modelContextWindow":200000
                  }
                }
                """#
            )
        )
        guard case .tokenUsageReplaced(let turn, let tokenUsage) = try XCTUnwrap(usage.mutations.first) else {
            return XCTFail("Expected token-usage replacement")
        }
        XCTAssertEqual(turn, TurnKey(threadID: "thread-1", turnID: "turn-1"))
        XCTAssertEqual(tokenUsage.last.totalTokens, 10)
        XCTAssertEqual(tokenUsage.last.cacheWriteInputTokens, 5)
        XCTAssertEqual(tokenUsage.total.totalTokens, 50)
        XCTAssertEqual(tokenUsage.modelContextWindow, 200_000)
    }

    func testRawAlphaUnionsPreserveFutureGoalAndPlanStatuses() throws {
        let goal = try adapter.adaptNotification(
            method: .threadGoalUpdated,
            params: objectFixture(
                #"{"threadId":"thread-1","goal":{"threadId":"thread-1","objective":"ship","status":"futureStatus","tokensUsed":4,"timeUsedSeconds":5,"createdAt":6,"updatedAt":7,"futureGoalField":true}}"#
            )
        )
        guard case .threadGoalReplaced(_, let canonicalGoal) = try XCTUnwrap(goal.mutations.first),
              let canonicalGoal else {
            return XCTFail("Expected canonical goal")
        }
        XCTAssertEqual(canonicalGoal.status, .unknown("futureStatus"))
        XCTAssertEqual(canonicalGoal.extensions["futureGoalField"], .bool(true))

        let plan = try adapter.adaptNotification(
            method: .turnPlanUpdated,
            params: objectFixture(
                #"{"threadId":"thread-1","turnId":"turn-1","plan":[{"step":"future","status":"futureStatus"}]}"#
            )
        )
        guard case .planReplaced(_, let steps, _) = try XCTUnwrap(plan.mutations.first) else {
            return XCTFail("Expected canonical plan")
        }
        XCTAssertEqual(steps, [CanonicalPlanStep(step: "future", status: .unknown("futureStatus"))])
    }

    func testSuccessfulCorrelatedLifecycleResponsesCommitBeforeContinuation() throws {
        let archive = try adapter.adaptResponse(
            ProtocolResponseContext(
                method: .threadArchive,
                requestParams: ["threadId": .string("thread-1")],
                connectionEpoch: 1
            ),
            result: .dictionary([:])
        )
        XCTAssertEqual(archive.mutations, [.threadLifecycleUpdated(
            id: "thread-1",
            isArchived: .set(true),
            isLoaded: .unchanged
        )])

        let rename = try adapter.adaptResponse(
            ProtocolResponseContext(
                method: .threadNameSet,
                requestParams: [
                    "threadId": .string("thread-1"),
                    "name": .string("Renamed"),
                ],
                connectionEpoch: 1
            ),
            result: .dictionary([:])
        )
        XCTAssertEqual(rename.mutations, [.threadNameReplaced(id: "thread-1", name: "Renamed")])

        let deleted = try adapter.adaptResponse(
            ProtocolResponseContext(
                method: .threadDelete,
                requestParams: ["threadId": .string("thread-1")],
                connectionEpoch: 1
            ),
            result: .dictionary([:])
        )
        XCTAssertEqual(deleted.mutations, [.threadRemoved("thread-1")])
    }

    func testBackgroundTerminalResponsesBecomeTypedCanonicalMutations() throws {
        let list = try adapter.adaptResponse(
            ProtocolResponseContext(
                method: .threadBackgroundTerminalsList,
                requestParams: ["threadId": .string("thread-1")],
                connectionEpoch: 1
            ),
            result: valueFixture(#"""
            {
              "data": [{
                "command": "sleep 10",
                "cpuPercent": 1.5,
                "cwd": "/tmp/project",
                "itemId": "item-1",
                "osPid": 42,
                "processId": "process-1",
                "rssKb": 128
              }],
              "nextCursor": "next"
            }
            """#)
        )
        XCTAssertEqual(list.mutations, [.backgroundTerminalsPage(
            threadID: "thread-1",
            terminals: [CanonicalBackgroundTerminal(
                processID: "process-1",
                command: "sleep 10",
                cwd: .string("/tmp/project"),
                itemID: "item-1",
                osPID: 42,
                cpuPercent: 1.5,
                rssKB: 128
            )],
            nextCursor: "next",
            replacesExisting: true
        )])

        let terminated = try adapter.adaptResponse(
            ProtocolResponseContext(
                method: .threadBackgroundTerminalsTerminate,
                requestParams: [
                    "threadId": .string("thread-1"),
                    "processId": .string("process-1"),
                ],
                connectionEpoch: 1
            ),
            result: .dictionary(["terminated": .bool(true)])
        )
        XCTAssertEqual(terminated.mutations, [
            .backgroundTerminalRemoved(threadID: "thread-1", processID: "process-1")
        ])

        let clean = try adapter.adaptResponse(
            ProtocolResponseContext(
                method: .threadBackgroundTerminalsClean,
                requestParams: ["threadId": .string("thread-1")],
                connectionEpoch: 1
            ),
            result: .null
        )
        XCTAssertEqual(clean.mutations, [.backgroundTerminalsRemoved(threadID: "thread-1")])
    }

    func testBackgroundTerminalListCursorAppendsInsteadOfReplacing() throws {
        let adaptation = try adapter.adaptResponse(
            ProtocolResponseContext(
                method: .threadBackgroundTerminalsList,
                requestParams: [
                    "threadId": .string("thread-1"),
                    "cursor": .string("older"),
                ],
                connectionEpoch: 1
            ),
            result: .dictionary(["data": .array([]), "nextCursor": .null])
        )
        XCTAssertEqual(adaptation.mutations, [.backgroundTerminalsPage(
            threadID: "thread-1",
            terminals: [],
            nextCursor: nil,
            replacesExisting: false
        )])
    }

    func testUnknownUnsubscribeStatusFailsClosed() {
        let context = ProtocolResponseContext(
            method: .threadUnsubscribe,
            requestParams: ["threadId": .string("thread-1")],
            connectionEpoch: 1
        )

        XCTAssertThrowsError(
            try adapter.adaptResponse(
                context,
                result: .dictionary(["status": .string("stillSubscribed")])
            )
        ) { error in
            XCTAssertEqual(
                error as? ProtocolStateAdapterError,
                .malformedResponse(
                    method: CodexAppServerClientMethod.threadUnsubscribe.rawValue,
                    message: "unrecognized unsubscribe status stillSubscribed"
                )
            )
        }
    }

    func testSuccessfulUnsubscribeIsValidatedWithoutInventingLifecycleState() throws {
        let adaptation = try adapter.adaptResponse(
            ProtocolResponseContext(
                method: .threadUnsubscribe,
                requestParams: ["threadId": .string("thread-1")],
                connectionEpoch: 1
            ),
            result: .dictionary(["status": .string("unsubscribed")])
        )

        XCTAssertEqual(adaptation.disposition, .ignored)
        XCTAssertTrue(adaptation.mutations.isEmpty)
    }

    func testEmptyCompleteItemPageCanAuthoritativelyClearARequestedTurn() throws {
        let context = ProtocolResponseContext(
            method: .threadItemsList,
            requestParams: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
            ],
            connectionEpoch: 1,
            itemCollectionPolicy: .authoritativeReplacement
        )

        let adaptation = try adapter.adaptResponse(
            context,
            result: .dictionary([
                "data": .array([]),
                "backwardsCursor": .null,
                "nextCursor": .null,
            ])
        )

        guard case .turnSnapshot(let turn, let items, let policy) = try XCTUnwrap(
            adaptation.mutations.first
        ) else {
            return XCTFail("Expected an empty authoritative turn snapshot")
        }
        XCTAssertEqual(turn.key, TurnKey(threadID: "thread-1", turnID: "turn-1"))
        XCTAssertEqual(turn.itemsCoverage, .full)
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(policy, .authoritativeReplacement)
    }

    func testRollbackResponseUsesTheOnlyDestructiveThreadSnapshotMutation() throws {
        let resumeObject = try objectFixture(resumeResponseJSON(includeItemsCursor: true))
        let thread = try XCTUnwrap(resumeObject["thread"])
        let adaptation = try adapter.adaptResponse(
            ProtocolResponseContext(
                method: .threadRollback,
                requestParams: ["threadId": .string("thread-1")],
                connectionEpoch: 1
            ),
            result: .dictionary(["thread": thread])
        )

        guard case .threadRollbackReplaced(let snapshot, let turns, let items) = try XCTUnwrap(
            adaptation.mutations.first
        ) else {
            return XCTFail("Expected authoritative rollback replacement")
        }
        XCTAssertEqual(snapshot.id, "thread-1")
        XCTAssertTrue(turns.isEmpty)
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(adaptation.mutations.count, 1)
    }

    func testPaginatedItemPagesNeverDestructivelyReplaceAnIncompleteChain() throws {
        let context = ProtocolResponseContext(
            method: .threadItemsList,
            requestParams: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "cursor": .string("older-page"),
            ],
            connectionEpoch: 1,
            itemCollectionPolicy: .authoritativeReplacement
        )
        let result = try valueFixture(
            #"{"data":[{"turnId":"turn-1","item":{"type":"agentMessage","id":"item-1","text":"page"}}],"nextCursor":"still-older"}"#
        )

        let adaptation = try adapter.adaptResponse(context, result: result)
        guard case .turnSnapshot(let turn, _, let policy) = try XCTUnwrap(
            adaptation.mutations.first
        ) else {
            return XCTFail("Expected paginated turn snapshot")
        }
        XCTAssertEqual(turn.itemsCoverage, .summary)
        XCTAssertEqual(policy, .mergePreservingExistingOrder)

        let finalContext = ProtocolResponseContext(
            method: .threadItemsList,
            requestParams: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "cursor": .string("final-page"),
            ],
            connectionEpoch: 1,
            itemCollectionPolicy: .mergeIncomingFirst,
            assertedItemsCoverage: .full
        )
        let final = try adapter.adaptResponse(
            finalContext,
            result: .dictionary(["data": .array([]), "nextCursor": .null])
        )
        guard case .turnSnapshot(let finalTurn, _, let finalPolicy) = try XCTUnwrap(
            final.mutations.first
        ) else {
            return XCTFail("Expected final paginated turn snapshot")
        }
        XCTAssertEqual(finalTurn.itemsCoverage, .full)
        XCTAssertEqual(finalPolicy, .mergeIncomingFirst)
    }

    func testResumeResponseInstallsCursorCutAndMarksActivePageUncertain() throws {
        let context = ProtocolResponseContext(
            method: .threadResume,
            requestParams: ["threadId": .string("thread-1")],
            connectionEpoch: 9,
            resumeGeneration: 3
        )
        let result = try valueFixture(resumeResponseJSON(includeItemsCursor: true))

        let adaptation = try adapter.adaptResponse(context, result: result)

        XCTAssertEqual(adaptation.disposition, .state)
        let history = try XCTUnwrap(adaptation.mutations.compactMap { mutation -> CanonicalHistoryState? in
            guard case .threadHistoryReplaced(let id, let history) = mutation, id == "thread-1" else {
                return nil
            }
            return history
        }.first)
        XCTAssertEqual(history.resumeCut?.connectionEpoch, 9)
        XCTAssertEqual(history.resumeCut?.resumeGeneration, 3)
        XCTAssertEqual(history.resumeCut?.turnsBackwardsCursor, "turn-head")
        XCTAssertNil(history.resumeCut?.itemsBackwardsCursor)
        XCTAssertEqual(history.turnsPage.backwardsCursor, "page-head")
        XCTAssertEqual(history.turnsPage.nextCursor, "older-page")
        XCTAssertFalse(history.turnsPage.isExhausted)

        let settings = try XCTUnwrap(adaptation.mutations.compactMap { mutation -> [String: CodexJSONValue]? in
            guard case .threadSettingsReplaced(let id, let settings) = mutation, id == "thread-1" else {
                return nil
            }
            return settings
        }.first)
        XCTAssertEqual(settings["approvalPolicy"], .string("never"))
        XCTAssertEqual(settings["model"], .string("gpt-test"))
        XCTAssertNotNil(settings["sandbox"])
        XCTAssertNil(settings["thread"])
        XCTAssertNil(settings["initialTurnsPage"])

        XCTAssertTrue(adaptation.mutations.contains { mutation in
            guard case .turnItemsMarkedUncertain(let key) = mutation else { return false }
            return key == TurnKey(threadID: "thread-1", turnID: "active-turn")
        })
    }

    func testResumeResponseAllowsOmittedOptionalCursorKeys() throws {
        let context = ProtocolResponseContext(
            method: .threadResume,
            connectionEpoch: 1
        )
        var response = try objectFixture(
            resumeResponseJSON(includeItemsCursor: false)
        )
        response.removeValue(forKey: "turnsBackwardsCursor")

        let adaptation = try adapter.adaptResponse(
            context,
            result: .dictionary(response)
        )
        let history = try XCTUnwrap(adaptation.mutations.compactMap { mutation -> CanonicalHistoryState? in
            guard case .threadHistoryReplaced(_, let history) = mutation else { return nil }
            return history
        }.first)
        XCTAssertNil(history.resumeCut?.turnsBackwardsCursor)
        XCTAssertNil(history.resumeCut?.itemsBackwardsCursor)
    }

    func testSettingsAndMemoryResponsesPatchWhileNotificationReplaces() throws {
        let settingsResponse = try adapter.adaptResponse(
            ProtocolResponseContext(
                method: .threadSettingsUpdate,
                requestParams: [
                    "threadId": .string("thread-1"),
                    "model": .null,
                    "serviceTier": .string("priority"),
                ],
                connectionEpoch: 1
            ),
            result: .dictionary([:])
        )
        guard case .threadSettingsPatched(let settingsID, let settingsPatch)? =
            settingsResponse.mutations.first else {
            return XCTFail("Expected sparse settings response patch")
        }
        XCTAssertEqual(settingsID, "thread-1")
        XCTAssertEqual(settingsPatch, [
            "model": .null,
            "serviceTier": .string("priority"),
        ])

        let memoryResponse = try adapter.adaptResponse(
            ProtocolResponseContext(
                method: .threadMemoryModeSet,
                requestParams: [
                    "threadId": .string("thread-1"),
                    "mode": .string("enabled"),
                ],
                connectionEpoch: 1
            ),
            result: .dictionary([:])
        )
        guard case .threadSettingsPatched(let memoryID, let memoryPatch)? =
            memoryResponse.mutations.first else {
            return XCTFail("Expected sparse memory-mode response patch")
        }
        XCTAssertEqual(memoryID, "thread-1")
        XCTAssertEqual(memoryPatch, ["memoryMode": .string("enabled")])

        let notification = try adapter.adaptNotification(
            method: .threadSettingsUpdated,
            params: try objectFixture(
                #"{"threadId":"thread-1","threadSettings":{"approvalPolicy":"never","approvalsReviewer":"user","collaborationMode":{"mode":"default","settings":{"model":"gpt-test"}},"cwd":"/tmp/project","model":"gpt-test","modelProvider":"openai","sandboxPolicy":{"type":"readOnly"}}}"#
            )
        )
        guard case .threadSettingsReplaced(let notificationID, let replacement)? =
            notification.mutations.first else {
            return XCTFail("Expected authoritative settings notification replacement")
        }
        XCTAssertEqual(notificationID, "thread-1")
        XCTAssertEqual(replacement["model"], .string("gpt-test"))
    }

    func testMalformedKnownAndUnknownNotificationBehaviorIsExplicit() throws {
        XCTAssertThrowsError(
            try adapter.adaptNotification(
                method: .itemAgentMessageDelta,
                params: try objectFixture(
                    #"{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1"}"#
                )
            )
        ) { error in
            guard case .malformedNotification(let method, _) = error as? ProtocolStateAdapterError else {
                return XCTFail("Expected typed malformed-notification error, got \(error)")
            }
            XCTAssertEqual(method, "item/agentMessage/delta")
        }

        let unknown = try adapter.adaptNotification(method: "future/state/event", params: [:])
        XCTAssertEqual(unknown.disposition, .unknownMethod)
        XCTAssertTrue(unknown.mutations.isEmpty)
        XCTAssertEqual(unknown.diagnostic, "Unknown app-server notification: future/state/event")
    }

    /// This switch intentionally has no default. Adding an alpha protocol method
    /// must force the adapter test inventory to classify it during compilation.
    private func expectedDisposition(
        for method: CodexAppServerNotificationMethod
    ) -> ProtocolStateDisposition {
        switch method {
        case .error,
             .threadStarted, .threadStatusChanged, .threadArchived, .threadDeleted,
             .threadUnarchived, .threadClosed, .threadNameUpdated, .threadGoalUpdated,
             .threadGoalCleared, .threadEnvironmentConnected, .threadEnvironmentDisconnected,
             .threadSettingsUpdated, .threadTokenUsageUpdated,
             .turnStarted, .hookStarted, .turnCompleted, .hookCompleted,
             .turnDiffUpdated, .turnPlanUpdated,
             .itemStarted, .itemAutoApprovalReviewStarted, .itemAutoApprovalReviewCompleted,
             .itemCompleted, .itemAgentMessageDelta, .itemPlanDelta,
             .itemCommandExecutionOutputDelta, .itemCommandExecutionTerminalInteraction,
             .itemFileChangeOutputDelta, .itemFileChangePatchUpdated, .itemMCPToolCallProgress,
             .mcpServerStartupStatusUpdated,
             .accountUpdated, .accountRateLimitsUpdated,
             .itemReasoningSummaryTextDelta, .itemReasoningSummaryPartAdded,
             .itemReasoningTextDelta, .threadCompacted,
             .modelRerouted, .modelVerification, .turnModerationMetadata,
             .modelSafetyBufferingUpdated:
            .state

        case .serverRequestResolved:
            .requestResolution

        case .skillsChanged,
             .commandExecOutputDelta, .processOutputDelta, .processExited,
             .mcpServerOAuthLoginCompleted,
             .appListUpdated, .remoteControlStatusChanged,
             .externalAgentConfigImportProgress, .externalAgentConfigImportCompleted,
             .fsChanged, .fuzzyFileSearchSessionUpdated, .fuzzyFileSearchSessionCompleted,
             .threadRealtimeStarted, .threadRealtimeItemAdded,
             .threadRealtimeTranscriptDelta, .threadRealtimeTranscriptDone,
             .threadRealtimeOutputAudioDelta, .threadRealtimeSdp,
             .threadRealtimeError, .threadRealtimeClosed,
             .windowsSandboxSetupCompleted, .accountLoginCompleted:
            .operation

        case .warning, .guardianWarning, .deprecationNotice, .configWarning,
             .windowsWorldWritableWarning:
            .diagnostic
        }
    }

    private func objectFixture(_ json: String) throws -> [String: CodexJSONValue] {
        let value = try valueFixture(json)
        guard case .dictionary(let object) = value else {
            throw FixtureError.expectedObject
        }
        return object
    }

    /// Minimal valid payloads for the current notification inventory, including older histories.
    /// Keeping one fixture per state-bearing method makes protocol inventory drift
    /// fail here instead of being hidden behind the empty-payload disposition probe.
    private func stateNotificationFixtures() throws -> [
        CodexAppServerNotificationMethod: [String: CodexJSONValue]
    ] {
        let coordinates = #"{"threadId":"thread-1","turnId":"turn-1"}"#
        let turnStarted = #"{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"inProgress"}}"#
        let turnCompleted = #"{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":"full","status":"completed"}}"#
        let hookStarted = #"{"threadId":"thread-1","turnId":"turn-1","run":{"displayOrder":0,"entries":[],"eventName":"preToolUse","executionMode":"sync","handlerType":"command","id":"hook-1","scope":"turn","sourcePath":"/tmp/hook","startedAt":1,"status":"running"}}"#
        let hookCompleted = #"{"threadId":"thread-1","turnId":"turn-1","run":{"completedAt":2,"displayOrder":0,"durationMs":1,"entries":[],"eventName":"preToolUse","executionMode":"sync","handlerType":"command","id":"hook-1","scope":"turn","sourcePath":"/tmp/hook","startedAt":1,"status":"completed"}}"#
        let reviewStarted = #"{"action":{"type":"mcpToolCall","server":"fixture-server","toolName":"fixture-tool"},"review":{"status":"inProgress"},"reviewId":"review-1","startedAtMs":1,"threadId":"thread-1","turnId":"turn-1"}"#
        let reviewCompleted = #"{"action":{"type":"mcpToolCall","server":"fixture-server","toolName":"fixture-tool"},"completedAtMs":2,"decisionSource":"agent","review":{"status":"approved"},"reviewId":"review-1","startedAtMs":1,"threadId":"thread-1","turnId":"turn-1"}"#

        return [
            .error: try objectFixture(
                #"{"error":{"message":"fixture error"},"threadId":"thread-1","turnId":"turn-1","willRetry":false}"#
            ),
            .threadStarted: try objectFixture(
                #"{"thread":{"cliVersion":"0.145.0-alpha.20","createdAt":1,"cwd":"/tmp/project","ephemeral":false,"id":"thread-1","modelProvider":"openai","preview":"fixture","sessionId":"session-1","source":"cli","status":{"type":"idle"},"turns":[],"updatedAt":2}}"#
            ),
            .threadStatusChanged: try objectFixture(
                #"{"threadId":"thread-1","status":{"type":"idle"}}"#
            ),
            .threadArchived: try objectFixture(#"{"threadId":"thread-1"}"#),
            .threadDeleted: try objectFixture(#"{"threadId":"thread-1"}"#),
            .threadUnarchived: try objectFixture(#"{"threadId":"thread-1"}"#),
            .threadClosed: try objectFixture(#"{"threadId":"thread-1"}"#),
            .threadNameUpdated: try objectFixture(
                #"{"threadId":"thread-1","threadName":"Fixture"}"#
            ),
            .threadGoalUpdated: try objectFixture(
                #"{"threadId":"thread-1","goal":{"createdAt":1,"objective":"ship","status":"active","threadId":"thread-1","timeUsedSeconds":0,"tokensUsed":0,"updatedAt":1}}"#
            ),
            .threadGoalCleared: try objectFixture(#"{"threadId":"thread-1"}"#),
            .threadEnvironmentConnected: try objectFixture(
                #"{"environmentId":"environment-1","threadId":"thread-1"}"#
            ),
            .threadEnvironmentDisconnected: try objectFixture(
                #"{"environmentId":"environment-1","threadId":"thread-1"}"#
            ),
            .threadSettingsUpdated: try objectFixture(
                #"{"threadId":"thread-1","threadSettings":{"approvalPolicy":"never","approvalsReviewer":"user","collaborationMode":{"mode":"default","settings":{"model":"gpt-test"}},"cwd":"/tmp/project","model":"gpt-test","modelProvider":"openai","sandboxPolicy":{"type":"readOnly"}}}"#
            ),
            .threadTokenUsageUpdated: try objectFixture(
                #"{"threadId":"thread-1","turnId":"turn-1","tokenUsage":{"last":{"cachedInputTokens":0,"inputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":0},"total":{"cachedInputTokens":0,"inputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":0}}}"#
            ),
            .turnStarted: try objectFixture(turnStarted),
            .hookStarted: try objectFixture(hookStarted),
            .turnCompleted: try objectFixture(turnCompleted),
            .hookCompleted: try objectFixture(hookCompleted),
            .turnDiffUpdated: try objectFixture(
                #"{"diff":"fixture diff","threadId":"thread-1","turnId":"turn-1"}"#
            ),
            .turnPlanUpdated: try objectFixture(
                #"{"threadId":"thread-1","turnId":"turn-1","plan":[{"step":"inspect","status":"pending"}]}"#
            ),
            .itemStarted: try objectFixture(
                #"{"item":{"type":"agentMessage","id":"item-1","text":""},"startedAtMs":1,"threadId":"thread-1","turnId":"turn-1"}"#
            ),
            .itemAutoApprovalReviewStarted: try objectFixture(reviewStarted),
            .itemAutoApprovalReviewCompleted: try objectFixture(reviewCompleted),
            .itemCompleted: try objectFixture(
                #"{"completedAtMs":2,"item":{"type":"agentMessage","id":"item-1","text":"done"},"threadId":"thread-1","turnId":"turn-1"}"#
            ),
            .itemAgentMessageDelta: try objectFixture(
                #"{"delta":"chunk","itemId":"item-1","threadId":"thread-1","turnId":"turn-1"}"#
            ),
            .itemPlanDelta: try objectFixture(
                #"{"delta":"chunk","itemId":"item-1","threadId":"thread-1","turnId":"turn-1"}"#
            ),
            .itemCommandExecutionOutputDelta: try objectFixture(
                #"{"delta":"chunk","itemId":"item-1","threadId":"thread-1","turnId":"turn-1"}"#
            ),
            .itemCommandExecutionTerminalInteraction: try objectFixture(
                #"{"itemId":"item-1","processId":"process-1","stdin":"y\n","threadId":"thread-1","turnId":"turn-1"}"#
            ),
            .itemFileChangeOutputDelta: try objectFixture(
                #"{"delta":"chunk","itemId":"item-1","threadId":"thread-1","turnId":"turn-1"}"#
            ),
            .itemFileChangePatchUpdated: try objectFixture(
                #"{"changes":[],"itemId":"item-1","threadId":"thread-1","turnId":"turn-1"}"#
            ),
            .itemMCPToolCallProgress: try objectFixture(
                #"{"itemId":"item-1","message":"working","threadId":"thread-1","turnId":"turn-1"}"#
            ),
            .mcpServerStartupStatusUpdated: try objectFixture(
                #"{"name":"fixture-server","status":"ready","threadId":"thread-1"}"#
            ),
            .accountUpdated: try objectFixture(
                #"{"authMode":"chatgpt","planType":"plus"}"#
            ),
            .accountRateLimitsUpdated: try objectFixture(#"{"rateLimits":{}}"#),
            .itemReasoningSummaryTextDelta: try objectFixture(
                #"{"delta":"chunk","itemId":"item-1","summaryIndex":0,"threadId":"thread-1","turnId":"turn-1"}"#
            ),
            .itemReasoningSummaryPartAdded: try objectFixture(
                #"{"itemId":"item-1","summaryIndex":0,"threadId":"thread-1","turnId":"turn-1"}"#
            ),
            .itemReasoningTextDelta: try objectFixture(
                #"{"contentIndex":0,"delta":"chunk","itemId":"item-1","threadId":"thread-1","turnId":"turn-1"}"#
            ),
            .threadCompacted: try objectFixture(coordinates),
            .modelRerouted: try objectFixture(
                #"{"fromModel":"gpt-old","reason":"highRiskCyberActivity","threadId":"thread-1","toModel":"gpt-new","turnId":"turn-1"}"#
            ),
            .modelVerification: try objectFixture(
                #"{"threadId":"thread-1","turnId":"turn-1","verifications":[]}"#
            ),
            .turnModerationMetadata: try objectFixture(
                #"{"metadata":{},"threadId":"thread-1","turnId":"turn-1"}"#
            ),
            .modelSafetyBufferingUpdated: try objectFixture(
                #"{"model":"gpt-test","reasons":[],"showBufferingUi":false,"threadId":"thread-1","turnId":"turn-1","useCases":[]}"#
            ),
        ]
    }

    private func valueFixture(_ json: String) throws -> CodexJSONValue {
        try JSONDecoder().decode(CodexJSONValue.self, from: Data(json.utf8))
    }

    private func resumeResponseJSON(includeItemsCursor: Bool) -> String {
        let itemsCursor = includeItemsCursor ? #", "itemsBackwardsCursor": null"# : ""
        return #"""
        {
          "approvalPolicy": "never",
          "approvalsReviewer": "user",
          "cwd": "/tmp/project",
          "model": "gpt-test",
          "modelProvider": "openai",
          "sandbox": {"type": "readOnly"},
          "thread": {
            "cliVersion": "0.145.0-alpha.20",
            "createdAt": 1,
            "cwd": "/tmp/project",
            "ephemeral": false,
            "historyMode": "paginated",
            "id": "thread-1",
            "modelProvider": "openai",
            "preview": "resume",
            "sessionId": "thread-1",
            "source": "cli",
            "status": {"type": "active", "activeFlags": []},
            "turns": [],
            "updatedAt": 2
          },
          "initialTurnsPage": {
            "backwardsCursor": "page-head",
            "data": [
              {
                "id": "active-turn",
                "items": [
                  {"type": "agentMessage", "id": "message-1", "text": "partial"}
                ],
                "itemsView": "summary",
                "startedAt": 2,
                "status": "inProgress"
              }
            ],
            "nextCursor": "older-page"
          },
          "turnsBackwardsCursor": "turn-head"\#(itemsCursor)
        }
        """#
    }
}

private enum FixtureError: Error {
    case expectedObject
}
