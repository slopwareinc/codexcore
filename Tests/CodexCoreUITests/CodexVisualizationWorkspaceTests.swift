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
        #expect(!document.contains("allow-same-origin"))
        #expect(!document.contains("allow-top-navigation"))
    }

    @Test func hiddenFramesStayUnmaterializedAndLRUEvictsOldestSession() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = CodexVisualizationPathPolicy(allowedRoots: [root])
        let store = CodexVisualizationFrameStore(maximumFrameCount: 2)
        var sessions: [CodexVisualizationSession] = []
        for index in 0..<3 {
            let url = root.appendingPathComponent("probe-\(index).html")
            try Data("<p>\(index)</p>".utf8).write(to: url)
            let reference = CodexVisualizationReference(
                fileURL: url,
                title: "Probe \(index)",
                origin: .init(threadID: "thread", turnID: TurnID("turn-\(index)"))
            )
            sessions.append(store.session(for: reference, policy: policy))
        }

        #expect(store.frameCount == 2)
        #expect(sessions.allSatisfy { $0.state == .unloaded })
        #expect(sessions.allSatisfy { $0.webView == nil })
        #expect(sessions.allSatisfy { $0.loadCount == 0 })
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

    @Test func visualizationAdapterRestoresOnlyWhileSourceRemainsAllowed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("restore-probe.html")
        try Data("<p>restore</p>".utf8).write(to: url)
        let resource = CodexThreadResource(
            id: "visualization:thread/turn/item:\(url.path)",
            kind: .visualization,
            title: "Restore probe",
            origin: .init(threadID: "thread", turnID: "turn", itemID: "item"),
            metadata: .init(path: url.path, mimeType: "text/html")
        )
        let store = CodexVisualizationFrameStore()
        let adapter = try #require(CodexVisualizationWorkspaceTabAdapter(
            resource: resource,
            workspaceURL: root,
            visualizationRoots: [root],
            frameStore: store
        ))
        let route = try #require(adapter.workspaceTabRegistration.durableRoute)

        #expect(CodexVisualizationWorkspaceTabAdapter(
            route: route,
            workspaceURL: root,
            visualizationRoots: [root],
            frameStore: store
        ) != nil)
        #expect(CodexVisualizationWorkspaceTabAdapter(
            route: route,
            workspaceURL: URL(fileURLWithPath: "/private/tmp/unrelated-workspace"),
            visualizationRoots: [],
            frameStore: store
        ) == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visualization-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
