import Foundation
import XCTest
@testable import CodexCoreApp

@MainActor
final class CodexAutomationNotificationServiceTests: XCTestCase {
    func testSwiftRunBundleDoesNotConstructNotificationCenter() {
        let executableDirectory = URL(
            fileURLWithPath: "/tmp/CodexCore/.build/arm64-apple-macosx/debug/",
            isDirectory: true
        )

        XCTAssertFalse(CodexAutomationNotificationService.supportsNotifications(
            bundleURL: executableDirectory,
            bundleIdentifier: nil
        ))
    }

    func testApplicationBundleSupportsNotifications() {
        let applicationURL = URL(fileURLWithPath: "/Applications/CodexCore.app", isDirectory: true)

        XCTAssertTrue(CodexAutomationNotificationService.supportsNotifications(
            bundleURL: applicationURL,
            bundleIdentifier: "com.slopware.CodexCore"
        ))
    }

    func testCurrentTestHostInitializesWithoutTouchingUnsupportedCenter() {
        let service = CodexAutomationNotificationService(bundle: .main)

        XCTAssertEqual(
            service.isAvailable,
            Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
                && Bundle.main.bundleIdentifier != nil
        )
    }
}
