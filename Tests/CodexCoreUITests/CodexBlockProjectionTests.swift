import Foundation
import Testing
@testable import CodexCoreUI

struct CodexBlockProjectionTests {
    @Test func projectsCommonMarkdownBlocksIncludingRawHTML() throws {
        let blocks = CodexBlockProjector.project(
            "# Heading\n\n> quoted **text**\n\n---\n\n<div>raw</div>",
            cacheNamespace: "test"
        )

        #expect(blocks.count == 4)
        guard case .heading(_, 1, "Heading", _) = blocks[0] else {
            Issue.record("Expected a heading block")
            return
        }
        guard case .blockquote(_, "quoted **text**", _) = blocks[1] else {
            Issue.record("Expected a blockquote block")
            return
        }
        guard case .horizontalRule = blocks[2] else {
            Issue.record("Expected a horizontal-rule block")
            return
        }
        guard case .htmlFallback(_, "<div>raw</div>") = blocks[3] else {
            Issue.record("Expected raw HTML to remain a fallback block")
            return
        }
    }

    @Test func parsesTaskListsWithFourSpaceAndTabNesting() throws {
        let blocks = CodexBlockProjector.project(
            "- [ ] parent\n    continuation\n\t- [x] child\n\n- [x] second",
            cacheNamespace: "test"
        )
        guard case .list(_, false, let items) = try #require(blocks.first) else {
            Issue.record("Expected a list block")
            return
        }

        #expect(items.map(\.depth) == [0, 1, 0])
        #expect(items.map(\.isTask) == [true, true, true])
        #expect(items.map(\.isCompleted) == [false, true, true])
        #expect(items[0].text == "parent\ncontinuation")
        #expect(items[1].text == "child")
    }

    @Test func preservesMultiParagraphListItemText() throws {
        let blocks = CodexBlockProjector.project(
            "- first paragraph\n\n    second paragraph\n- second item",
            cacheNamespace: "test"
        )
        guard case .list(_, _, let items) = try #require(blocks.first) else {
            Issue.record("Expected a list block")
            return
        }
        #expect(items.count == 2)
        #expect(items[0].text == "first paragraph\n\nsecond paragraph")
        #expect(items[1].text == "second item")
    }
}
