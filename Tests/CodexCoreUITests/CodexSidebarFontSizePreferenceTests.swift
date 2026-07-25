import Foundation
import XCTest
@testable import CodexCoreUI

final class CodexSidebarFontSizePreferenceTests: XCTestCase {
    func testSidebarFontDefaultsToTwoPixelsLarger() {
        let store = SidebarFontPreferenceStore()

        XCTAssertEqual(CodexSidebarFontSizeStorage.loadSidebarFontSize(from: store), 14)
    }

    func testLargerSidebarTextKeepsIconScaleUnchanged() {
        let typography = CodexAgentTheme.Fonts.SidebarTypography.official

        XCTAssertEqual(typography.commandTitle.size, 14)
        XCTAssertEqual(typography.projectTitle.size, 14)
        XCTAssertEqual(typography.chatTitle.size, 14)
        XCTAssertEqual(typography.commandIcon.size, 13)
        XCTAssertEqual(typography.projectIcon.size, 13)
        XCTAssertEqual(typography.chatActionIcon.size, 8)
    }

    func testLegacySidebarFontSizeMigratesByTwoPixels() {
        let store = SidebarFontPreferenceStore(values: [
            "CodexCoreApp.sidebarFontSize.v2": ["12"]
        ])

        XCTAssertEqual(CodexSidebarFontSizeStorage.loadSidebarFontSize(from: store), 14)
    }

    func testExplicitCurrentSidebarFontSizeWinsOverLegacyValue() {
        let store = SidebarFontPreferenceStore(values: [
            "CodexCoreApp.sidebarFontSize.v2": ["12"],
            "CodexCoreApp.sidebarFontSize.v3": ["16"]
        ])

        XCTAssertEqual(CodexSidebarFontSizeStorage.loadSidebarFontSize(from: store), 16)
    }

    func testSavingSidebarFontSizeUsesCurrentStorageVersion() {
        let store = SidebarFontPreferenceStore()

        CodexSidebarFontSizeStorage.saveSidebarFontSize(15, to: store)

        XCTAssertEqual(store.loadStrings(forKey: "CodexCoreApp.sidebarFontSize.v3"), ["15"])
    }
}

private final class SidebarFontPreferenceStore:
    CodexStringListPreferenceStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: [String]]

    init(values: [String: [String]] = [:]) {
        self.values = values
    }

    func loadStrings(forKey key: String) -> [String] {
        lock.withLock { values[key] ?? [] }
    }

    func saveStrings(_ strings: [String], forKey key: String) {
        lock.withLock { values[key] = strings }
    }

    func hasStrings(forKey key: String) -> Bool {
        lock.withLock { values[key] != nil }
    }
}
