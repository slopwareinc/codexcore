import XCTest
@testable import CodexCoreUI
import CodexCore

final class CodexIntegrationSemanticsTests: XCTestCase {
    func testPluginPolicyKeepsAdminDisabledAndAdminInstalledDistinct() {
        let blocked = CodexPluginSummary(
            id: "blocked",
            name: "blocked",
            marketplaceName: "managed",
            installed: false,
            enabled: false,
            installPolicy: "AVAILABLE",
            availability: "DISABLED_BY_ADMIN",
            sourceType: "remote"
        )
        XCTAssertTrue(blocked.isAdminDisabled)
        XCTAssertFalse(blocked.isInstalledByAdmin)
        XCTAssertFalse(blocked.canInstall)
        XCTAssertEqual(blocked.statusLabel, "Disabled by admin")

        let installed = CodexPluginSummary(
            id: "installed",
            name: "installed",
            marketplaceName: "managed",
            installed: true,
            enabled: true,
            installPolicy: "INSTALLED_BY_DEFAULT",
            sourceType: "remote"
        )
        XCTAssertFalse(installed.isAdminDisabled)
        XCTAssertTrue(installed.isInstalledByAdmin)
        XCTAssertFalse(installed.canUninstall)
        XCTAssertFalse(installed.supportsEnabledToggle)
        XCTAssertEqual(installed.stateLabels, ["Installed", "Enabled", "Installed by admin"])
    }

    func testMissingPluginAvailabilityRemainsUnknown() {
        let plugin = CodexPluginSummary(id: "local", name: "local", marketplaceName: "local", installed: true, enabled: false)
        XCTAssertNil(plugin.availability)
        XCTAssertEqual(plugin.statusLabel, "Disabled")
    }

    func testInstalledOnlyAppsRemainVisibleWithoutInventedCatalogState() {
        let runtime = CodexSchemaInstalledApp(
            callable: false,
            enabled: true,
            id: "runtime-only",
            runtimeName: "Runtime Only"
        )
        let joined = CodexAppSummary.join(catalog: [], installed: [runtime])
        XCTAssertEqual(joined.count, 1)
        XCTAssertTrue(joined[0].isInstalled)
        XCTAssertNil(joined[0].isAccessible)
        XCTAssertNil(joined[0].isEnabled)
        XCTAssertEqual(joined[0].runtimeEnabled, true)

        let state = CodexPluginRouteState(plugins: [], apps: joined)
        XCTAssertEqual(state.manageCounts.first { $0.tab == .apps }?.count, 1)
        XCTAssertEqual(state.visibleApps.map(\.id), ["runtime-only"])
    }

    func testSkillsRequireAuthoritativeEnabledStateAndKeepCwdIdentity() {
        let missingEnabled: CodexJSONValue = .dictionary([
            "name": .string("deploy"),
            "path": .string("/repo/.agents/skills/deploy/SKILL.md")
        ])
        XCTAssertNil(CodexSkillSummary(raw: missingEnabled, cwd: "/repo"))

        let dependency: CodexJSONValue = .dictionary([
            "name": .string("deploy"),
            "path": .string("/shared/deploy/SKILL.md"),
            "enabled": .bool(false),
            "dependencies": .dictionary([
                "tools": .array([
                    .dictionary(["type": .string("binary"), "value": .string("git")])
                ])
            ])
        ])
        let first = CodexSkillSummary(raw: dependency, cwd: "/repo-a")
        let second = CodexSkillSummary(raw: dependency, cwd: "/repo-b")
        XCTAssertNotNil(first)
        XCTAssertFalse(first?.enabled ?? true)
        XCTAssertEqual(first?.dependencies, ["binary: git"])
        XCTAssertNotEqual(first?.id, second?.id)
    }

    func testSkillListErrorsRemainVisibleWithTheirReportedPath() {
        let response: CodexJSONValue = .dictionary([
            "data": .array([
                .dictionary([
                    "cwd": .string("/repo"),
                    "skills": .array([]),
                    "errors": .array([
                        .dictionary([
                            "path": .string("/repo/.agents/skills/broken/SKILL.md"),
                            "message": .string("invalid front matter")
                        ])
                    ])
                ])
            ])
        ])
        var session = CodexIntegrationCatalogSession()
        session.applySkillResponse(response)
        XCTAssertEqual(session.skillLoadErrors, ["/repo/.agents/skills/broken/SKILL.md: invalid front matter"])
        XCTAssertNil(session.skillErrorMessage)
    }


    func testMalformedPluginLifecycleIsNotDefaultedIntoAnActionableRecord() {
        let response: CodexJSONValue = .dictionary([
            "marketplaces": .array([
                .dictionary([
                    "name": .string("official"),
                    "plugins": .array([
                        .dictionary([
                            "id": .string("missing-lifecycle"),
                            "name": .string("missing-lifecycle")
                        ])
                    ])
                ])
            ])
        ])
        XCTAssertTrue(CodexPluginSummary.plugins(from: response).isEmpty)
    }

}
