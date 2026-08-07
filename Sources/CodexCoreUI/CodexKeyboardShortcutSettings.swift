import Foundation
import CodexCore

/// The actions whose global keyboard shortcuts can be changed in Settings.
///
/// These are intentionally limited to shortcuts that the reference app owns
/// directly. AppKit text editing and protocol-specific actions remain native
/// responder behavior rather than becoming pretend preferences here.
public enum CodexKeyboardShortcutAction: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case search
    case newChat
    case toggleSidebar

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .search: return "Search chats and commands"
        case .newChat: return "New chat"
        case .toggleSidebar: return "Toggle sidebar"
        }
    }

    public var detail: String {
        switch self {
        case .search: return "Open the command menu and search past chats"
        case .newChat: return "Start a new chat in the current workspace"
        case .toggleSidebar: return "Show or hide the project sidebar"
        }
    }
}

/// The modifier keys stored for a Codex keyboard shortcut.
public struct CodexKeyboardShortcutModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)

    public var displayPrefix: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

/// A normalized, persistable shortcut independent of AppKit's event types.
public struct CodexKeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    public let key: String
    public let modifiers: CodexKeyboardShortcutModifiers

    public init(key: String, modifiers: CodexKeyboardShortcutModifiers) {
        self.key = Self.normalizedKey(key)
        self.modifiers = modifiers
    }

    public var displayValue: String {
        guard !key.isEmpty else { return "Not set" }
        return modifiers.displayPrefix + key.uppercased()
    }

    public static func command(_ key: String) -> Self {
        Self(key: key, modifiers: .command)
    }

    private static func normalizedKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// User-owned global shortcuts exposed by the reference app.
public struct CodexKeyboardShortcutSettings: Codable, Equatable, Sendable {
    public var search: CodexKeyboardShortcut
    public var newChat: CodexKeyboardShortcut
    public var toggleSidebar: CodexKeyboardShortcut

    public init(
        search: CodexKeyboardShortcut = .command("g"),
        newChat: CodexKeyboardShortcut = .command("n"),
        toggleSidebar: CodexKeyboardShortcut = CodexKeyboardShortcut(
            key: "s",
            modifiers: [.command, .control]
        )
    ) {
        self.search = search
        self.newChat = newChat
        self.toggleSidebar = toggleSidebar
    }

    public static let defaults = Self()

    public subscript(action: CodexKeyboardShortcutAction) -> CodexKeyboardShortcut {
        get {
            switch action {
            case .search: return search
            case .newChat: return newChat
            case .toggleSidebar: return toggleSidebar
            }
        }
        set {
            switch action {
            case .search: search = newValue
            case .newChat: newChat = newValue
            case .toggleSidebar: toggleSidebar = newValue
            }
        }
    }

    public mutating func reset() {
        self = .defaults
    }
}

public enum CodexKeyboardShortcutStorage {
    private static let storageKey = "CodexCoreApp.keyboardShortcutSettings.v1"

    public static func load(
        from store: any CodexStringListPreferenceStore
    ) -> CodexKeyboardShortcutSettings {
        guard let stored = store.loadStrings(forKey: storageKey).first,
              let data = stored.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CodexKeyboardShortcutSettings.self, from: data)
        else {
            return .defaults
        }
        return decoded
    }

    public static func save(
        _ settings: CodexKeyboardShortcutSettings,
        to store: any CodexStringListPreferenceStore
    ) {
        guard let data = try? JSONEncoder().encode(settings),
              let string = String(data: data, encoding: .utf8)
        else {
            return
        }
        store.saveStrings([string], forKey: storageKey)
    }
}
