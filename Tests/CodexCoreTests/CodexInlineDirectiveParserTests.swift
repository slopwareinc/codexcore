@testable import CodexCore
import Testing

struct CodexInlineDirectiveParserTests {
    @Test func parsesKnownDirectiveShapesAndEscapedValues() throws {
        let created = try #require(CodexInlineDirectiveParser.parse(
            line: #"::created-thread{threadId="019f" pendingWorktreeId="pending"}"#
        ))
        #expect(created.name == "created-thread")
        #expect(created.attributes["threadId"] == "019f")
        #expect(created.attributes["pendingWorktreeId"] == "pending")

        let pullRequest = try #require(CodexInlineDirectiveParser.parse(
            line: #"::git-create-pr{cwd="/tmp/repo" branch="feature" url="https://example.com/pr/1" isDraft=true}"#
        ))
        #expect(pullRequest.attributes["isDraft"] == "true")

        let comment = try #require(CodexInlineDirectiveParser.parse(
            line: #"::code-comment{title="Quote" body="Escaped \"body\"" file="Sources/A.swift" start=42 end=43 priority=2}"#
        ))
        #expect(comment.attributes["body"] == #"Escaped "body""#)
        #expect(comment.attributes["priority"] == "2")

        let empty = try #require(CodexInlineDirectiveParser.parse(line: "::archive-thread{}"))
        #expect(empty.attributes.isEmpty)
    }

    @Test func rejectsInlineMentionsAndSplitsDirectiveLinesInOrder() {
        #expect(CodexInlineDirectiveParser.parse(line: "keep ::created-thread{threadId=abc} inline") == nil)
        let parts = CodexInlineDirectiveParser.split(text: "Before\n::created-thread{clientThreadId=client-new-thread:abc}\nAfter")
        #expect(parts.count == 3)
        #expect(parts[0].text == "Before\n")
        #expect(parts[1].directive?.name == "created-thread")
        #expect(parts[2].text == "After")
    }
}
