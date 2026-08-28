import XCTest
@testable import CodexCoreUI

final class CodexServerDiagnosticsPresentationTests: XCTestCase {
    @MainActor
    func testMemoryFormattingDistinguishesUnavailableAndReportedValues() {
        XCTAssertEqual(CodexSettingsAboutPage.memoryString(nil), "Unavailable")
        let formatted = CodexSettingsAboutPage.memoryString(1_048_576)
        XCTAssertNotEqual(formatted, "Unavailable")
        XCTAssertTrue(formatted.contains("MB") || formatted.contains("MiB"))
    }
}
