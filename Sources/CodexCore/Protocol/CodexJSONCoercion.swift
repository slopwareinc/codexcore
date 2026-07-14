import Foundation

public extension String {
    /// Returns `nil` when the string is empty. Does not trim.
    var nilIfEmpty: String? { isEmpty ? nil : self }

    /// Returns the trimmed string, or `nil` when it is empty after trimming
    /// whitespace and newlines.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Heuristics over raw app-server status strings.
public enum CodexStatusHeuristics {
    /// True when a raw status string represents an in-flight / streaming item.
    ///
    /// Matches the wire values the app-server emits for active work. This is a
    /// deliberately literal check on the raw values; use
    /// `CodexSubagentState.Status.normalized` for synonym-folding into the
    /// typed status enum.
    public static func isActiveStreaming(_ status: String) -> Bool {
        status == "active" || status == "inProgress" || status == "running"
    }
}

/// Exact adapter for the structured `TurnError` wire value.
public enum CodexTurnErrorAdapter {
    public static func decode(_ value: CodexJSONValue?) -> CodexSchemaTurnError? {
        guard let value else { return nil }
        if case .null = value { return nil }
        return try? value.decode(CodexSchemaTurnError.self)
    }

    public static func message(from value: CodexJSONValue?) -> String? {
        decode(value)?.message.nilIfBlank
    }
}

/// Pure path presentation helpers.
public enum CodexPathFormatter {
    /// Abbreviates the user's home-directory prefix of `path` to `~`.
    ///
    /// - Parameter home: The home directory to match against. Injectable for
    ///   testing; defaults to the current user's home directory.
    public static func abbreviatingHome(
        _ path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// Lenient coercion from dynamically-typed `CodexJSONValue` payloads into
/// concrete Swift values.
///
/// The app-server protocol carries many fields as loosely-typed JSON; this is
/// the canonical place to unwrap them. Coercion variants that need a specific
/// dictionary key precedence pass `dictionaryKeys` explicitly so behavior stays
/// caller-controlled (the various call sites intentionally differ — see the
/// individual sites and issue #87).
public enum CodexJSONCoercion {
    /// Default dictionary key precedence used by `string(from:)`.
    ///
    /// Content-bearing keys are preferred over discriminators: a payload that
    /// carries both `type` and `text` resolves to its `text`, not its type tag.
    public static let defaultStringKeys = ["text", "value", "message", "type", "raw", "id"]

    public static func string(from value: CodexJSONValue?) -> String? {
        string(from: value, dictionaryKeys: defaultStringKeys)
    }

    /// Coerces a value into a display string.
    ///
    /// - Parameters:
    ///   - dictionaryKeys: For `.dictionary` values, the keys tried in order.
    ///   - separator: Join separator for `.array` values.
    ///   - trimScalars: When `true`, empty scalar strings coerce to `nil`.
    public static func string(
        from value: CodexJSONValue?,
        dictionaryKeys: [String],
        separator: String = " ",
        trimScalars: Bool = false
    ) -> String? {
        switch value {
        case .string(let string):
            return trimScalars ? string.nilIfEmpty : string
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .bool(let bool):
            return String(bool)
        case .array(let values):
            return values
                .compactMap {
                    string(from: $0, dictionaryKeys: dictionaryKeys, separator: separator, trimScalars: trimScalars)
                }
                .joined(separator: separator)
                .nilIfBlank
        case .dictionary(let object):
            for key in dictionaryKeys {
                if let resolved = string(
                    from: object[key],
                    dictionaryKeys: dictionaryKeys,
                    separator: separator,
                    trimScalars: trimScalars
                ) {
                    return resolved
                }
            }
            return nil
        case .null, nil:
            return nil
        }
    }

    public static func flatString(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string):
            return string
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .bool(let bool):
            return String(bool)
        case .array, .dictionary, .null, nil:
            return nil
        }
    }

    public static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let string = string(from: object[key])?.nilIfBlank else { continue }
            return string
        }
        return nil
    }

    public static func bool(in object: [String: CodexJSONValue], key: String) -> Bool? {
        bool(from: object[key])
    }

    public static func bool(from value: CodexJSONValue?) -> Bool? {
        switch value {
        case .bool(let bool):
            return bool
        case .string(let string):
            return Bool(string)
        case .int(let int):
            return int != 0
        case .double(let double):
            return double != 0
        case .array, .dictionary, .null, nil:
            return nil
        }
    }

    public static func int(in object: [String: CodexJSONValue], key: String) -> Int? {
        int(from: object[key])
    }

    public static func int(from value: CodexJSONValue?) -> Int? {
        switch value {
        case .int(let int):
            return int
        case .double(let double):
            return Int(double)
        case .string(let string):
            return Int(string)
        case .bool(let bool):
            return bool ? 1 : 0
        case .array, .dictionary, .null, nil:
            return nil
        }
    }

    public static func stringArray(in object: [String: CodexJSONValue], key: String) -> [String] {
        stringArray(from: object[key])
    }

    public static func stringArray(from value: CodexJSONValue?) -> [String] {
        switch value {
        case .array(let values):
            return values.compactMap { string(from: $0)?.nilIfBlank }
        case let value?:
            return string(from: value).map { [$0] } ?? []
        case nil:
            return []
        }
    }

    public static func dictionary(in object: [String: CodexJSONValue], key: String) -> [String: CodexJSONValue]? {
        dictionary(from: object[key])
    }

    public static func dictionary(from value: CodexJSONValue?) -> [String: CodexJSONValue]? {
        guard case .dictionary(let object)? = value else { return nil }
        return object
    }

    public static func dictionaryOrEmpty(from value: CodexJSONValue?) -> [String: CodexJSONValue] {
        dictionary(from: value) ?? [:]
    }
}
