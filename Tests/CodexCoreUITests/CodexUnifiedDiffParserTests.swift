@testable import CodexCoreUI
import Foundation
import Testing

struct CodexUnifiedDiffParserTests {
    @Test func parsesMultipleFilesHunksAndCounts() {
        let diff = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -1,2 +1,3 @@
         context
        -old
        +new
        +extra
        diff --git a/Tests/B.swift b/Tests/B.swift
        new file mode 100644
        --- /dev/null
        +++ b/Tests/B.swift
        @@ -0,0 +1 @@
        +test
        """
        let files = CodexUnifiedDiffParser.parse(diff)
        #expect(files.count == 2)
        #expect(files[0].path == "Sources/A.swift")
        #expect(files[0].added == 2)
        #expect(files[0].removed == 1)
        #expect(files[1].kind == "added")
        #expect(files[1].added == 1)
    }

    @Test func preservesUnstructuredInputAsFallback() {
        let files = CodexUnifiedDiffParser.parse("+line\n-line")
        #expect(files.count == 1)
        #expect(files[0].path == "patch")
        #expect(files[0].hunks[0].lines.map(\.text) == ["+line", "-line"])
    }

    @Test func hunkSourceThatResemblesFileHeadersStillCountsAsSource() throws {
        let diff = """
        diff --git a/Sources/Counter.swift b/Sources/Counter.swift
        --- a/Sources/Counter.swift
        +++ b/Sources/Counter.swift
        @@ -1 +1 @@
        ---value
        +++counter
        """

        let file = try #require(CodexUnifiedDiffParser.parse(diff).first)

        #expect(file.added == 1)
        #expect(file.removed == 1)
        #expect(file.hunks.last?.lines.map(\.text) == ["---value", "+++counter"])
        #expect(file.hunks.last?.lines.map(\.kind) == [.remove, .add])
    }

    @Test func exactOneMiBPatchKeepsExactStatsWithinByteAndLineCaps() throws {
        let prefix = """
        diff --git a/Sources/Large.swift b/Sources/Large.swift\r
        --- a/Sources/Large.swift\r
        +++ b/Sources/Large.swift\r
        @@ -0,0 +1 @@\r
        +
        """
        let targetByteCount = 1_024 * 1_024
        let diff = prefix + String(
            repeating: "x",
            count: targetByteCount - prefix.utf8.count
        )

        let parsed = CodexUnifiedDiffParser.parseBounded(
            diff,
            maximumRetainedUTF8Bytes: 1_024,
            maximumRetainedLineCount: 8
        )
        let file = try #require(parsed.files.first)
        var expectedFingerprint = CodexStableFingerprint()
        expectedFingerprint.combine(diff)

        #expect(diff.utf8.count == targetByteCount)
        #expect(parsed.rawFingerprint == expectedFingerprint.value)
        #expect(parsed.totalLineCount == 5)
        #expect(file.path == "Sources/Large.swift")
        #expect(file.added == 1)
        #expect(file.removed == 0)
        #expect(parsed.retainedUTF8ByteCount <= 1_024)
        #expect(parsed.retainedLineCount <= 8)
        #expect(parsed.isTruncated)
    }

    @Test func newlineDenseOfficialAdditionHasExactCountAndBoundedPreparation() throws {
        let content = String(repeating: "\n", count: 1_024 * 1_024)
        let change = CodexFileChangeV2(
            id: "dense",
            path: "Sources/Dense.swift",
            kind: .added,
            diff: content
        )

        let prepared = CodexFileChangeDiffPreparer().prepare(
            changes: [change],
            legacyDiff: nil
        )
        let entry = try #require(prepared.entries.first)

        #expect(content.utf8.count == 1_024 * 1_024)
        #expect(entry.added == 1_024 * 1_024)
        #expect(entry.removed == 0)
        #expect(entry.isTruncated)
        #expect(
            prepared.retainedUTF8ByteCount
                <= CodexPreparedFileChangeSetV2.maximumRetainedUTF8Bytes
        )
        #expect(
            prepared.retainedLineCount
                <= CodexPreparedFileChangeSetV2.maximumRetainedLineCount
        )
    }

    @Test func newlineDenseOneMiBDiffDoesNotRetainAnUnboundedLineArray() {
        let diff = String(repeating: "\n", count: 1_024 * 1_024)

        let parsed = CodexUnifiedDiffParser.parseBounded(
            diff,
            maximumRetainedUTF8Bytes: 32,
            maximumRetainedLineCount: 32
        )

        #expect(diff.utf8.count == 1_024 * 1_024)
        #expect(parsed.totalLineCount == 1_024 * 1_024 + 1)
        #expect(parsed.retainedLineCount == 32)
        #expect(parsed.retainedUTF8ByteCount == 0)
        #expect(
            parsed.files.flatMap(\.hunks).flatMap(\.lines).count == 32
        )
        #expect(parsed.isTruncated)
    }

    @Test func exactOneMiBLegacyMultifilePatchKeepsPerFileBinaryAndSlices() throws {
        let first = [
            "diff --git a/Assets/Image.png b/Assets/Image.png",
            "new file mode 100644",
            "Binary files /dev/null and b/Assets/Image.png differ",
        ].joined(separator: "\r\n")
        let secondPrefix = [
            "diff --git a/Sources/Text.swift b/Sources/Text.swift",
            "--- a/Sources/Text.swift",
            "+++ b/Sources/Text.swift",
            "@@ -1 +1 @@",
            "-old",
            "+new",
            " ",
        ].joined(separator: "\r\n")
        let prefix = first + "\r\n" + secondPrefix
        let targetByteCount = 1_024 * 1_024
        let diff = prefix + String(
            repeating: "x",
            count: targetByteCount - prefix.utf8.count
        )

        let prepared = CodexFileChangeDiffPreparer().prepare(
            changes: [],
            legacyDiff: diff
        )
        let firstEntry = try #require(prepared.entries.first)
        let secondEntry = try #require(prepared.entries.dropFirst().first)

        #expect(diff.utf8.count == targetByteCount)
        #expect(prepared.entries.count == 2)
        #expect(prepared.entries.map(\.path) == [
            "Assets/Image.png",
            "Sources/Text.swift",
        ])
        #expect(prepared.entries.map(\.isBinary) == [true, false])
        #expect(prepared.entries.map(\.added) == [0, 1])
        #expect(prepared.entries.map(\.removed) == [0, 1])
        #expect(
            firstEntry.exactPatch?.materialized()
                .hasPrefix("diff --git a/Assets/Image.png") == true
        )
        #expect(
            firstEntry.exactPatch?.materialized()
                .contains("Sources/Text.swift") == false
        )
        #expect(
            secondEntry.exactPatch?.materialized()
                .hasPrefix("diff --git a/Sources/Text.swift") == true
        )
        #expect(
            prepared.retainedUTF8ByteCount
                <= CodexPreparedFileChangeSetV2.maximumRetainedUTF8Bytes
        )
        #expect(
            prepared.retainedLineCount
                <= CodexPreparedFileChangeSetV2.maximumRetainedLineCount
        )
    }

    @Test func headerDenseOneMiBMultifilePatchCapsRecordsButKeepsExactTotals() {
        let block = """
        diff --git a/a.swift b/a.swift
        @@ -1 +1 @@
        -old
        +new

        """
        let targetByteCount = 1_024 * 1_024
        let fileCount = targetByteCount / block.utf8.count
        let repeated = String(repeating: block, count: fileCount)
        let diff = repeated + String(
            repeating: " ",
            count: targetByteCount - repeated.utf8.count
        )

        let parsed = CodexUnifiedDiffParser.parseBounded(
            diff,
            maximumRetainedUTF8Bytes: 1_024,
            maximumRetainedLineCount: 32
        )
        let prepared = CodexFileChangeDiffPreparer().prepare(
            changes: [],
            legacyDiff: diff
        )

        #expect(diff.utf8.count == targetByteCount)
        #expect(parsed.totalFileCount == fileCount)
        #expect(parsed.totalAdded == fileCount)
        #expect(parsed.totalRemoved == fileCount)
        #expect(parsed.files.count <= 32)
        #expect(parsed.fileSourceRanges.count == parsed.files.count)
        #expect(parsed.didTruncateFileRecords)
        #expect(prepared.totalAdded == fileCount)
        #expect(prepared.totalRemoved == fileCount)
        #expect(
            prepared.entries.count
                <= CodexPreparedFileChangeSetV2.maximumPreparedEntryCount
        )
    }

    @Test func officialContentNormalizesCRLFAndSynthesizesExactHeaders() throws {
        let content = "let first = true\r\n\r\nlet second = true\r\n"
        let change = CodexFileChangeV2(
            id: "added",
            path: "Sources/Added.swift",
            kind: .added,
            diff: content
        )

        let entry = try #require(
            CodexFileChangeDiffPreparer().prepare(
                changes: [change],
                legacyDiff: nil
            ).entries.first
        )

        #expect(entry.added == 3)
        #expect(entry.removed == 0)
        #expect(entry.displayPatch.contains("@@ -0,0 +1,3 @@"))
        #expect(entry.displayPatch.contains("+let first = true\n+\n+let second = true"))
        #expect(!entry.displayPatch.contains("\r"))
    }

    @Test func officialContentThatResemblesFileHeadersRemainsVisible() throws {
        let added = CodexFileChangeV2(
            id: "added",
            path: "Sources/Added.swift",
            kind: .added,
            diff: "++ generated heading"
        )
        let deleted = CodexFileChangeV2(
            id: "deleted",
            path: "Sources/Deleted.swift",
            kind: .deleted,
            diff: "-- removed heading"
        )

        let entries = CodexFileChangeDiffPreparer().prepare(
            changes: [added, deleted],
            legacyDiff: nil
        ).entries
        let addedEntry = try #require(entries.first)
        let deletedEntry = try #require(entries.dropFirst().first)

        #expect(entries.count == 2)
        #expect(addedEntry.displayPatch.contains("+++ generated heading"))
        #expect(deletedEntry.displayPatch.contains("--- removed heading"))
    }

    @Test func modifiedPayloadHeaderVariantsNormalizeWithoutDuplicates() throws {
        let path = "Sources/Counter.swift"
        let payloads = [
            "@@ -1 +1 @@\n-old\n+new",
            "--- a/\(path)\n+++ b/\(path)\n@@ -1 +1 @@\n-old\n+new",
            "\n\ndiff --git a/\(path) b/\(path)\n@@ -1 +1 @@\n-old\n+new",
            """
            diff --git a/\(path) b/\(path)
            --- a/\(path)
            +++ b/\(path)
            @@ -1 +1 @@
            -old
            +new
            """,
        ]

        for (index, payload) in payloads.enumerated() {
            let entry = try #require(
                CodexFileChangeDiffPreparer().prepare(
                    changes: [.init(
                        id: "modified:\(index)",
                        path: path,
                        kind: .modified,
                        diff: payload
                    )],
                    legacyDiff: nil
                ).entries.first
            )
            let lines = entry.displayPatch.components(separatedBy: "\n")

            #expect(lines.filter { $0.hasPrefix("diff --git ") }.count == 1)
            #expect(lines.filter { $0.hasPrefix("--- ") }.count == 1)
            #expect(lines.filter { $0.hasPrefix("+++ ") }.count == 1)
            #expect(entry.added == 1)
            #expect(entry.removed == 1)
        }
    }

    @Test func renamedPayloadHeaderVariantsNormalizeWithoutDuplicates() throws {
        let oldPath = "Sources/Old.swift"
        let newPath = "Sources/New.swift"
        let payloads = [
            "@@ -1 +1 @@\n-old\n+new",
            "--- a/\(oldPath)\n+++ b/\(newPath)\n@@ -1 +1 @@\n-old\n+new",
            "diff --git a/\(oldPath) b/\(newPath)\n@@ -1 +1 @@\n-old\n+new",
        ]

        for (index, payload) in payloads.enumerated() {
            let entry = try #require(
                CodexFileChangeDiffPreparer().prepare(
                    changes: [.init(
                        id: "renamed:\(index)",
                        path: oldPath,
                        destinationPath: newPath,
                        kind: .renamed,
                        diff: payload
                    )],
                    legacyDiff: nil
                ).entries.first
            )
            let lines = entry.displayPatch.components(separatedBy: "\n")

            #expect(lines.filter { $0.hasPrefix("diff --git ") }.count == 1)
            #expect(lines.filter { $0.hasPrefix("rename from ") }.count == 1)
            #expect(lines.filter { $0.hasPrefix("rename to ") }.count == 1)
            #expect(lines.filter { $0.hasPrefix("--- ") }.count == 1)
            #expect(lines.filter { $0.hasPrefix("+++ ") }.count == 1)
            #expect(entry.added == 1)
            #expect(entry.removed == 1)
        }
    }

    @Test func canonicalPreparationCapsThousandsOfEmptyFileEntries() {
        var changes = (0..<5_000).map { index in
            CodexFileChangeV2(
                id: "empty:\(index)",
                path: "Generated/Empty\(index).swift",
                kind: .added,
                diff: ""
            )
        }
        changes.append(.init(
            id: "tail",
            path: "Sources/Tail.swift",
            kind: .modified,
            diff: "@@ -1 +1 @@\n-old\n+new"
        ))

        let prepared = CodexFileChangeDiffPreparer().prepare(
            changes: changes,
            legacyDiff: nil
        )
        let entryLimit = CodexPreparedFileChangeSetV2.maximumPreparedEntryCount

        #expect(prepared.entries.count == entryLimit)
        #expect(prepared.entries.last?.changeID == "empty:\(entryLimit - 1)")
        #expect(prepared.totalAdded == 1)
        #expect(prepared.totalRemoved == 1)
        #expect(
            prepared.retainedUTF8ByteCount
                <= CodexPreparedFileChangeSetV2.maximumRetainedUTF8Bytes
        )
        #expect(
            prepared.retainedLineCount
                <= CodexPreparedFileChangeSetV2.maximumRetainedLineCount
        )
    }

    @Test func entryFingerprintIncludesItsBudgetDependentDisplay() throws {
        let target = CodexFileChangeV2(
            id: "target",
            path: "Sources/Target.swift",
            kind: .modified,
            diff: "@@ -1 +1 @@\n-old\n+new"
        )
        let targetAlone = try #require(
            CodexFileChangeDiffPreparer().prepare(
                changes: [target],
                legacyDiff: nil
            ).entries.first
        )
        let budgetConsumer = CodexFileChangeV2(
            id: "large",
            path: "Sources/Large.swift",
            kind: .added,
            diff: String(repeating: "let value = true\n", count: 100_000)
        )
        let targetAfterLargeChange = try #require(
            CodexFileChangeDiffPreparer().prepare(
                changes: [budgetConsumer, target],
                legacyDiff: nil
            ).entries.last
        )

        #expect(targetAlone.displayPatch != targetAfterLargeChange.displayPatch)
        #expect(targetAlone.fingerprint != targetAfterLargeChange.fingerprint)
    }
}
