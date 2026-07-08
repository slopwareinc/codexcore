import Foundation

// Reusable persistence codecs over the injected `CodexStringListPreferenceStore`.
// These were previously private to CodexCoreApp but are host-agnostic (they only
// depend on the injection protocol and CodexCoreUI value types), so any host app
// embedding CodexCoreUI gets settings persistence for free.
//
// The storage keys keep their original "CodexCoreApp." namespace so existing
// persisted state is preserved across this move.

public enum CodexPinnedThreadStorage {
    private static let pinnedThreadStorageKey = "CodexCoreApp.pinnedThreadIDs"

    public static func loadPinnedThreadIDs(
        from store: any CodexStringListPreferenceStore
    ) -> [String] {
        deduped(store.loadStrings(forKey: pinnedThreadStorageKey))
    }

    public static func savePinnedThreadIDs(
        _ ids: [String],
        to store: any CodexStringListPreferenceStore
    ) {
        store.saveStrings(deduped(ids), forKey: pinnedThreadStorageKey)
    }

    private static func deduped(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for id in ids where !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }
}

public enum CodexAppearanceSettingsStorage {
    private static let appearanceSettingsKey = "CodexCoreApp.appearanceSettings.v2"

    public static func loadAppearanceSettings(from store: any CodexStringListPreferenceStore) -> CodexAppearanceSettings {
        guard let stored = store.loadStrings(forKey: appearanceSettingsKey).first,
              let data = stored.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CodexAppearanceSettings.self, from: data)
        else {
            return .official
        }
        return decoded
    }

    public static func saveAppearanceSettings(
        _ settings: CodexAppearanceSettings,
        to store: any CodexStringListPreferenceStore
    ) {
        guard let data = try? JSONEncoder().encode(settings),
              let string = String(data: data, encoding: .utf8)
        else {
            return
        }
        store.saveStrings([string], forKey: appearanceSettingsKey)
    }
}

public enum CodexGitSettingsStorage {
    private static let gitSettingsKey = "CodexCoreApp.gitSettings.v1"

    public static func loadGitSettings(from store: any CodexStringListPreferenceStore) -> CodexGitSettings {
        guard let stored = store.loadStrings(forKey: gitSettingsKey).first,
              let data = stored.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CodexGitSettings.self, from: data)
        else {
            return .defaults
        }
        return decoded
    }

    public static func saveGitSettings(
        _ settings: CodexGitSettings,
        to store: any CodexStringListPreferenceStore
    ) {
        guard let data = try? JSONEncoder().encode(settings),
              let string = String(data: data, encoding: .utf8)
        else {
            return
        }
        store.saveStrings([string], forKey: gitSettingsKey)
    }
}

public enum CodexSidebarFontSizeStorage {
    public static let defaultFontSize = CodexAgentTheme.Fonts.SidebarTypography.defaultBaseTextSize
    public static let fontSizeRange = CodexAgentTheme.Fonts.SidebarTypography.baseTextSizeRange
    private static let sidebarFontSizeKey = "CodexCoreApp.sidebarFontSize.v2"

    public static func loadSidebarFontSize(from store: any CodexStringListPreferenceStore) -> Double {
        guard let stored = store.loadStrings(forKey: sidebarFontSizeKey).first,
              let value = Double(stored)
        else {
            return defaultFontSize
        }
        return clamped(value)
    }

    public static func saveSidebarFontSize(
        _ fontSize: Double,
        to store: any CodexStringListPreferenceStore
    ) {
        store.saveStrings([String(Int(clamped(fontSize).rounded()))], forKey: sidebarFontSizeKey)
    }

    public static func clamped(_ fontSize: Double) -> Double {
        guard fontSize.isFinite else { return defaultFontSize }
        return min(max(fontSize, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }
}

public enum CodexExpandedProjectStorage {
    private static let expandedProjectStorageKey = "CodexCoreApp.expandedProjectIDs"
    private static let persistedMarker = "__codex_expanded_project_state_v2__"
    private static let legacyPersistedMarkers: Set<String> = [
        "__codex_expanded_project_state_v1__"
    ]

    public static func loadExpandedProjectState(
        from store: any CodexStringListPreferenceStore
    ) -> (hasStoredState: Bool, ids: Set<String>) {
        let stored = store.loadStrings(forKey: expandedProjectStorageKey)
        if stored.contains(persistedMarker) {
            return (true, Set(normalized(stored.filter { $0 != persistedMarker && !legacyPersistedMarkers.contains($0) })))
        }
        if stored.contains(where: legacyPersistedMarkers.contains) {
            return (false, [])
        }
        return (store.hasStrings(forKey: expandedProjectStorageKey), Set(normalized(stored)))
    }

    public static func saveExpandedProjectIDs(
        _ ids: Set<String>,
        to store: any CodexStringListPreferenceStore
    ) {
        store.saveStrings([persistedMarker] + normalized(Array(ids)).sorted(), forKey: expandedProjectStorageKey)
    }

    private static func normalized(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = CodexProjectSummary.normalizedPath(trimmed)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }
}
