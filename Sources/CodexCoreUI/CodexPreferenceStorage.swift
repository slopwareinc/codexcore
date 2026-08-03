import CodexCore
import Foundation
import OSLog

public enum CodexPreferenceStorageError: Error, Equatable, Sendable, LocalizedError {
    case invalidUTF8(key: String)
    case decodingFailed(key: String, reason: String)
    case encodingFailed(key: String, reason: String)
    case writeVerificationFailed(key: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidUTF8(key):
            return "The stored preference for \(key) is not valid UTF-8."
        case let .decodingFailed(key, reason):
            return "The stored preference for \(key) could not be decoded: \(reason)"
        case let .encodingFailed(key, reason):
            return "The preference for \(key) could not be encoded: \(reason)"
        case let .writeVerificationFailed(key):
            return "The preference write for \(key) could not be verified."
        }
    }
}

public typealias CodexPreferenceFailureHandler = (CodexPreferenceStorageError) -> Void

private let codexPreferenceStorageLogger = Logger(
    subsystem: "com.slopware.codexcore",
    category: "preferences"
)

private struct CodexStoredJSON<Value> {
    let value: Value
    let sourceKey: String
}

private enum CodexPreferenceStorageCodec {
    static func decode<Value: Decodable>(
        _ type: Value.Type,
        currentKey: String,
        legacyKeys: [String],
        from store: any CodexStringListPreferenceStore,
        onFailure: CodexPreferenceFailureHandler?
    ) -> CodexStoredJSON<Value>? {
        var keys: [String] = []
        for key in [currentKey] + legacyKeys where !keys.contains(key) {
            keys.append(key)
        }

        for key in keys {
            guard let stored = store.loadStrings(forKey: key).first else { continue }
            guard let data = stored.data(using: .utf8) else {
                report(.invalidUTF8(key: key), to: onFailure)
                continue
            }
            do {
                let value = try JSONDecoder().decode(type, from: data)
                return CodexStoredJSON(value: value, sourceKey: key)
            } catch {
                report(
                    .decodingFailed(key: key, reason: error.localizedDescription),
                    to: onFailure
                )
            }
        }
        return nil
    }

    @discardableResult
    static func encodeAndSave<Value: Encodable>(
        _ value: Value,
        forKey key: String,
        to store: any CodexStringListPreferenceStore,
        onFailure: CodexPreferenceFailureHandler?
    ) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            guard let string = String(data: data, encoding: .utf8) else {
                report(
                    .encodingFailed(key: key, reason: "The encoded bytes were not UTF-8."),
                    to: onFailure
                )
                return false
            }
            return saveRaw(string, forKey: key, to: store, onFailure: onFailure)
        } catch {
            report(
                .encodingFailed(key: key, reason: error.localizedDescription),
                to: onFailure
            )
            return false
        }
    }

    @discardableResult
    static func saveRaw(
        _ string: String,
        forKey key: String,
        to store: any CodexStringListPreferenceStore,
        onFailure: CodexPreferenceFailureHandler?
    ) -> Bool {
        store.saveStrings([string], forKey: key)
        guard store.loadStrings(forKey: key) == [string] else {
            report(.writeVerificationFailed(key: key), to: onFailure)
            return false
        }
        return true
    }

    @discardableResult
    static func saveStrings(
        _ strings: [String],
        forKey key: String,
        to store: any CodexStringListPreferenceStore,
        onFailure: CodexPreferenceFailureHandler? = nil
    ) -> Bool {
        store.saveStrings(strings, forKey: key)
        guard store.loadStrings(forKey: key) == strings else {
            report(.writeVerificationFailed(key: key), to: onFailure)
            return false
        }
        return true
    }

    static func loadStrings(
        currentKey: String,
        legacyKeys: [String],
        from store: any CodexStringListPreferenceStore,
        onFailure: CodexPreferenceFailureHandler? = nil
    ) -> [String] {
        var keys: [String] = []
        for key in [currentKey] + legacyKeys where !keys.contains(key) {
            keys.append(key)
        }

        for key in keys {
            let values = store.loadStrings(forKey: key)
            guard !values.isEmpty else { continue }
            if key != currentKey {
                _ = saveStrings(values, forKey: currentKey, to: store, onFailure: onFailure)
            }
            return values
        }
        return []
    }

    private static func report(
        _ error: CodexPreferenceStorageError,
        to onFailure: CodexPreferenceFailureHandler?
    ) {
        codexPreferenceStorageLogger.error("\(error.localizedDescription, privacy: .public)")
        onFailure?(error)
    }
}

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

