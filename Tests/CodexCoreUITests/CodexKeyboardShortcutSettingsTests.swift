import Foundation
import XCTest
@testable import CodexCoreUI

final class CodexKeyboardShortcutSettingsTests: XCTestCase {
    func testDefaultsExposeReferenceAppShortcuts() {
        let defaults = CodexKeyboardShortcutSettings.defaults

        XCTAssertEqual(defaults.search.displayValue, "⌘G")
        XCTAssertEqual(defaults.newChat.displayValue, "⌘N")
        XCTAssertEqual(defaults.toggleSidebar.displayValue, "⌃⌘S")
        XCTAssertEqual(defaults[.search], defaults.search)
    }

    func testStoragePersistsCapturedShortcuts() {
        let store = KeyboardShortcutPreferenceStore()
        var settings = CodexKeyboardShortcutSettings.defaults
        settings.search = CodexKeyboardShortcut(
            key: "k",
            modifiers: [.command, .shift]
        )

        CodexKeyboardShortcutStorage.save(settings, to: store)

        XCTAssertEqual(CodexKeyboardShortcutStorage.load(from: store), settings)
        XCTAssertEqual(CodexKeyboardShortcutStorage.load(from: store).search.displayValue, "⇧⌘K")
    }

    func testUnknownStoredSettingsFallBackToDefaults() {
        let store = KeyboardShortcutPreferenceStore(defaultValue: ["not-json"])

        XCTAssertEqual(CodexKeyboardShortcutStorage.load(from: store), .defaults)
    }

    func testResetRestoresAllActions() {
        var settings = CodexKeyboardShortcutSettings(
            search: CodexKeyboardShortcut(key: "f", modifiers: .option),
            newChat: CodexKeyboardShortcut(key: "j", modifiers: .control),
            toggleSidebar: CodexKeyboardShortcut(key: "b", modifiers: .shift)
        )

        settings.reset()

        XCTAssertEqual(settings, .defaults)
    }
}

private final class KeyboardShortcutPreferenceStore: CodexStringListPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String]] = [:]
    private let defaultValue: [String]

    init(defaultValue: [String] = []) {
        self.defaultValue = defaultValue
    }

    func loadStrings(forKey key: String) -> [String] {
        lock.withLock { values[key] ?? defaultValue }
    }

    func saveStrings(_ strings: [String], forKey key: String) {
        lock.withLock { values[key] = strings }
    }

    func hasStrings(forKey key: String) -> Bool {
        lock.withLock { values[key] != nil }
    }
}
