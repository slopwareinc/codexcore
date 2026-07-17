import XCTest
@testable import CodexCore

final class CodexCoreTests: XCTestCase {
    func testResolveCodexBinaryUsesExplicitExecutableOverride() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let binaryURL = directory.appendingPathComponent("codex")
        try "#!/bin/sh\n".write(to: binaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binaryURL.path
        )

        let resolved = try Codex.resolveCodexBinary(
            config: CodexConfig(codexBinaryPath: binaryURL.path)
        )
        XCTAssertEqual(resolved.path, binaryURL.path)
    }

    func testResolveCodexBinaryRejectsInvalidExplicitOverride() {
        XCTAssertThrowsError(try Codex.resolveCodexBinary(
            config: CodexConfig(
                codexBinaryPath: "/definitely/not/a/codex/runtime"
            )
        ))
    }

    func testJSONValueDecoding() throws {
        let data = try XCTUnwrap(#"{"s":"text","i":42,"d":3.14,"b":true,"n":null}"#
            .data(using: .utf8))
        let map = try JSONDecoder().decode(
            [String: CodexJSONValue].self,
            from: data
        )

        XCTAssertEqual(map["s"], .string("text"))
        XCTAssertEqual(map["i"], .int(42))
        XCTAssertEqual(map["d"], .double(3.14))
        XCTAssertEqual(map["b"], .bool(true))
        XCTAssertEqual(map["n"], .null)
    }

    func testExtractPlainSegments() {
        let blocks = MessageContentBridge.assistantRenderBlocks("Hello, world!")
        XCTAssertEqual(blocks.count, 1)
        guard case .markdown(let text) = blocks[0] else {
            return XCTFail("Expected markdown")
        }
        XCTAssertEqual(text, "Hello, world!")
    }

    func testExtractCodeBlockSegments() {
        let blocks = MessageContentBridge.assistantRenderBlocks(
            "Before\n```python\nprint('hi')\n```\nAfter"
        )
        XCTAssertEqual(blocks.count, 3)

        guard case .markdown(let before) = blocks[0],
              case .codeBlock(let language, let code) = blocks[1],
              case .markdown(let after) = blocks[2]
        else {
            return XCTFail("Expected markdown/code/markdown blocks")
        }
        XCTAssertEqual(before, "Before\n")
        XCTAssertEqual(language, "python")
        XCTAssertEqual(code, "print('hi')")
        XCTAssertEqual(after, "\nAfter")
    }

    func testExtractInlineImageSegments() {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
        let blocks = MessageContentBridge.assistantRenderBlocks(
            "Before image ![alt](data:image/png;base64,\(png)) after image"
        )
        XCTAssertEqual(blocks.count, 3)

        guard case .markdown(let before) = blocks[0],
              case .inlineImage(let data) = blocks[1],
              case .markdown(let after) = blocks[2]
        else {
            return XCTFail("Expected markdown/image/markdown blocks")
        }
        XCTAssertEqual(before, "Before image ")
        XCTAssertEqual(data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(after, " after image")
    }

    func testParseCodeReviewJSON() {
        let json = """
        {
          "findings": [{
            "title": "[P1] Fall back to turn/start when queue sync fails",
            "body": "A queued follow-up can get stuck indefinitely.",
            "confidence_score": 0.97,
            "priority": 1,
            "code_location": {
              "absolute_file_path": "/repo/mobile_client_impl.rs",
              "line_range": {"start": 799, "end": 815}
            }
          }],
          "overall_correctness": "incorrect",
          "overall_explanation": "There are blocking issues.",
          "overall_confidence_score": 0.92
        }
        """

        let payload = MessageContentBridge.parseCodeReview(text: json)
        XCTAssertEqual(
            payload?.findings.first?.title,
            "Fall back to turn/start when queue sync fails"
        )
        XCTAssertEqual(payload?.findings.first?.priority, 1)
        XCTAssertEqual(
            payload?.findings.first?.codeLocation?.lineRange?.start,
            799
        )
        XCTAssertEqual(payload?.overallCorrectness, "incorrect")

        let fenced = MessageContentBridge.parseCodeReview(text: """
        Ignore this shell example:
        ```bash
        echo "{}"
        ```

        ```json
        \(json)
        ```
        """)
        XCTAssertEqual(
            fenced?.findings.first?.title,
            "Fall back to turn/start when queue sync fails"
        )
    }
}
