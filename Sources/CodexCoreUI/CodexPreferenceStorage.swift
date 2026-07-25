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

public enum CodexNewThreadHistoryModeStorage {
    private static let historyModeKey = "CodexCoreApp.newThreadHistoryMode.v1"

    public static func load(
        from store: any CodexStringListPreferenceStore
    ) -> CodexNewThreadHistoryMode {
        guard let rawValue = store.loadStrings(forKey: historyModeKey).first,
              let mode = CodexNewThreadHistoryMode(rawValue: rawValue)
        else { return .defaultForPinnedRelease }
        return mode
    }

    public static func save(
        _ mode: CodexNewThreadHistoryMode,
        to store: any CodexStringListPreferenceStore
    ) {
        store.saveStrings([mode.rawValue], forKey: historyModeKey)
    }
}

public enum CodexSidebarFontSizeStorage {
    public static let defaultFontSize = CodexAgentTheme.Fonts.SidebarTypography.defaultBaseTextSize
    public static let fontSizeRange = CodexAgentTheme.Fonts.SidebarTypography.baseTextSizeRange
    private static let sidebarFontSizeKey = "CodexCoreApp.sidebarFontSize.v3"
    private static let legacySidebarFontSizeKey = "CodexCoreApp.sidebarFontSize.v2"
    private static let legacyFontSizeIncrease: Double = 2