public enum CodexSelectedThreadStorage {
    public static let key = "CodexCoreApp.selectedThreadID.v1"

    public static func loadSelectedThreadID(
        from store: any CodexStringListPreferenceStore
    ) -> String? {
        store.loadStrings(forKey: key).first?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    @discardableResult
    public static func saveSelectedThreadID(
        _ threadID: String?,
        to store: any CodexStringListPreferenceStore
    ) -> Bool {
        let value = threadID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        return CodexPreferenceStorageCodec.saveStrings(
            value.map { [$0] } ?? [],
            forKey: key,
            to: store
        )
    }
}

public enum CodexUnreadThreadStorage {
    public static let key = "CodexCoreApp.unreadAgentMessageThreadIDs.v2"
    public static let legacyKey = "CodexCoreApp.unreadAgentMessageThreadIDs.v1"
    private static let legacyKeys = [
        legacyKey,
        "CodexCoreApp.unreadAgentMessageThreadIDs"
    ]

    public static func loadUnreadThreadIDs(
        from store: any CodexStringListPreferenceStore,
        onFailure: CodexPreferenceFailureHandler? = nil
    ) -> Set<ThreadID> {
        let hasCurrentValue = !store.loadStrings(forKey: key).isEmpty
        let normalizedIDs = normalized(
            CodexPreferenceStorageCodec.loadStrings(
                currentKey: key,
                legacyKeys: legacyKeys,
                from: store,
                onFailure: onFailure
            )
        )
        if !hasCurrentValue, !normalizedIDs.isEmpty {
            _ = CodexPreferenceStorageCodec.saveStrings(
                normalizedIDs.sorted(),
                forKey: key,
                to: store,
                onFailure: onFailure
            )
        }
        return Set(normalizedIDs.map { ThreadID($0) })
    }

    @discardableResult
    public static func saveUnreadThreadIDs(
        _ ids: Set<ThreadID>,
        to store: any CodexStringListPreferenceStore,
        onFailure: CodexPreferenceFailureHandler? = nil
    ) -> Bool {
        CodexPreferenceStorageCodec.saveStrings(
            normalized(ids.map(\.rawValue)).sorted(),
            forKey: key,
            to: store,
            onFailure: onFailure
        )
    }

