import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexReviewDiffDocumentTests {
    @Test func addedFileShowsOneGutterStartingAtLineOne() {
        let document = CodexReviewDiffDocument.parse("""
        diff --git a/games/guess_game.py b/games/guess_game.py
        new file mode 100644
        --- /dev/null
        +++ b/games/guess_game.py
        @@ -0,0 +1,3 @@
        +import random
        +
        +secret = random.randint(1, 10)
        """)

        // A pure addition never had an old side, so its rows are numbered
        // once, from 1 — matching the official renderer's single unified gutter.
        #expect(document.hasOldSide == false)
        #expect(document.hasNewSide)
        let lines = document.rows.filter { $0.kind == .add }
        #expect(lines.map(\.displayLine) == [1, 2, 3])
        #expect(lines.first?.text == "import random")
        // File headers are chrome the pane already shows.
        #expect(document.rows.contains { $0.text.hasPrefix("diff --git") } == false)
        #expect(document.rows.contains { $0.kind == .hunk } == false)
    }

    @Test func plainFileContentIsNumberedOnceFromLineOne() {
        let document = CodexReviewDiffDocument.parse("""
        import random

        secret = random.randint(1, 10)
        """)

        #expect(document.hasOldSide == false)
        #expect(document.rows.map(\.displayLine) == [1, 2, 3])
        #expect(document.rows.allSatisfy { $0.kind == .context })
    }

    @Test func modifiedFileKeepsBothSidesAndStripsMarkers() {
        let document = CodexReviewDiffDocument.parse("""
        diff --git a/A.swift b/A.swift
        index 1234567..89abcde 100644
        --- a/A.swift
        +++ b/A.swift
        @@ -10,4 +10,4 @@ func body() {
             let before = 1
        -    let removed = 2
        +    let added = 2
             let after = 3
        """)

        #expect(document.hasOldSide)
        #expect(document.hasNewSide)
        let removed = try? #require(document.rows.first { $0.kind == .remove })
        #expect(removed?.oldLine == 11)
        #expect(removed?.newLine == nil)
        #expect(removed?.text == "    let removed = 2")
        let added = try? #require(document.rows.first { $0.kind == .add })
        #expect(added?.newLine == 11)
        #expect(added?.oldLine == nil)
        // One number per row: the new side, falling back to the old side for
        // a line that only existed before the change.
        #expect(document.rows.filter { $0.kind != .hunk }.map(\.displayLine) == [10, 11, 11, 12])
        let context = document.rows.filter { $0.kind == .context }
        #expect(context.map(\.oldLine) == [10, 12])
        #expect(context.map(\.newLine) == [10, 12])
        #expect(context.first?.text == "    let before = 1")
    }

    @Test func deletedFileShowsOnlyTheOldSide() {
        let document = CodexReviewDiffDocument.parse("""
        diff --git a/Gone.swift b/Gone.swift
        deleted file mode 100644
        --- a/Gone.swift
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two
        """)

        #expect(document.hasOldSide)
        #expect(document.hasNewSide == false)
        #expect(document.rows.filter { $0.kind == .remove }.map(\.displayLine) == [1, 2])
    }

    @Test func trailingNewlineDoesNotAddAPhantomLine() {
        let document = CodexReviewDiffDocument.parse("one\ntwo\n")
        #expect(document.rows.count == 2)
        #expect(document.widestLineNumber == 2)
    }

    @Test func fileTreeGroupsPathsAndCollapsesSingleChildChains() {
        let files = [
            change("Sources/CodexCoreUI/Review.swift"),
            change("Sources/CodexCoreUI/Diff.swift"),
            change("docs/ui/embedding.md"),
            change("README.md"),
        ]
        let nodes = CodexReviewFileTreeNode.build(files)

        #expect(nodes.map(\.name) == ["Sources/CodexCoreUI", "docs/ui", "README.md"])
        #expect(nodes[0].fileCount == 2)
        let flattened = CodexReviewFileTreeNode.flatten(nodes, collapsedIDs: [])
        #expect(flattened.count == 6)
        #expect(flattened.filter { $0.depth == 1 }.count == 3)

        let collapsed = CodexReviewFileTreeNode.flatten(
            nodes,
            collapsedIDs: [nodes[0].id]
        )
        #expect(collapsed.count == 4)
    }

    private func change(_ path: String) -> CodexGitReviewFileChange {
        CodexGitReviewFileChange(path: path, status: .modified, isStaged: false)
    }
}
