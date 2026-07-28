@testable import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

struct CodexCanonicalFileChangeProjectorTests {
    @Test func canonicalFileChangesPreserveEveryPatchAndMetadataInOneStableRow() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let fileChange = item(threadID, turnID, "patch", .fileChange, [
            "status": .string("completed"),
            "changes": .array([
                fileUpdate(
                    path: "Sources/Added.swift",
                    kind: "add",
                    diff: "@@ -0,0 +1 @@\n+let added = true"
                ),
                fileUpdate(
                    path: "Sources/Modified.swift",
                    kind: "update",
                    diff: "@@ -1 +1 @@\n-let value = 1\n+let value = 2"
                ),
                fileUpdate(
                    path: "Sources/Deleted.swift",
                    kind: "delete",
                    diff: "@@ -1 +0,0 @@\n-let deleted = true"
                ),
                fileUpdate(
                    path: "Sources/OldName.swift",
                    kind: "update",
                    movePath: "Sources/NewName.swift",
                    diff: "@@ -1 +1 @@\n-let name = \"old\"\n+let name = \"new\""
                ),
            ]),
        ])
        let snapshot = state(
            revision: 4,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["patch"], revision: 4)],
            items: [fileChange]
        )

        let projected = try #require(
            CodexCanonicalTranscriptProjector().rebuild(snapshot: snapshot, threadID: threadID)
                .presentation.transcript.turns.first
        )
        let rows = projected.narrative.flatMap(\.fileChangeTestWorkRows)
        let row = try #require(rows.compactMap(\.canonicalFileChange).first)

        #expect(rows.count == 1)
        #expect(row.id == "patch")
        #expect(Set(row.changes.map(\.id)).count == 4)
        #expect(row.changes.allSatisfy { $0.id.hasPrefix("patch:file:") })
        #expect(row.changes.map(\.path) == [
            "Sources/Added.swift",
            "Sources/Modified.swift",
            "Sources/Deleted.swift",
            "Sources/OldName.swift",
        ])
        #expect(row.changes.map(\.kind) == [.added, .modified, .deleted, .renamed])
        #expect(row.changes.map(\.destinationPath) == [
            nil,
            nil,
            nil,
            "Sources/NewName.swift",
        ])
        #expect(row.changes.map(\.diff) == [
            "@@ -0,0 +1 @@\n+let added = true",
            "@@ -1 +1 @@\n-let value = 1\n+let value = 2",
            "@@ -1 +0,0 @@\n-let deleted = true",
            "@@ -1 +1 @@\n-let name = \"old\"\n+let name = \"new\"",
        ])
        #expect(row.preparedChanges.map(\.sourceIndex) == [0, 1, 2, 3])
        #expect(row.preparedChanges.map(\.summary.path) == [
            "Sources/Added.swift",
            "Sources/Modified.swift",
            "Sources/Deleted.swift",
            "Sources/NewName.swift",
        ])
        #expect(row.status == .completed)
        #expect(row.files == [
            "Sources/Added.swift",
            "Sources/Modified.swift",
            "Sources/Deleted.swift",
            "Sources/NewName.swift",
        ])
    }

    @Test func liveFilePatchAndHydratedHistoryProjectIdenticallyInTheirTurn() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let changes: [CodexJSONValue] = [
            fileUpdate(
                path: "Sources/Live.swift",
                kind: "update",
                diff: "@@ -1 +1 @@\n-let live = false\n+let live = true"
            ),
            fileUpdate(
                path: "Tests/LiveTests.swift",
                kind: "add",
                diff: "@@ -0,0 +1 @@\n+#expect(live)"
            ),
        ]
        let liveItem = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: "patch"),
            kind: .fileChange,
            payload: ["status": .string("inProgress"), "changes": .array([])],
            authority: .started,
            liveFields: ["fileChanges": .array(changes)],
            consistency: .partial,
            lastChangedRevision: StateRevision(4)
        )
        let historyItem = item(threadID, turnID, "patch", .fileChange, [
            "status": .string("completed"),
            "changes": .array(changes),
        ], revision: 40)
        let live = state(
            revision: 4,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["patch"], revision: 4)],
            items: [liveItem]
        )
        let history = state(
            revision: 40,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["patch"], revision: 40)],
            items: [historyItem]
        )
        let projector = CodexCanonicalTranscriptProjector()

        let liveTranscript = projector.rebuild(snapshot: live, threadID: threadID)
            .presentation.transcript
        let historyTranscript = projector.rebuild(snapshot: history, threadID: threadID)
            .presentation.transcript

        #expect(liveTranscript == historyTranscript)
        #expect(liveTranscript.turns.map(\.id) == [turnID.rawValue])
        let row = try #require(
            liveTranscript.turns.first?.narrative.flatMap(\.fileChangeTestWorkRows)
                .compactMap(\.canonicalFileChange).first
        )
        #expect(row.changes.map(\.path) == ["Sources/Live.swift", "Tests/LiveTests.swift"])
        #expect(row.preparedChanges.map(\.sourceIndex) == [0, 1])
    }

    @Test func malformedFileChangeEntriesDoNotDropValidSiblings() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let fileChange = item(threadID, turnID, "patch", .fileChange, [
            "status": .string("completed"),
            "changes": .array([
                .string("not an object"),
                .dictionary([
                    "kind": .dictionary(["type": .string("delete")]),
                    "diff": .string("-missing path"),
                ]),
                .dictionary([
                    "path": .string("Sources/Partial.swift"),
                    "kind": .bool(true),
                    "diff": .int(7),
                ]),
                fileUpdate(
                    path: "Sources/Valid.swift",
                    kind: "update",
                    diff: "@@ -1 +1 @@\n-let valid = false\n+let valid = true"
                ),
            ]),
        ])
        let snapshot = state(
            revision: 2,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["patch"], revision: 2)],
            items: [fileChange]
        )

        let row = try projectedFileChangeRow(snapshot, threadID: threadID)

        #expect(row.changes.map(\.path) == ["Sources/Partial.swift", "Sources/Valid.swift"])
        #expect(row.changes.map(\.kind) == [.unknown("unknown"), .modified])
        #expect(row.changes.map(\.diff) == [
            "",
            "@@ -1 +1 @@\n-let valid = false\n+let valid = true",
        ])
        #expect(row.preparedChanges.map(\.sourceIndex) == [0, 1])
        #expect(row.preparedChanges.map(\.isMalformed) == [true, false])
    }

    @Test func malformedWireDifferencesParticipateInConstantTimeRowEquality() {
        func malformedItem(
            futureValue: CodexJSONValue,
            diff: CodexJSONValue? = .int(42)
        ) -> CanonicalItem {
            var change: [String: CodexJSONValue] = [
                "path": .string("Sources/Future.swift"),
                "kind": .bool(true),
                "futureField": futureValue,
            ]
            change["diff"] = diff
            return item("thread", "turn", "patch", .fileChange, [
                "changes": .array([.dictionary(change)]),
            ])
        }
        let projector = CodexCanonicalFileChangeProjector()
        let first = projector.project(
            item: malformedItem(futureValue: .bool(true)),
            status: .completed,
            durationMs: nil,
            previous: nil,
            checkpoint: {}
        )
        let second = projector.project(
            item: malformedItem(futureValue: .bool(false)),
            status: .completed,
            durationMs: nil,
            previous: nil,
            checkpoint: {}
        )
        let missingDiff = projector.project(
            item: malformedItem(futureValue: .bool(true), diff: nil),
            status: .completed,
            durationMs: nil,
            previous: nil,
            checkpoint: {}
        )
        let emptyDiff = projector.project(
            item: malformedItem(futureValue: .bool(true), diff: .string("")),
            status: .completed,
            durationMs: nil,
            previous: nil,
            checkpoint: {}
        )

        #expect(first != second)
        #expect(first.changes.first?.wireValue != second.changes.first?.wireValue)
        #expect(missingDiff != emptyDiff)
    }

    @Test func nullMovePathAndEmptyDiffAreValidButMissingDiffIsMalformed() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let snapshot = state(
            revision: 2,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["patch"], revision: 2)],
            items: [item(threadID, turnID, "patch", .fileChange, [
                "status": .string("inProgress"),
                "changes": .array([
                    .dictionary([
                        "path": .string("Sources/Empty.swift"),
                        "kind": .dictionary([
                            "type": .string("update"),
                            "move_path": .null,
                        ]),
                        "diff": .string(""),
                    ]),
                    .dictionary([
                        "path": .string("Sources/Missing.swift"),
                        "kind": .dictionary(["type": .string("update")]),
                    ]),
                ]),
            ], revision: 2)]
        )

        let row = try projectedFileChangeRow(snapshot, threadID: threadID)
        #expect(row.status == .inProgress)
        #expect(row.changes.map(\.kind) == [.modified, .modified])
        #expect(row.changes.map(\.destinationPath) == [nil, nil])
        #expect(row.preparedChanges.map(\.sourceIndex) == [0, 1])
        #expect(row.preparedChanges.map(\.isMalformed) == [false, true])
    }

    @Test func representativeLargeFilePatchIsPreparedOnceDuringProjection() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let lineCount = 5_000
        let body = (0..<lineCount).flatMap { index in
            ["-let value\(index) = false", "+let value\(index) = true"]
        }.joined(separator: "\n")
        let diff = "@@ -1,\(lineCount) +1,\(lineCount) @@\n\(body)"
        let fileChange = item(threadID, turnID, "large-patch", .fileChange, [
            "status": .string("completed"),
            "changes": .array([
                fileUpdate(path: "Sources/Large.swift", kind: "update", diff: diff),
            ]),
        ])
        let snapshot = state(
            revision: 3,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["large-patch"], revision: 3)],
            items: [fileChange]
        )

        let row = try projectedFileChangeRow(snapshot, threadID: threadID)
        let prepared = try #require(row.preparedChanges.first)

        #expect(row.changes.first?.diff == diff)
        #expect(row.preparedChanges.count == 1)
        #expect(prepared.sourceIndex == 0)
        #expect(prepared.summary.path == "Sources/Large.swift")
        #expect(prepared.summary.added == lineCount)
        #expect(prepared.summary.removed == lineCount)
        #expect(
            row.retainedPreparedUTF8ByteCount
                <= CodexPreparedFileChangeSetV2.maximumRetainedUTF8Bytes
        )
        #expect(prepared.isTruncated)
        #expect(prepared.displayLines.contains { $0.text.contains("more lines") })
    }

    @Test func officialKindDependentFilePayloadsNormalizeOnceWithExactStats() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let addedContent = "let first = true\n\nlet second = true\n"
        let deletedContent = "old\n--value\n"
        let updateDiff = "@@ -1 +1 @@\n---value\n+++counter"
        let changes: [CodexJSONValue] = [
            fileUpdate(path: "Sources/Added.swift", kind: "add", diff: addedContent),
            fileUpdate(path: "Sources/Deleted.swift", kind: "delete", diff: deletedContent),
            fileUpdate(path: "Sources/Counter.swift", kind: "update", diff: updateDiff),
            fileUpdate(
                path: "Sources/Old.swift",
                kind: "update",
                movePath: "Sources/New.swift",
                diff: ""
            ),
        ]
        let snapshot = state(
            revision: 3,
            threadID: threadID,
            turns: [turn(turnID, threadID: threadID, itemIDs: ["patch"], revision: 3)],
            items: [item(threadID, turnID, "patch", .fileChange, [
                "status": .string("completed"),
                "changes": .array(changes),
            ], revision: 3)]
        )

        let row = try projectedFileChangeRow(snapshot, threadID: threadID)
        let display = row.preparedChanges.map(displayText)

        #expect(row.changes.map(\.diff) == [
            addedContent,
            deletedContent,
            updateDiff,
            "",
        ])
        #expect(row.preparedChanges.map(\.sourceIndex) == [0, 1, 2, 3])
        #expect(row.preparedChanges.map(\.summary.added) == [3, 0, 1, 0])
        #expect(row.preparedChanges.map(\.summary.removed) == [0, 2, 1, 0])
        #expect(display[0].contains("new file mode 100644"))
        #expect(display[0].contains("+let first = true"))
        #expect(display[1].contains("deleted file mode 100644"))
        #expect(row.preparedChanges[1].displayLines.contains {
            $0.kind == .remove && $0.text == "---value"
        })
        #expect(display[2].contains("--- a/Sources/Counter.swift"))
        #expect(row.preparedChanges[2].displayLines.contains {
            $0.kind == .add && $0.text == "+++counter"
        })
        #expect(display[3].contains("rename from Sources/Old.swift"))
        #expect(display[3].contains("rename to Sources/New.swift"))
        #expect(row.hasPreparedDetail)
    }

    @Test func fileItemRevisionInvalidatesPreparationButSiblingRevisionDoesNot() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let probe = FilePreparationProbe()
        let production = CodexFileChangeDiffPreparer()
        let projector = CodexCanonicalTranscriptProjector(
            fileChangeDiffPreparer: .init { changes, legacyDiff, maximumBytes in
                probe.record()
                return production.prepare(
                    changes: changes,
                    legacyDiff: legacyDiff,
                    maximumRetainedUTF8Bytes: maximumBytes,
                    checkpoint: {}
                )
            }
        )
        let firstFile = item(threadID, turnID, "patch", .fileChange, [
            "status": .string("inProgress"),
            "changes": .array([
                fileUpdate(
                    path: "Sources/Stable.swift",
                    kind: "update",
                    diff: "@@ -1 +1 @@\n-old\n+new"
                ),
            ]),
        ], revision: 3)
        let first = state(
            revision: 3,
            threadID: threadID,
            turns: [turn(
                turnID,
                threadID: threadID,
                itemIDs: ["patch", "message"],
                revision: 3
            )],
            items: [
                firstFile,
                item(threadID, turnID, "message", .agentMessage, [
                    "phase": .string("commentary"),
                    "text": .string("one"),
                ], revision: 3),
            ]
        )
        let firstResult = projector.rebuild(snapshot: first, threadID: threadID)
        let firstRow = try #require(
            firstResult.presentation.transcript.turns.first?.narrative
                .flatMap(\.fileChangeTestWorkRows)
                .compactMap(\.canonicalFileChange).first
        )

        let siblingMessage = item(threadID, turnID, "message", .agentMessage, [
            "phase": .string("commentary"),
            "text": .string("two"),
        ], revision: 4)
        let siblingChanged = state(
            revision: 4,
            threadID: threadID,
            turns: [turn(
                turnID,
                threadID: threadID,
                itemIDs: ["patch", "message"],
                revision: 4
            )],
            items: [firstFile, siblingMessage]
        )
        let secondResult = try projector.project(
            snapshot: siblingChanged,
            threadID: threadID,
            previous: firstResult.presentation
        )
        let secondRow = try #require(
            secondResult.presentation.transcript.turns.first?.narrative
                .flatMap(\.fileChangeTestWorkRows)
                .compactMap(\.canonicalFileChange).first
        )

        #expect(probe.count == 1)
        #expect(firstRow.preparedFileChanges === secondRow.preparedFileChanges)

        let lifecycleChanged = item(threadID, turnID, "patch", .fileChange, [
            "status": .string("completed"),
            "changes": firstFile.payload["changes"] ?? .array([]),
        ], revision: 5)
        let lifecycleSnapshot = state(
            revision: 5,
            threadID: threadID,
            turns: [turn(
                turnID,
                threadID: threadID,
                itemIDs: ["patch", "message"],
                revision: 5
            )],
            items: [lifecycleChanged, siblingMessage]
        )
        let lifecycleResult = try projector.project(
            snapshot: lifecycleSnapshot,
            threadID: threadID,
            previous: secondResult.presentation
        )
        let lifecycleRow = try #require(
            lifecycleResult.presentation.transcript.turns.first?.narrative
                .flatMap(\.fileChangeTestWorkRows)
                .compactMap(\.canonicalFileChange).first
        )

        #expect(probe.count == 2)
        #expect(lifecycleRow.preparedFileChanges !== secondRow.preparedFileChanges)
    }

    @Test func duplicatePathIDsRemainUniqueAndFollowContentAcrossReordering() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let firstDiff = "@@ -1 +1 @@\n-a\n+b"
        let secondDiff = "@@ -1 +1 @@\n-c\n+d"
        func snapshot(_ diffs: [String], revision: UInt64) -> CanonicalStateSnapshot {
            state(
                revision: revision,
                threadID: threadID,
                turns: [turn(
                    turnID,
                    threadID: threadID,
                    itemIDs: ["patch"],
                    revision: revision
                )],
                items: [item(threadID, turnID, "patch", .fileChange, [
                    "changes": .array(diffs.map {
                        fileUpdate(path: "Sources/Same.swift", kind: "update", diff: $0)
                    }),
                ], revision: revision)]
            )
        }
        func IDsByDiff(_ snapshot: CanonicalStateSnapshot) throws -> [String: String] {
            let row = try projectedFileChangeRow(snapshot, threadID: threadID)
            #expect(Set(row.changes.map(\.id)).count == row.changes.count)
            return Dictionary(uniqueKeysWithValues: row.changes.map { ($0.diff, $0.id) })
        }

        let original = try IDsByDiff(snapshot([firstDiff, secondDiff], revision: 2))
        let reordered = try IDsByDiff(snapshot([secondDiff, firstDiff], revision: 3))

        #expect(original == reordered)
    }

    @Test func fileChangeIDSurvivesSingletonToDuplicateTransition() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let originalDiff = "@@ -1 +1 @@\n-a\n+b"
        let siblingDiff = "@@ -1 +1 @@\n-c\n+d"
        func row(_ diffs: [String], revision: UInt64) throws -> CodexFileChangeRowV2 {
            let snapshot = state(
                revision: revision,
                threadID: threadID,
                turns: [turn(
                    turnID,
                    threadID: threadID,
                    itemIDs: ["patch"],
                    revision: revision
                )],
                items: [item(threadID, turnID, "patch", .fileChange, [
                    "changes": .array(diffs.map {
                        fileUpdate(path: "Sources/Same.swift", kind: "update", diff: $0)
                    }),
                ], revision: revision)]
            )
            return try projectedFileChangeRow(snapshot, threadID: threadID)
        }

        let singleton = try row([originalDiff], revision: 2)
        let duplicate = try row([originalDiff, siblingDiff], revision: 3)
        #expect(
            singleton.changes.first?.id
                == duplicate.changes.first { $0.diff == originalDiff }?.id
        )
    }

    @Test func fileChangeIDSurvivesIncrementalPatchEvolution() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        func snapshot(diff: String, revision: UInt64) -> CanonicalStateSnapshot {
            state(
                revision: revision,
                threadID: threadID,
                turns: [turn(
                    turnID,
                    threadID: threadID,
                    itemIDs: ["patch"],
                    revision: revision
                )],
                items: [item(threadID, turnID, "patch", .fileChange, [
                    "changes": .array([
                        fileUpdate(
                            path: "Sources/Evolving.swift",
                            kind: "update",
                            diff: diff
                        ),
                    ]),
                ], revision: revision)]
            )
        }

        let projector = CodexCanonicalTranscriptProjector()
        let first = projector.rebuild(
            snapshot: snapshot(diff: "@@ -1 +1 @@\n-old\n+new", revision: 2),
            threadID: threadID
        )
        let firstID = try #require(
            first.presentation.transcript.turns.first?.narrative
                .flatMap(\.fileChangeTestWorkRows)
                .compactMap(\.canonicalFileChange)
                .first?
                .changes
                .first?
                .id
        )
        let evolved = try projector.project(
            snapshot: snapshot(diff: "@@ -1 +1 @@\n-old\n+newer", revision: 3),
            threadID: threadID,
            previous: first.presentation
        )
        let evolvedID = try #require(
            evolved.presentation.transcript.turns.first?.narrative
                .flatMap(\.fileChangeTestWorkRows)
                .compactMap(\.canonicalFileChange)
                .first?
                .changes
                .first?
                .id
        )

        #expect(evolvedID == firstID)
    }

    @Test func publicFileChangeSourcesAreExplicitAndDerivedStateIsNotEquality() {
        let row = CodexFileChangeRowV2(
            id: "patch",
            changes: [.init(
                id: "change",
                path: "Sources/Old.swift",
                destinationPath: "Sources/New.swift",
                kind: .renamed,
                diff: ""
            )],
            status: .completed
        )
        #expect(row.files == ["Sources/New.swift"])
        #expect(row.preparedChanges.count == 1)
        #expect(row.preparedChanges.first?.sourceIndex == 0)
        #expect(row.diff == nil)

        let legacy = CodexFileChangeRowV2(
            id: "legacy",
            files: ["Sources/Legacy.swift"],
            status: .completed,
            diff: "@@ -1 +1 @@\n-old\n+new"
        )
        #expect(legacy.files == ["Sources/Legacy.swift"])
        #expect(legacy.diff == "@@ -1 +1 @@\n-old\n+new")
        #expect(legacy.changes.isEmpty)

        let alternatePreparation = CodexFileChangeDiffPreparer().prepare(
            changes: row.changes,
            legacyDiff: nil,
            maximumRetainedUTF8Bytes: 8,
            checkpoint: {}
        )
        let semanticallyEqual = CodexFileChangeRowV2(
            id: row.id,
            sourceRevision: StateRevision(999),
            changes: row.changes,
            status: row.status,
            durationMs: row.durationMs,
            preparedFileChanges: alternatePreparation
        )
        #expect(row == semanticallyEqual)
    }

    @Test func malformedLivePatchAndAdapterCompletionKeepValidSibling() throws {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let itemID: ItemID = "patch"
        let itemKey = ItemKey(threadID: threadID, turnID: turnID, itemID: itemID)
        let malformedWire: CodexJSONValue = .dictionary([
            "path": .string("Sources/Future.swift"),
            "kind": .dictionary(["type": .string("update")]),
            "diff": .int(42),
            "futureField": .dictionary(["kept": .bool(true)]),
        ])
        let rawChanges: CodexJSONValue = .array([
            fileUpdate(
                path: "Sources/Valid.swift",
                kind: "update",
                diff: "@@ -1 +1 @@\n-old\n+new"
            ),
            malformedWire,
        ])
        let adaptation = try ProtocolStateAdapter().adaptNotification(
            method: .itemFileChangePatchUpdated,
            params: [
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "itemId": .string(itemID.rawValue),
                "changes": rawChanges,
            ]
        )
        var graph = CanonicalStateGraph()
        var reducer = CanonicalStateReducer()
        _ = reducer.apply(.threadUpsert(.init(
            id: threadID,
            status: .active(flags: []),
            turnOrder: [turnID],
            isLoaded: true
        )), to: &graph)
        _ = reducer.apply(.turnStarted(.init(
            key: .init(threadID: threadID, turnID: turnID),
            status: .inProgress,
            itemOrder: [itemID]
        ), items: []), to: &graph)
        _ = reducer.apply(.itemStarted(.init(
            key: itemKey,
            kind: .fileChange,
            payload: ["status": .string("inProgress")],
            authority: .started
        )), to: &graph)
        _ = reducer.apply(adaptation.mutations, to: &graph)

        let projector = CodexCanonicalTranscriptProjector()
        let liveResult = projector.rebuild(snapshot: graph.snapshot(), threadID: threadID)
        let liveRow = try #require(
            liveResult.presentation.transcript.turns.first?.narrative
                .flatMap(\.fileChangeTestWorkRows)
                .compactMap(\.canonicalFileChange).first
        )
        #expect(liveRow.changes.map(\.path) == [
            "Sources/Valid.swift",
            "Sources/Future.swift",
        ])
        #expect(graph.items[itemKey]?.liveFields["fileChanges"] == rawChanges)
        #expect(liveRow.preparedChanges.map(\.sourceIndex) == [0, 1])
        #expect(liveRow.preparedChanges.map(\.isMalformed) == [false, true])
        #expect(liveRow.changes[1].wireValue == malformedWire)

        let completion = try ProtocolStateAdapter().adaptNotification(
            method: .itemCompleted,
            params: [
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "completedAtMs": .int(10),
                "item": .dictionary([
                    "id": .string(itemID.rawValue),
                    "type": .string("fileChange"),
                    "status": .string("completed"),
                    "changes": rawChanges,
                ]),
            ]
        )
        _ = reducer.apply(completion.mutations, to: &graph)
        let completedResult = try projector.project(
            snapshot: graph.snapshot(),
            threadID: threadID,
            previous: liveResult.presentation
        )
        let hydratedRow = try #require(
            completedResult.presentation.transcript.turns.first?.narrative
                .flatMap(\.fileChangeTestWorkRows)
                .compactMap(\.canonicalFileChange).first
        )

        #expect(hydratedRow.changes.map(\.path) == liveRow.changes.map(\.path))
        #expect(hydratedRow.changes.map(\.diff) == liveRow.changes.map(\.diff))
        #expect(
            hydratedRow.preparedChanges.map(\.summary.added)
                == liveRow.preparedChanges.map(\.summary.added)
        )
        #expect(
            hydratedRow.preparedChanges.map(\.summary.removed)
                == liveRow.preparedChanges.map(\.summary.removed)
        )
    }
}

