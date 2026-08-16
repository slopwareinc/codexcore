import Foundation
import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexPreferenceStorageTests: XCTestCase {
    func testAppearanceSettingsMigratesV1PayloadAndPreservesStoredFields() {
        let v1Payload = #"{"preset":"midnight","mode":"light","reduceMotion":true,"uiFontSize":17}"#
        let store = PreferenceStore(values: [
            CodexAppearanceSettingsStorage.legacyKey: [v1Payload]
        ])
        let failures = FailureRecorder()

        let settings = CodexAppearanceSettingsStorage.loadAppearanceSettings(
            from: store,
            onFailure: failures.record
        )

        XCTAssertEqual(settings.preset, .midnight)
        XCTAssertEqual(settings.appearanceMode, .light)
        XCTAssertTrue(settings.reduceMotion)
        XCTAssertEqual(settings.uiFontSize, 17)
        XCTAssertEqual(settings.diffMarkerStyle, .color)
        XCTAssertEqual(settings.dockIconVariant, .default)
        XCTAssertNil(settings.textFontFamily)
        XCTAssertTrue(failures.values.isEmpty)
        guard let migratedPayload = store.loadStrings(forKey: CodexAppearanceSettingsStorage.key).first else {
            XCTFail("The migrated appearance payload was not written")
            return
        }
        XCTAssertNotEqual(migratedPayload, v1Payload)
        XCTAssertTrue(migratedPayload.contains(#""appearanceMode":"light""#))
    }

    func testCorruptAppearancePayloadFallsBackAndReportsDecodeFailure() {
        let store = PreferenceStore(values: [
            CodexAppearanceSettingsStorage.key: [#"{"preset":"midnight""#]
        ])
        let failures = FailureRecorder()

        let settings = CodexAppearanceSettingsStorage.loadAppearanceSettings(
            from: store,
            onFailure: failures.record
        )

        XCTAssertEqual(settings, .official)
        XCTAssertTrue(
            failures.values.contains {
                guard case let .decodingFailed(key, _) = $0 else { return false }
                return key == CodexAppearanceSettingsStorage.key
            }
        )
    }

    func testAppearanceSaveReportsRejectedWriteAndKeepsExistingValue() {
        let staleValue = #"{"preset":"officialDark"}"#
        let store = PreferenceStore(values: [
            CodexAppearanceSettingsStorage.key: [staleValue]
        ])
        store.rejectedKeys = [CodexAppearanceSettingsStorage.key]
        let failures = FailureRecorder()

        let saved = CodexAppearanceSettingsStorage.saveAppearanceSettings(
            CodexAppearanceSettings(preset: .warmMinimal, uiFontSize: 18),
            to: store,
            onFailure: failures.record
        )

        XCTAssertFalse(saved)
        XCTAssertEqual(
            store.loadStrings(forKey: CodexAppearanceSettingsStorage.key),
            [staleValue]
        )
        XCTAssertTrue(
            failures.values.contains {
                guard case let .writeVerificationFailed(key) = $0 else { return false }
                return key == CodexAppearanceSettingsStorage.key
            }
        )
    }

    func testGitSettingsDecodesPartialV1PayloadWithFieldDefaults() {
        let v1Payload = #"{"branchPrefix":"feature/","alwaysForcePush":true}"#
        let store = PreferenceStore(values: [
            CodexGitSettingsStorage.key: [v1Payload]
        ])

        let settings = CodexGitSettingsStorage.loadGitSettings(from: store)

        XCTAssertEqual(settings.branchPrefix, "feature/")
        XCTAssertTrue(settings.alwaysForcePush)
        XCTAssertEqual(settings.mergeMethod, .merge)
        XCTAssertFalse(settings.createsDraftPullRequests)
        XCTAssertEqual(settings.commitInstructions, "")
        XCTAssertEqual(settings.pullRequestInstructions, "")
    }

    func testUnreadThreadIDsMigrateFromV1Key() {
        let store = PreferenceStore(values: [
            CodexUnreadThreadStorage.legacyKey: ["thread-b", "thread-a", "thread-a"]
        ])

        let loaded = CodexUnreadThreadStorage.loadUnreadThreadIDs(from: store)

        XCTAssertEqual(loaded, Set([ThreadID("thread-a"), ThreadID("thread-b")]))
        XCTAssertEqual(
            store.loadStrings(forKey: CodexUnreadThreadStorage.key),
            ["thread-a", "thread-b"]
        )
        XCTAssertEqual(
            store.loadCount(forKey: CodexUnreadThreadStorage.key),
            4,
            "Unread migration should reuse its initial current-key read (including the final verification read)"
        )
    }

    func testSelectedThreadIDPersistsAndCanBeCleared() {
        let store = PreferenceStore()

        XCTAssertNil(CodexSelectedThreadStorage.loadSelectedThreadID(from: store))

        XCTAssertTrue(CodexSelectedThreadStorage.saveSelectedThreadID("  thread-42  ", to: store))
        XCTAssertEqual(
            CodexSelectedThreadStorage.loadSelectedThreadID(from: store),
            "thread-42"
        )

        XCTAssertTrue(CodexSelectedThreadStorage.saveSelectedThreadID(nil, to: store))
        XCTAssertNil(CodexSelectedThreadStorage.loadSelectedThreadID(from: store))
    }
}

private final class FailureRecorder: @unchecked Sendable {
    private(set) var values: [CodexPreferenceStorageError] = []

    func record(_ error: CodexPreferenceStorageError) {
        values.append(error)
    }
}

private final class PreferenceStore: CodexStringListPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String]]
    private var loadCounts: [String: Int] = [:]
    var rejectedKeys: Set<String> = []

    init(values: [String: [String]] = [:]) {
        self.values = values
    }

    func loadStrings(forKey key: String) -> [String] {
        lock.withLock {
            loadCounts[key, default: 0] += 1
            return values[key] ?? []
        }
    }

    func loadCount(forKey key: String) -> Int {
        lock.withLock { loadCounts[key, default: 0] }
    }

    func saveStrings(_ strings: [String], forKey key: String) {
        lock.withLock {
            guard !rejectedKeys.contains(key) else { return }
            values[key] = strings
        }
    }

    func hasStrings(forKey key: String) -> Bool {
        lock.withLock { values[key] != nil }
    }
}