    public static func loadSidebarFontSize(from store: any CodexStringListPreferenceStore) -> Double {
        if let stored = store.loadStrings(forKey: sidebarFontSizeKey).first,
           let value = Double(stored) {
            return clamped(value)
        }

        if let stored = store.loadStrings(forKey: legacySidebarFontSizeKey).first,
           let value = Double(stored) {
            return clamped(value + legacyFontSizeIncrease)
        }

        return defaultFontSize
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

public enum CodexProjectOrderStorage {
    private static let projectOrderStorageKey = "CodexCoreApp.projectOrder.v1"

    public static func loadProjectOrder(
        from store: any CodexStringListPreferenceStore
    ) -> [String] {
        normalized(store.loadStrings(forKey: projectOrderStorageKey))
    }

    public static func saveProjectOrder(
        _ paths: [String],
        to store: any CodexStringListPreferenceStore
    ) {
        store.saveStrings(normalized(paths), forKey: projectOrderStorageKey)
    }

    private static func normalized(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = CodexProjectSummary.normalizedPath(trimmed)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
}

public enum CodexPinnedProjectStorage {
    private static let pinnedProjectStorageKey = "CodexCoreApp.pinnedProjectIDs.v1"

    public static func loadPinnedProjectIDs(
        from store: any CodexStringListPreferenceStore
    ) -> [String] {
        normalized(store.loadStrings(forKey: pinnedProjectStorageKey))
    }

    public static func savePinnedProjectIDs(
        _ paths: [String],
        to store: any CodexStringListPreferenceStore
    ) {
        store.saveStrings(normalized(paths), forKey: pinnedProjectStorageKey)
    }

    private static func normalized(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = CodexProjectSummary.normalizedPath(trimmed)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
}

public enum CodexHiddenProjectStorage {
    private static let hiddenProjectStorageKey = "CodexCoreApp.hiddenProjectIDs.v1"

    public static func loadHiddenProjectIDs(
        from store: any CodexStringListPreferenceStore
    ) -> Set<String> {
        Set(store.loadStrings(forKey: hiddenProjectStorageKey).compactMap(normalizedPath))
    }

    public static func saveHiddenProjectIDs(
        _ paths: Set<String>,
        to store: any CodexStringListPreferenceStore
    ) {
        store.saveStrings(paths.compactMap(normalizedPath).sorted(), forKey: hiddenProjectStorageKey)
    }

    private static func normalizedPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return CodexProjectSummary.normalizedPath(trimmed)
    }
}

public enum CodexProjectAliasStorage {
    private static let projectAliasStorageKey = "CodexCoreApp.projectAliases.v1"

    public static func loadProjectAliases(
        from store: any CodexStringListPreferenceStore
    ) -> [String: String] {
        guard let value = store.loadStrings(forKey: projectAliasStorageKey).first,
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return normalized(decoded)
    }

    public static func saveProjectAliases(
        _ aliases: [String: String],
        to store: any CodexStringListPreferenceStore
    ) {
        guard let data = try? JSONEncoder().encode(normalized(aliases)),
              let value = String(data: data, encoding: .utf8)
        else { return }
        store.saveStrings([value], forKey: projectAliasStorageKey)
    }

    private static func normalized(_ aliases: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: aliases.compactMap { path, alias in
            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty, !trimmedAlias.isEmpty else { return nil }
            return (CodexProjectSummary.normalizedPath(trimmedPath), trimmedAlias)
        })
    }
}

/// Ordered source folders for local projects. The dictionary key is the
/// project's primary folder and the first value is always the primary folder.
/// Projects without an entry retain the legacy single-folder behavior.
public enum CodexProjectSourceFoldersStorage {
    private static let storageKey = "CodexCoreApp.projectSourceFolders.v1"

    public static func load(
        from store: any CodexStringListPreferenceStore
    ) -> [String: [String]] {
        guard let value = store.loadStrings(forKey: storageKey).first,
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return normalized(decoded)
    }

    public static func save(
        _ projects: [String: [String]],
        to store: any CodexStringListPreferenceStore
    ) {
        guard let data = try? JSONEncoder().encode(normalized(projects)),
              let value = String(data: data, encoding: .utf8)
        else { return }
        store.saveStrings([value], forKey: storageKey)
    }

    public static func updating(
        _ projects: [String: [String]],
        oldPrimary: String,
        sourceFolders: [String]
    ) -> [String: [String]] {
        var result = projects
        result.removeValue(forKey: CodexProjectSummary.normalizedPath(oldPrimary))
        let roots = CodexProjectSummary.normalizedSourceFolders(sourceFolders)
        guard let newPrimary = roots.first else { return result }
        result[newPrimary] = roots
        return normalized(result)
    }

    private static func normalized(_ projects: [String: [String]]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (key, value) in projects {
            let primary = CodexProjectSummary.normalizedPath(key)
            let roots = CodexProjectSummary.normalizedSourceFolders(value, primary: primary)
            guard !roots.isEmpty else { continue }
            result[primary] = roots
        }
        return result
    }
}

public enum CodexProjectlessThreadStorage {
    public static let key = "CodexCoreApp.projectlessThreadIDs.v1"

    public static func load(from store: any CodexStringListPreferenceStore) -> Set<String> {
        Set(store.loadStrings(forKey: key).filter { !$0.isEmpty })
    }

    public static func save(
        _ threadIDs: Set<String>,
        to store: any CodexStringListPreferenceStore
    ) {
        store.saveStrings(threadIDs.sorted(), forKey: key)
    }
}

public enum CodexModelPreferenceStorage {
    private static let lastModelKey = "CodexCoreApp.lastManualModel.v1"
    private static let threadModelsKey = "CodexCoreApp.threadModels.v1"

    public static func loadLastModelID(from store: any CodexStringListPreferenceStore) -> String? {
        store.loadStrings(forKey: lastModelKey).first
    }

    public static func saveLastModelID(_ id: String, to store: any CodexStringListPreferenceStore) {
        store.saveStrings([id], forKey: lastModelKey)
    }

    public static func loadThreadModelIDs(from store: any CodexStringListPreferenceStore) -> [String: String] {
        guard let value = store.loadStrings(forKey: threadModelsKey).first,
              let data = value.data(using: .utf8),
              let result = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return result
    }

    public static func saveThreadModelIDs(_ ids: [String: String], to store: any CodexStringListPreferenceStore) {
        guard let data = try? JSONEncoder().encode(ids),
              let value = String(data: data, encoding: .utf8)
        else { return }
        store.saveStrings([value], forKey: threadModelsKey)
    }
}