    private static func normalized(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.compactMap { id in
            let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
}

public enum CodexAppearanceSettingsStorage {
    public static let key = "CodexCoreApp.appearanceSettings.v2"
    public static let legacyKey = "CodexCoreApp.appearanceSettings.v1"
    private static let legacyKeys = [
        legacyKey,
        "CodexCoreApp.appearanceSettings"
    ]

    public static func loadAppearanceSettings(
        from store: any CodexStringListPreferenceStore,
        onFailure: CodexPreferenceFailureHandler? = nil
    ) -> CodexAppearanceSettings {
        guard let stored = CodexPreferenceStorageCodec.decode(
            CodexAppearanceSettingsPayload.self,
            currentKey: key,
            legacyKeys: legacyKeys,
            from: store,
            onFailure: onFailure
        ) else {
            return .official
        }
        if stored.sourceKey != key {
            _ = saveAppearanceSettings(stored.value.settings, to: store, onFailure: onFailure)
        }
        return stored.value.settings
    }

    @discardableResult
    public static func saveAppearanceSettings(
        _ settings: CodexAppearanceSettings,
        to store: any CodexStringListPreferenceStore,
        onFailure: CodexPreferenceFailureHandler? = nil
    ) -> Bool {
        CodexPreferenceStorageCodec.encodeAndSave(
            settings,
            forKey: key,
            to: store,
            onFailure: onFailure
        )
    }
}

public enum CodexGitSettingsStorage {
    public static let key = "CodexCoreApp.gitSettings.v1"
    public static let legacyKey = "CodexCoreApp.gitSettings"
    private static let legacyKeys = [legacyKey, "CodexCoreApp.gitSettings.v0"]

    public static func loadGitSettings(
        from store: any CodexStringListPreferenceStore,
        onFailure: CodexPreferenceFailureHandler? = nil
    ) -> CodexGitSettings {
        guard let stored = CodexPreferenceStorageCodec.decode(
            CodexGitSettingsPayload.self,
            currentKey: key,
            legacyKeys: legacyKeys,
            from: store,
            onFailure: onFailure
        ) else {
            return .defaults
        }
        if stored.sourceKey != key {
            _ = saveGitSettings(stored.value.settings, to: store, onFailure: onFailure)
        }
        return stored.value.settings
    }

    @discardableResult
    public static func saveGitSettings(
        _ settings: CodexGitSettings,
        to store: any CodexStringListPreferenceStore,
        onFailure: CodexPreferenceFailureHandler? = nil
    ) -> Bool {
        CodexPreferenceStorageCodec.encodeAndSave(
            settings,
            forKey: key,
            to: store,
            onFailure: onFailure
        )
    }
}

private struct CodexAppearanceSettingsPayload: Decodable {
    let settings: CodexAppearanceSettings

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let appearanceMode = codexDecodeOptional(
            CodexAppearanceMode.self,
            from: container,
            forKey: .appearanceMode
        ) ?? codexDecodeOptional(
            CodexAppearanceMode.self,
            from: container,
            forKey: .mode
        )
        let preset = codexDecodeOptional(
            CodexAgentThemePreset.self,
            from: container,
            forKey: .preset
        ) ?? (appearanceMode == .light ? .nativeLight : .officialDark)
        let reduceMotion = codexDecodeIfPresent(
            Bool.self,
            from: container,
            forKey: .reduceMotion,
            default: false
        )
        let uiFontSize = codexDecodeIfPresent(
            Double.self,
            from: container,
            forKey: .uiFontSize,
            default: 14
        )
        let diffMarkerStyle = codexDecodeIfPresent(
            CodexDiffMarkerStyle.self,
            from: container,
            forKey: .diffMarkerStyle,
            default: .color
        )
        let dockIconVariant = codexDecodeIfPresent(
            CodexDockIconVariant.self,
            from: container,
            forKey: .dockIconVariant,
            default: .default
        )
        let textFontFamily = codexDecodeOptional(
            String.self,
            from: container,
            forKey: .textFontFamily
        )
        let monoFontFamily = codexDecodeOptional(
            String.self,
            from: container,
            forKey: .monoFontFamily
        )
        settings = CodexAppearanceSettings(
            preset: preset,
            appearanceMode: appearanceMode,
            reduceMotion: reduceMotion,
            uiFontSize: uiFontSize,
            diffMarkerStyle: diffMarkerStyle,
            dockIconVariant: dockIconVariant,
            textFontFamily: textFontFamily,
            monoFontFamily: monoFontFamily
        )
    }

    private enum CodingKeys: String, CodingKey {
        case preset
        case appearanceMode
        case mode
        case reduceMotion
        case uiFontSize
        case diffMarkerStyle
        case dockIconVariant
        case textFontFamily
        case monoFontFamily
    }
}

private struct CodexGitSettingsPayload: Decodable {
    let settings: CodexGitSettings

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CodexGitSettings.defaults
        let branchPrefix = codexDecodeIfPresent(
            String.self,
            from: container,
            forKey: .branchPrefix,
            default: defaults.branchPrefix
        )
        let mergeMethod = codexDecodeIfPresent(
            CodexSettingsMergeMethod.self,
            from: container,
            forKey: .mergeMethod,
            default: defaults.mergeMethod
        )
        let createsDraftPullRequests = codexDecodeIfPresent(
            Bool.self,
            from: container,
            forKey: .createsDraftPullRequests,
            default: codexDecodeIfPresent(
                Bool.self,
                from: container,
                forKey: .createDraftPullRequests,
                default: defaults.createsDraftPullRequests
            )
        )
        let alwaysForcePush = codexDecodeIfPresent(
            Bool.self,
            from: container,
            forKey: .alwaysForcePush,
            default: defaults.alwaysForcePush
        )
        let commitInstructions = codexDecodeIfPresent(
            String.self,
            from: container,
            forKey: .commitInstructions,
            default: defaults.commitInstructions
        )
        let pullRequestInstructions = codexDecodeIfPresent(
            String.self,
            from: container,
            forKey: .pullRequestInstructions,
            default: defaults.pullRequestInstructions
        )
        settings = CodexGitSettings(
            branchPrefix: branchPrefix,
            mergeMethod: mergeMethod,
            createsDraftPullRequests: createsDraftPullRequests,
            alwaysForcePush: alwaysForcePush,
            commitInstructions: commitInstructions,
            pullRequestInstructions: pullRequestInstructions
        )
    }

