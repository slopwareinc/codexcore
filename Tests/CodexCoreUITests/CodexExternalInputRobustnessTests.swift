import XCTest
import CodexCore
@testable import CodexCoreUI

final class CodexExternalInputRobustnessTests: XCTestCase {
    func testRepeatedMCPEnvironmentKeysUseTheLastAssignment() {
        XCTAssertEqual(CodexMCPConfigurationText.dictionary("KEY=old\nKEY=new"), ["KEY": "new"])
    }

    func testInstalledAppDuplicatesMatchTypedLastRecordWinsBehavior() {
        let apps = CodexAppSummary.apps(
            listResponse: .dictionary(["data": .array([.dictionary(["id": .string("same"), "isAccessible": .bool(true)])])]),
            installedResponse: .dictionary(["apps": .array([
                .dictionary(["id": .string("same"), "runtimeName": .string("old")]),
                .dictionary(["id": .string("same"), "runtimeName": .string("new")])
            ])])
        )
        XCTAssertEqual(apps.first?.runtimeName, "new")
    }

    func testProjectAliasNormalizationMergesCollidingPathsConsistently() {
        let aliases = ["/tmp/Repo": "Canonical", "/tmp/Repo/../Repo": "Alternate", " ": "Blank"]
        let input = CodexSidebarProjectionInput(currentWorkspacePath: "/tmp/Repo", projectAliases: aliases)
        let session = CodexSidebarNavigationSession(currentWorkspacePath: "/tmp/Repo", projectAliases: aliases)
        XCTAssertEqual(input.projectAliases, ["/tmp/Repo": "Canonical"])
        XCTAssertEqual(session.projectAliases, input.projectAliases)
    }
}
