import Foundation
import Testing
@testable import CodexCoreApp
@testable import CodexCoreUI

@MainActor
struct CodexSidebarWidthPreferenceTests {
    @Test func loadsTheDefaultWithoutInstallingALivePreferencesObservation() throws {
        let suiteName = "CodexSidebarWidthPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(
            CodexSidebarWidthPreference.load(from: defaults)
                == Double(CodexProjectSidebar.defaultExpandedWidth)
        )
    }

    @Test func clampsPersistedAndNewWidths() throws {
        let suiteName = "CodexSidebarWidthPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(10, forKey: CodexSidebarWidthPreference.key)
        #expect(
            CodexSidebarWidthPreference.load(from: defaults)
                == Double(CodexProjectSidebar.minExpandedWidth)
        )

        let stored = CodexSidebarWidthPreference.store(10_000, in: defaults)
        #expect(stored == Double(CodexProjectSidebar.maxExpandedWidth))
        #expect(defaults.double(forKey: CodexSidebarWidthPreference.key) == stored)
    }
}