private extension CodexCanonicalFileChangeProjectorTests {
    func projectedFileChangeRow(
        _ snapshot: CanonicalStateSnapshot,
        threadID: ThreadID
    ) throws -> CodexFileChangeRowV2 {
        try #require(
            CodexCanonicalTranscriptProjector().rebuild(
                snapshot: snapshot,
                threadID: threadID
            ).presentation.transcript.turns.first?.narrative
                .flatMap(\.fileChangeTestWorkRows)
                .compactMap(\.canonicalFileChange).first
        )
    }

    func displayText(_ change: CodexPreparedFileChangeV2) -> String {
        change.displayLines.map(\.text).joined(separator: "\n")
    }

    func state(
        revision: UInt64,
        threadID: ThreadID,
        turns: [CanonicalTurn],
        items: [CanonicalItem]
    ) -> CanonicalStateSnapshot {
        let thread = CanonicalThread(
            id: threadID,
            status: .idle,
            turnOrder: turns.map(\.key.turnID),
            history: .init(turnsCoverage: .full),
            consistency: .authoritative,
            lastChangedRevision: StateRevision(revision)
        )
        return .init(
            revision: StateRevision(revision),
            threadOrder: [threadID],
            threads: [threadID: thread],
            turns: Dictionary(uniqueKeysWithValues: turns.map { ($0.key, $0) }),
            items: Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })
        )
    }

    func turn(
        _ id: TurnID,
        threadID: ThreadID,
        itemIDs: [ItemID] = [],
        revision: UInt64
    ) -> CanonicalTurn {
        .init(
            key: .init(threadID: threadID, turnID: id),
            status: .completed,
            duration: DurationMilliseconds(20),
            itemOrder: itemIDs,
            itemsCoverage: .full,
            itemsConsistency: .authoritative,
            lastChangedRevision: StateRevision(revision)
        )
    }

    func item(
        _ threadID: ThreadID,
        _ turnID: TurnID,
        _ itemID: ItemID,
        _ kind: ThreadItemKind,
        _ payload: [String: CodexJSONValue] = [:],
        revision: UInt64 = 8
    ) -> CanonicalItem {
        .init(
            key: .init(threadID: threadID, turnID: turnID, itemID: itemID),
            kind: kind,
            payload: payload,
            authority: .completed,
            consistency: .authoritative,
            lastChangedRevision: StateRevision(revision)
        )
    }

    func fileUpdate(
        path: String,
        kind: String,
        movePath: String? = nil,
        diff: String
    ) -> CodexJSONValue {
        var kindPayload: [String: CodexJSONValue] = ["type": .string(kind)]
        if let movePath {
            kindPayload["move_path"] = .string(movePath)
        }
        return .dictionary([
            "path": .string(path),
            "kind": .dictionary(kindPayload),
            "diff": .string(diff),
        ])
    }
}

private extension CodexNarrativeEntry {
    var fileChangeTestWorkRows: [CodexWorkRowV2] {
        if case .workGroup(let group) = self { group.rows } else { [] }
    }
}

private extension CodexWorkRowV2 {
    var canonicalFileChange: CodexFileChangeRowV2? {
        if case .fileChange(let value) = self { value } else { nil }
    }
}

private final class FilePreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock { value += 1 }
    }
}
