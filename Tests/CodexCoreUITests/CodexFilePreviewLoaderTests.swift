import XCTest

@testable import CodexCoreUI

/// Exercises the real tree-sitter path end to end: writing a file, loading it,
/// and confirming the bundled grammar/query resources resolve at runtime (build
/// success alone does not prove the query bundles load).
final class CodexFilePreviewLoaderTests: XCTestCase {
    private func load(_ contents: String, ext: String) throws -> CodexFilePreviewState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-preview-\(UUID().uuidString).\(ext)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return CodexFilePreviewLoader.load(url: url)
    }

    private func spans(_ state: CodexFilePreviewState) -> [CodexHighlightSpan]? {
        guard case let .text(_, spans) = state else { return nil }
        return spans
    }

    func testSwiftFileProducesHighlightSpans() throws {
        let spans = spans(try load("func greet() { let x = 1 }", ext: "swift"))
        XCTAssertNotNil(spans, "Swift file should load as text")
        XCTAssertFalse(spans?.isEmpty ?? true, "Swift highlighting should yield spans")
        XCTAssertTrue(spans?.contains { $0.kind == .keyword } ?? false, "expected a keyword token")
    }

    func testHighlightingWorksAcrossCuratedLanguages() throws {
        let samples: [(String, String)] = [
            ("{\"a\": 1}", "json"),
            ("def f():\n    return 1", "py"),
            ("package main\nfunc main() {}", "go"),
            ("fn main() { let x = 1; }", "rs"),
            ("const x = 1;", "js"),
            ("key: value", "yaml"),
        ]
        for (source, ext) in samples {
            let spans = spans(try load(source, ext: ext))
            XCTAssertFalse(spans?.isEmpty ?? true, "\(ext) highlighting should yield spans")
        }
    }

    func testBinaryFileReportsNotice() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-preview-\(UUID().uuidString).bin")
        try Data([0x00, 0x01, 0x02, 0xFF, 0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .notice = CodexFilePreviewLoader.load(url: url) else {
            return XCTFail("binary file should produce a notice")
        }
    }

    func testUnknownExtensionStillLoadsAsPlainText() throws {
        let state = try load("just some words", ext: "unknownext")
        let spans = spans(state)
        XCTAssertNotNil(spans, "unknown extensions should still preview as text")
        XCTAssertTrue(spans?.isEmpty ?? false, "no grammar means no highlight spans")
    }

    func testOversizedFilesAreRejectedBeforePreviewRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-preview-too-large-\(UUID().uuidString).swift")
        try Data(repeating: 0x20, count: CodexFilePreviewLoader.maxByteSize + 1).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard case let .notice(message) = CodexFilePreviewLoader.load(url: url) else {
            return XCTFail("files over the byte cap should not be previewed")
        }
        XCTAssertTrue(message.contains("too large"))
    }

    func testLargeTextSkipsSyntaxParsingButStillReturnsText() throws {
        let source = String(repeating: "let value = 1\n", count: 40_000)
        let state = try load(source, ext: "swift")

        guard case let .text(text, spans) = state else {
            return XCTFail("large text should remain previewable")
        }
        XCTAssertEqual(text, source)
        XCTAssertTrue(spans.isEmpty, "highlight parsing is bounded independently from preview bytes")
    }

    func testUnsupportedRefsFailClosedInsteadOfShowingWorkingTreeBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-preview-ref-\(UUID().uuidString).swift")
        try "let workingTree = true\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        guard case let .notice(message) = CodexFilePreviewLoader.load(
            reference: CodexWorkspaceFileReference(fileURL: url, ref: "main")
        ) else {
            return XCTFail("unsupported refs must not silently show working-tree bytes")
        }
        XCTAssertTrue(message.contains("current workspace"))
    }
}
