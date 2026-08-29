import CodexCore
import Foundation
import Testing
@testable import CodexCoreApp
@testable import CodexCoreUI

@MainActor
struct CodexVisualizationRuntimeRootsTests {
    @Test func configuredCodexHomeVisualizationRootIsWritableByEveryThread() {
        let home = CodexHome(path: "/private/tmp/custom-codex-home")
        let model = CodexCoreAppModel(
            codexHome: home,
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: CodexNoopStringListPreferenceStore()
        )
        model.workspacePath = "/private/tmp/project"

        let roots = model.threadStartParameters().runtimeWorkspaceRoots?
            .compactMap { value -> String? in
                guard case .string(let path) = value.rawValue else { return nil }
                return path
            } ?? []

        #expect(roots.contains("/private/tmp/project"))
        #expect(roots.contains(home.visualizationsDirectoryURL.path))

        model.projectlessDraftPaths = CodexProjectlessThreadPaths(
            workspaceRoot: "/private/tmp/projectless",
            cwd: "/private/tmp/projectless/work",
            outputDirectory: "/private/tmp/projectless/output"
        )
        let projectless = try? model.threadStartParametersForCurrentDraft()
        let projectlessRoots: [String] = projectless?.runtimeWorkspaceRoots?.compactMap {
            guard case .string(let path) = $0.rawValue else { return nil }
            return path
        } ?? []
        #expect(projectlessRoots.contains(home.visualizationsDirectoryURL.path))
    }
}
