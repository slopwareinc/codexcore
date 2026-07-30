import XCTest
@testable import CodexCoreUI

final class CodexResponseTextAnnotationTests: XCTestCase {
    func testPromptCodecMatchesOfficialResponseAnnotationEnvelope() throws {
        let annotations = [
            annotation(
                id: "one",
                text: "The selected sentence.",
                note: "Explain this.",
                itemID: "answer:1",
                range: 4..<26
            ),
            annotation(
                id: "two",
                text: "Another selection.",
                itemID: "answer:2",
                range: 0..<18
            ),
        ]

        let encoded = CodexComposerPromptCodec.encode(
            files: [],
            responseAnnotations: annotations,
            request: "Please address these."
        )

        XCTAssertEqual(
            encoded,
            "\n# Response annotations:\n"
                + "Each item contains text selected from an earlier Codex response and may include a user comment. "
                + "Treat items as Annotation 1, Annotation 2, and so on in array order. "
                + "Use every selection as context and address every comment. "
                + "When addressing multiple comments, label each answer with its annotation number "
                + "(for example, `Annotation 1`) so the user can match it to the numbered annotation.\n"
                + "<response-annotations>\n"
                + "[{\"text\":\"The selected sentence.\",\"annotation\":\"Explain this.\"},"
                + "{\"text\":\"Another selection.\"}]\n"
                + "</response-annotations>\n"
                + "\n## My request for Codex:\nPlease address these.\n"
        )

        let decoded = try XCTUnwrap(CodexComposerPromptCodec.decode(encoded))
        XCTAssertEqual(decoded.request, "Please address these.")
        XCTAssertEqual(decoded.files, [])
        XCTAssertEqual(decoded.responseAnnotations, annotations.map(\.content))
    }

    func testPromptCodecComposesAnnotationsBeforeFileContext() throws {
        let file = CodexReferencedFile(path: "/tmp/Example.swift")
        let encoded = CodexComposerPromptCodec.encode(
            files: [file],
            responseAnnotations: [
                annotation(
                    id: "one",
                    text: "Use the same approach.",
                    itemID: "answer:1",
                    range: 0..<22
                )
            ],
            request: "Apply it here."
        )

        XCTAssertLessThan(
            try XCTUnwrap(encoded.range(of: "# Response annotations:")?.lowerBound),
            try XCTUnwrap(encoded.range(of: "# Files mentioned by the user:")?.lowerBound)
        )
        let decoded = try XCTUnwrap(CodexComposerPromptCodec.decode(encoded))
        XCTAssertEqual(decoded.request, "Apply it here.")
        XCTAssertEqual(decoded.files, [file])
        XCTAssertEqual(decoded.responseAnnotations.map(\.text), ["Use the same approach."])
    }

    func testMalformedAnnotationEnvelopeRemainsVisibleText() {
        let malformed = """

        # Response annotations:
        broken
        """
        XCTAssertNil(CodexComposerPromptCodec.decode(malformed))
    }

    func testAnnotationOnlyDraftIsTaskScopedConsumedAndRestored() throws {
        var session = CodexComposerStateSession()
        let first = annotation(
            id: "first",
            text: "Selection A",
            itemID: "answer:a",
            range: 2..<13
        )
        let second = annotation(
            id: "second",
            text: "Selection B",
            note: "Why?",
            itemID: "answer:b",
            range: 8..<19
        )

        session.setActiveThreadID("thread-a")
        session.responseAnnotations = [first]
        session.setActiveThreadID("thread-b")
        session.responseAnnotations = [second]

        XCTAssertEqual(session.responseAnnotations(for: "thread-a"), [first])
        let submission = try XCTUnwrap(session.consumeDraftForTurn())
        XCTAssertEqual(submission.prompt, "")
        XCTAssertEqual(submission.responseAnnotations, [second])
        XCTAssertTrue(session.responseAnnotations(for: "thread-b").isEmpty)

        session.restore(submission)
        XCTAssertEqual(session.responseAnnotations(for: "thread-b"), [second])
        XCTAssertEqual(session.responseAnnotations(for: "thread-a"), [first])
    }

    func testDraftAnnotationsPreserveOrderAndNormalizeEmptyComment() {
        var session = CodexComposerStateSession()
        session.setActiveThreadID("thread")
        let first = annotation(
            id: "first",
            text: "Selection A",
            itemID: "answer:a",
            range: 0..<11
        )
        let second = annotation(
            id: "second",
            text: "Selection B",
            itemID: "answer:b",
            range: 0..<11
        )
        session.setResponseAnnotations([first, second], for: "thread")

        var edited = first
        edited.annotation = "   "
        session.setResponseAnnotations([edited, second], for: "thread")

        XCTAssertEqual(session.responseAnnotations.map(\.id), ["first", "second"])
        XCTAssertNil(session.responseAnnotations.first?.annotation)
    }

    private func annotation(
        id: String,
        text: String,
        note: String? = nil,
        itemID: String,
        range: Range<Int>
    ) -> CodexResponseTextAnnotation {
        CodexResponseTextAnnotation(
            id: id,
            text: text,
            annotation: note,
            anchor: CodexResponseTextAnchor(
                renderItemID: itemID,
                startOffset: range.lowerBound,
                endOffset: range.upperBound
            )
        )
    }
}
