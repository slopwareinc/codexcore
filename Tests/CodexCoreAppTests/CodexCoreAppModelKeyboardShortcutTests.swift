import CodexCore
@testable import CodexCoreApp
@testable import CodexCoreUI
import Foundation
import XCTest

@MainActor
final class CodexCoreAppModelKeyboardShortcutTests: XCTestCase {
    func testAppModelLoadsAndPersistsKeyboardShortcutSettings() {
        let store = AppKeyboardShortcutPreferenceStore()
        let captured = CodexKeyboardShortcut(
            key: "k",
            modifiers: [.command, .shift]
        )
        CodexKeyboardShortcutStorage.save(
            CodexKeyboardShortcutSettings(
                search: captured,
                newChat: .command("n"),
                toggleSidebar: CodexKeyboardShortcut(key: "s", modifiers: [.command, .control])
            ),
            to: store
        )

        let app = CodexCoreAppModel(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: store
        )

        XCTAssertEqual(app.keyboardShortcutSettings.search, captured)

        app.keyboardShortcutSettings.search = .command("f")

        XCTAssertEqual(
            CodexKeyboardShortcutStorage.load(from: store).search,
            .command("f")
        )
    }
}

private final class AppKeyboardShortcutPreferenceStore: CodexStringListPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String]] = [:]

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
