import CodexCore
import Foundation
import Testing
@testable import CodexCoreApp

struct CodexBuiltInVisualizationSkillTests {
    @Test func installsOfficialDirectiveContractWithoutOverwritingUserSkill() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visualize-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = CodexHome(path: root.path)

        try await CodexBuiltInVisualizationSkill.install(in: home)
        let file = root.appendingPathComponent("skills/visualize/SKILL.md")
        let installed = try String(contentsOf: file, encoding: .utf8)
        #expect(installed.contains("visualize"))
        #expect(installed.contains("HTML fragment only"))

        try "user-owned".write(to: file, atomically: true, encoding: .utf8)
        try await CodexBuiltInVisualizationSkill.install(in: home)
        #expect(try String(contentsOf: file, encoding: .utf8) == "user-owned")
    }
}
