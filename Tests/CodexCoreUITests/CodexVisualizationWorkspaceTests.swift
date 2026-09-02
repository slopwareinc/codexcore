import AppKit
import CodexCore
import Foundation
import Testing
@testable import CodexCoreUI

@MainActor
struct CodexVisualizationWorkspaceTests {
    @Test func pathPolicyAcceptsOnlyBoundedHTMLInsideExplicitRoots() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("render-probe.html")
        let unsafeName = root.appendingPathComponent("Unsafe Name.html")
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-probe.html")
        try Data("<div>probe</div>".utf8).write(to: allowed)
        try Data("<div>unsafe</div>".utf8).write(to: unsafeName)
        try Data("<div>outside</div>".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let policy = CodexVisualizationPathPolicy(allowedRoots: [root])

        #expect(try policy.validate(allowed) == allowed.standardizedFileURL)
        #expect(throws: CodexVisualizationLoadError.invalidFileName) {
            try policy.validate(unsafeName)
        }
        #expect(throws: CodexVisualizationLoadError.outsideAllowedRoots) {
            try policy.validate(outside)
        }
    }

    @Test func sandboxDocumentMatchesOfficialIsolationShape() {
        let document = CodexVisualizationSandboxDocument.render(
            fragment: #"<button onclick="document.body.dataset.clicked='yes'">Probe</button>"#,
            title: "Probe"
        )

        #expect(document.contains(#"sandbox="allow-scripts""#))
        #expect(document.contains("default-src 'none'"))
        #expect(document.contains("connect-src blob: data:"))
        #expect(document.contains("form-action 'none'"))
        #expect(document.contains("ResizeObserver"))
        #expect(document.contains("codexVisualizationHeight"))
        #expect(!document.contains("allow-same-origin"))
        #expect(!document.contains("allow-top-navigation"))
    }

    @Test func fragmentLoaderReadsTheInteractiveProbeWithoutExecutingIt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("interactive-probe.html")
        let fragment = #"<button id="probe">Run</button><script>document.getElementById('probe').dataset.ready='yes'</script>"#
        try Data(fragment.utf8).write(to: url)
        let reference = CodexVisualizationReference(
            fileURL: url,
            title: "Interactive probe",
            origin: .init(threadID: "thread", turnID: "turn")
        )

        let loaded = try await CodexVisualizationFragmentLoader.load(
            reference: reference,
            policy: .init(allowedRoots: [root])
        )

        #expect(loaded == fragment)
    }

    @Test func transcriptAnchorReusesItsRetainedFrame() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("retained-probe.html")
        try Data("<p>retained</p>".utf8).write(to: url)
        let coordinator = CodexInlineVisualizationCoordinator(allowedRoots: [root])
        let itemID = CodexTranscriptRenderItemID(rawValue: "visualization-item")
        let render = CodexTranscriptVisualizationRender(
            path: url.path,
            title: "Retained probe",
            isWide: false,
            isExpandable: true,
            sourceThreadID: nil,
            variant: .inline
        )
        let firstAnchor = CodexInlineVisualizationAnchorView(frame: .init(x: 0, y: 0, width: 600, height: 240))
        coordinator.attach(render, itemID: itemID, threadID: "thread", to: firstAnchor) { _ in }
        for _ in 0..<100 where coordinator.sessionsForTesting.first?.webView == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let session = try #require(coordinator.sessionsForTesting.first)
        let webView = try #require(session.webView)
        #expect(session.loadCount == 1)

        coordinator.detach(firstAnchor)
        let secondAnchor = CodexInlineVisualizationAnchorView(frame: firstAnchor.frame)
        coordinator.attach(render, itemID: itemID, threadID: "thread", to: secondAnchor) { _ in }

        #expect(coordinator.frameCountForTesting == 1)
        #expect(session.webView === webView)
        #expect(webView.superview === secondAnchor)
        #expect(session.loadCount == 1)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visualization-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
