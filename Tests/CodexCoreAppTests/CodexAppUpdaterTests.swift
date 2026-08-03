import Foundation
import XCTest
@testable import CodexCoreApp

@MainActor
final class CodexAppUpdaterTests: XCTestCase {
    func testUpdatesDefaultToEnabled() throws {
        let defaults = try makeDefaults()

        XCTAssertTrue(CodexAppUpdatePolicy.isEnabled(in: defaults))
    }

    func testManagedPreferenceCanDisableUpdates() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: CodexAppUpdatePolicy.preferenceKey)

        XCTAssertFalse(CodexAppUpdatePolicy.isEnabled(in: defaults))
    }

    func testPackagedConfigurationRequiresHTTPSFeedAndNonPlaceholderKey() {
        XCTAssertTrue(CodexAppUpdatePolicy.hasPackagedConfiguration([
            "SUFeedURL": "https://updates.example.com/codexcore/appcast.xml",
            "SUPublicEDKey": testPublicKey,
        ]))
        XCTAssertFalse(CodexAppUpdatePolicy.hasPackagedConfiguration([
            "SUFeedURL": "http://updates.example.com/codexcore/appcast.xml",
            "SUPublicEDKey": testPublicKey,
        ]))
        XCTAssertFalse(CodexAppUpdatePolicy.hasPackagedConfiguration([
            "SUFeedURL": "https://updates.example.invalid/codexcore/appcast.xml",
            "SUPublicEDKey": "REPLACE_WITH_SPARKLE_ED25519_PUBLIC_KEY",
        ]))
    }

    func testDisabledPolicyDoesNotConstructUpdater() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: CodexAppUpdatePolicy.preferenceKey)

        let appUpdater = CodexAppUpdater(
            userDefaults: defaults,
            infoDictionary: [
                "SUFeedURL": "https://updates.example.com/codexcore/appcast.xml",
                "SUPublicEDKey": testPublicKey,
            ]
        )

        XCTAssertNil(appUpdater.updater)
        XCTAssertFalse(appUpdater.checkForUpdatesMenuItem.isEnabled)
    }

    private var testPublicKey: String {
        Data(repeating: 1, count: 32).base64EncodedString()
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "CodexAppUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
