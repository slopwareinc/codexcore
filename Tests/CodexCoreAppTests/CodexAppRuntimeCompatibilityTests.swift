import XCTest
@testable import CodexCore
@testable import CodexCoreApp

final class CodexAppRuntimeCompatibilityTests: XCTestCase {
    func testExactPinAndCompatiblePatchAreAccepted() throws {
        try CodexAppRuntimeCompatibility.requireFeatureStack(nil)
        let line = CodexPinnedRuntime.version.split(separator: ".").prefix(2).joined(separator: ".")
        try CodexAppRuntimeCompatibility.requireFeatureStack(.init(path: "/tmp/codex", expected: CodexPinnedRuntime.descriptor, actual: "codex-cli \(line).99"))
    }

    func testOlderCoreRuntimeGetsAnActionableAppError() {
        XCTAssertThrowsError(try CodexAppRuntimeCompatibility.requireFeatureStack(.init(path: "/tmp/codex", expected: CodexPinnedRuntime.descriptor, actual: "codex-cli 0.148.0"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Update the local Codex runtime"))
        }
    }
}
