import Foundation
import XCTest
@testable import CodexCoreUI

final class CodexThreadHistoryPreferenceTests: XCTestCase {
    func testNewThreadHistoryModeDefaultsToLegacy() {
        let store = LockedStringListPreferenceStore()

        XCTAssertEqual(CodexNewThreadHistoryModeStorage.load(from: store), .legacy)
    }

    func testNewThreadHistoryModePersistsExplicitPaginatedOptIn() {
        let store = LockedStringListPreferenceStore()

        CodexNewThreadHistoryModeStorage.save(.paginated, to: store)

        XCTAssertEqual(CodexNewThreadHistoryModeStorage.load(from: store), .paginated)
    }

    func testUnknownPersistedHistoryModeFallsBackToLegacy() {
        let store = LockedStringListPreferenceStore(defaultValue: ["future-mode"])

        XCTAssertEqual(CodexNewThreadHistoryModeStorage.load(from: store), .legacy)
    }

    func testFollowUpBehaviorDefaultsToQueue() {
        let store = LockedStringListPreferenceStore()

        XCTAssertEqual(CodexFollowUpBehaviorStorage.load(from: store), .queue)
    }

    func testFollowUpBehaviorPersistsSteer() {
        let store = LockedStringListPreferenceStore()

        CodexFollowUpBehaviorStorage.save(.steer, to: store)

        XCTAssertEqual(CodexFollowUpBehaviorStorage.load(from: store), .steer)
    }

    func testUnknownPersistedFollowUpBehaviorFallsBackToQueue() {
        let store = LockedStringListPreferenceStore(defaultValue: ["future-behavior"])

        XCTAssertEqual(CodexFollowUpBehaviorStorage.load(from: store), .queue)
    }
}

private final class LockedStringListPreferenceStore:
    CodexStringListPreferenceStore,
    @unchecked Sendable
{
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
