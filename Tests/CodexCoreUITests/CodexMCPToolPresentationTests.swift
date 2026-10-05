@testable import CodexCore
@testable import CodexCoreUI
import Testing

struct CodexMCPToolPresentationTests {
    @Test func browserMetadataUsesScreenshotThenBrowserUseThenLatestValidTab() {
        var payload = toolPayload(surface: [
            "kind": .string("browserUse"), "browserFamily": .string("chromium"),
            "screenshot": .dictionary(["pageUrl": .string("https://example.com/current")]),
            "openTabs": .array([
                .dictionary(["url": .string("https://example.com/older")]),
                .dictionary(["url": .string("https://example.com/latest")]),
                .dictionary(["url": .string("javascript:alert(1)")]),
            ]),
        ], extraMetadata: ["browser_use": .dictionary(["url": .string("https://example.com/fallback")])])
        let screenshot = CodexMCPToolPresentationV2.project(payload: payload)
        #expect(screenshot == .init(sourceName: "Chrome", title: "open page", symbolName: "globe", pageURL: "https://example.com/current"))
        var result = payload["result"]!.objectValue!
        var metadata = result["_meta"]!.objectValue!
        var surface = metadata["codex/toolSurface"]!.objectValue!
        surface["screenshot"] = .dictionary(["pageUrl": .string("file:///private/file")])
        metadata["codex/toolSurface"] = .dictionary(surface)
        result["_meta"] = .dictionary(metadata)
        payload["result"] = .dictionary(result)
        #expect(CodexMCPToolPresentationV2.project(payload: payload).pageURL == "https://example.com/fallback")
        metadata.removeValue(forKey: "browser_use")
        result["_meta"] = .dictionary(metadata)
        payload["result"] = .dictionary(result)
        #expect(CodexMCPToolPresentationV2.project(payload: payload).pageURL == "https://example.com/latest")
    }

    @Test func browserAppContextWinsAndUnsupportedSourcesRemainReadable() {
        var payload = toolPayload(surface: ["kind": .string("browserUse"), "backend": .string("iab")])
        payload["appContext"] = .dictionary(["appName": .string("Microsoft Edge browser"), "actionName": .string("Read page")])
        let presentation = CodexMCPToolPresentationV2.project(payload: payload)
        #expect(presentation.sourceName == "Microsoft Edge")
        #expect(presentation.title == "Read page")
        #expect(presentation.pageURL == nil)
        payload["appContext"] = .null
        #expect(CodexMCPToolPresentationV2.project(payload: payload).sourceName == "Browser")
    }

    @Test func computerMetadataUsesReportedAppThenArgumentsThenKnownBundleID() {
        var payload = toolPayload(surface: [
            "kind": .string("computerUse"), "app": .dictionary(["kind": .string("appId"), "appId": .string("com.apple.finder")]),
        ])
        let native = CodexMCPToolPresentationV2.project(payload: payload)
        #expect(native.sourceName == "Finder")
        #expect(native.symbolName == "desktopcomputer")
        payload["arguments"] = .dictionary(["application": .string("Xcode")])
        #expect(CodexMCPToolPresentationV2.project(payload: payload).sourceName == "Xcode")
        payload["appContext"] = .dictionary(["appName": .string("  App   Name  ")])
        #expect(CodexMCPToolPresentationV2.project(payload: payload).sourceName == "App Name")
    }

    @Test func ordinaryIntegrationMetadataHasReadableSourceAndPreservesToolData() {
        let payload = toolPayload(surface: [:], extraMetadata: ["source": .dictionary(["name": .string("Docs App")])])
        let copy = payload
        let presentation = CodexMCPToolPresentationV2.project(payload: payload)
        #expect(presentation.sourceName == "Docs App")
        #expect(presentation.title == "open page")
        #expect(presentation.symbolName == "puzzlepiece.extension")
        #expect(presentation.pageURL == nil)
        #expect(payload == copy)
    }

    @Test(arguments: ["javascript:alert(1)", "file:///private/file", "https://user:secret@example.com/", "https:///", "https://example.com/\n", String(repeating: "x", count: 4_097)])
    func browserPageURLRejectsInvalidSchemesCredentialsControlCharactersAndOversizedValues(value: String) {
        let payload = toolPayload(surface: [
            "kind": .string("browserUse"), "screenshot": .dictionary(["pageUrl": .string(value)]),
        ])
        #expect(CodexMCPToolPresentationV2.project(payload: payload).pageURL == nil)
    }

    @Test func oversizeMetadataFallsBackToBoundedServerFacts() {
        var payload = toolPayload(surface: [:])
        payload["appContext"] = .dictionary([
            "appName": .string(String(repeating: "x", count: 161)),
            "actionName": .string(String(repeating: "x", count: 10_000)),
        ])
        let presentation = CodexMCPToolPresentationV2.project(payload: payload)
        #expect(presentation.sourceName == "docs server")
        #expect(presentation.title == "open page")
    }

    private func toolPayload(surface: [String: CodexJSONValue], extraMetadata: [String: CodexJSONValue] = [:]) -> [String: CodexJSONValue] {
        var metadata = extraMetadata
        metadata["codex/toolSurface"] = .dictionary(surface)
        return [
            "server": .string("docs_server"), "tool": .string("open_page"),
            "arguments": .dictionary(["query": .string("unchanged")]),
            "result": .dictionary(["_meta": .dictionary(metadata), "content": .array([])]),
        ]
    }
}