    private enum CodingKeys: String, CodingKey {
        case branchPrefix
        case mergeMethod
        case createsDraftPullRequests
        case createDraftPullRequests
        case alwaysForcePush
        case commitInstructions
        case pullRequestInstructions
    }
}

private func codexDecodeIfPresent<Value: Decodable, Key: CodingKey>(
    _ type: Value.Type,
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key,
    default defaultValue: Value
) -> Value {
    do {
        return try container.decodeIfPresent(type, forKey: key) ?? defaultValue
    } catch {
        return defaultValue
    }
}

private func codexDecodeOptional<Value: Decodable, Key: CodingKey>(
    _ type: Value.Type,
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key
) -> Value? {
    do {
        return try container.decodeIfPresent(type, forKey: key)
    } catch {
        return nil
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
        guard let decoded = CodexPreferenceStorageCodec.decode(
            [String: String].self,
            currentKey: projectAliasStorageKey,
            legacyKeys: [],
            from: store,
            onFailure: nil
        ) else { return [:] }
        return normalized(decoded.value)
    }

    public static func saveProjectAliases(
        _ aliases: [String: String],
        to store: any CodexStringListPreferenceStore
    ) {
        _ = CodexPreferenceStorageCodec.encodeAndSave(
            normalized(aliases),
            forKey: projectAliasStorageKey,
            to: store,
            onFailure: nil
        )
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
        guard let decoded = CodexPreferenceStorageCodec.decode(
            [String: [String]].self,
            currentKey: storageKey,
            legacyKeys: [],
            from: store,
            onFailure: nil
        ) else { return [:] }
        return normalized(decoded.value)
    }

    public static func save(
        _ projects: [String: [String]],
        to store: any CodexStringListPreferenceStore
    ) {
        _ = CodexPreferenceStorageCodec.encodeAndSave(
            normalized(projects),
            forKey: storageKey,
            to: store,
            onFailure: nil
        )
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

package struct CodexModelPreference: Codable, Equatable, Sendable {
    package static let legacyFastTierID = "fast"
    package static let standardTierID = "standard"

    package var modelID: String?
    package var serviceTierID: String?
    package var isServiceTierExplicit: Bool
    package var isAuthoritativeModelID: Bool

    package init(
        modelID: String?,
        serviceTierID: String?,
        isServiceTierExplicit: Bool,
        isAuthoritativeModelID: Bool = false
    ) {
        self.modelID = modelID
        self.serviceTierID = serviceTierID
        self.isServiceTierExplicit = isServiceTierExplicit
        self.isAuthoritativeModelID = isAuthoritativeModelID
    }

    package init(
        model: CodexModelSelection,
        serviceTier: CodexServiceTierSelection,
        isServiceTierExplicit: Bool,
        isAuthoritativeModelID: Bool = false
    ) {
        self.init(
            modelID: model.id,
            serviceTierID: serviceTier.protocolValue ?? Self.standardTierID,
            isServiceTierExplicit: isServiceTierExplicit,
            isAuthoritativeModelID: isAuthoritativeModelID
        )
    }

    package static func migratingLegacyModelID(_ id: String) -> Self {
        if id.caseInsensitiveCompare("speed") == .orderedSame {
            return Self(
                modelID: nil,
                serviceTierID: legacyFastTierID,
                isServiceTierExplicit: true
            )
        }
        if id.lowercased().hasSuffix("-speed") {
            return Self(
                modelID: String(id.dropLast("-speed".count)),
                serviceTierID: legacyFastTierID,
                isServiceTierExplicit: true
            )
        }
        return Self(
            modelID: id,
            serviceTierID: nil,
            isServiceTierExplicit: false
        )
    }
}

public enum CodexModelPreferenceStorage {
    private static let lastModelKey = "CodexCoreApp.lastManualModel.v1"
    private static let threadModelsKey = "CodexCoreApp.threadModels.v1"
    private static let lastSelectionKey = "CodexCoreApp.lastManualModel.v2"
    private static let threadSelectionsKey = "CodexCoreApp.threadModels.v2"

    package static func loadLastSelection(
        from store: any CodexStringListPreferenceStore
    ) -> CodexModelPreference? {
        if let selection: CodexModelPreference = decode(lastSelectionKey, from: store) {
            return selection
        }
        return loadLastModelID(from: store).map(CodexModelPreference.migratingLegacyModelID)
    }

    package static func saveLastSelection(
        _ selection: CodexModelPreference,
        to store: any CodexStringListPreferenceStore
    ) {
        encode(selection, forKey: lastSelectionKey, to: store)
    }

    package static func loadThreadSelections(
        from store: any CodexStringListPreferenceStore
    ) -> [String: CodexModelPreference] {
        if let selections: [String: CodexModelPreference] = decode(
            threadSelectionsKey,
            from: store
        ) {
            return selections
        }
        return loadThreadModelIDs(from: store).mapValues(
            CodexModelPreference.migratingLegacyModelID
        )
    }

    package static func saveThreadSelections(
        _ selections: [String: CodexModelPreference],
        to store: any CodexStringListPreferenceStore
    ) {
        encode(selections, forKey: threadSelectionsKey, to: store)
    }

    public static func loadLastModelID(from store: any CodexStringListPreferenceStore) -> String? {
        store.loadStrings(forKey: lastModelKey).first
    }

    public static func saveLastModelID(_ id: String, to store: any CodexStringListPreferenceStore) {
        store.saveStrings([id], forKey: lastModelKey)
    }

    public static func loadThreadModelIDs(from store: any CodexStringListPreferenceStore) -> [String: String] {
        guard let decoded = CodexPreferenceStorageCodec.decode(
            [String: String].self,
            currentKey: threadModelsKey,
            legacyKeys: [],
            from: store,
            onFailure: nil
        ) else { return [:] }
        return decoded.value
    }

    public static func saveThreadModelIDs(_ ids: [String: String], to store: any CodexStringListPreferenceStore) {
        _ = CodexPreferenceStorageCodec.encodeAndSave(
            ids,
            forKey: threadModelsKey,
            to: store,
            onFailure: nil
        )
    }

    private static func decode<Value: Decodable>(
        _ key: String,
        from store: any CodexStringListPreferenceStore
    ) -> Value? {
        CodexPreferenceStorageCodec.decode(
            Value.self,
            currentKey: key,
            legacyKeys: [],
            from: store,
            onFailure: nil
        )?.value
    }

    private static func encode<Value: Encodable>(
        _ value: Value,
        forKey key: String,
        to store: any CodexStringListPreferenceStore
    ) {
        _ = CodexPreferenceStorageCodec.encodeAndSave(
            value,
            forKey: key,
            to: store,
            onFailure: nil
        )
    }
}
