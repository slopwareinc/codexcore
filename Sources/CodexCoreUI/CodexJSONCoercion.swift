import CodexCore

enum CodexJSONCoercion {
    static func string(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string):
            return string
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .bool(let bool):
            return String(bool)
        case .array(let values):
            return values.compactMap(string(from:)).joined(separator: " ").nilIfBlank
        case .dictionary(let object):
            return string(from: object["text"])
                ?? string(from: object["value"])
                ?? string(from: object["message"])
                ?? string(from: object["type"])
                ?? string(from: object["raw"])
        case .null, nil:
            return nil
        }
    }

    static func flatString(from value: CodexJSONValue?) -> String? {
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

    static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let string = string(from: object[key])?.nilIfBlank else { continue }
            return string
        }
        return nil
    }

    static func bool(in object: [String: CodexJSONValue], key: String) -> Bool? {
        bool(from: object[key])
    }

    static func bool(from value: CodexJSONValue?) -> Bool? {
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

    static func int(in object: [String: CodexJSONValue], key: String) -> Int? {
        int(from: object[key])
    }

    static func int(from value: CodexJSONValue?) -> Int? {
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

    static func stringArray(in object: [String: CodexJSONValue], key: String) -> [String] {
        stringArray(from: object[key])
    }

    static func stringArray(from value: CodexJSONValue?) -> [String] {
        switch value {
        case .array(let values):
            return values.compactMap { string(from: $0)?.nilIfBlank }
        case let value?:
            return string(from: value).map { [$0] } ?? []
        case nil:
            return []
        }
    }

    static func dictionary(in object: [String: CodexJSONValue], key: String) -> [String: CodexJSONValue]? {
        dictionary(from: object[key])
    }

    static func dictionary(from value: CodexJSONValue?) -> [String: CodexJSONValue]? {
        guard case .dictionary(let object)? = value else { return nil }
        return object
    }

    static func dictionaryOrEmpty(from value: CodexJSONValue?) -> [String: CodexJSONValue] {
        dictionary(from: value) ?? [:]
    }
}

extension CodexSubagentState.Status {
    init(normalizing rawStatus: String?, default fallback: Self = .running) {
        self = Self.normalized(rawStatus) ?? fallback
    }

    static func normalized(_ rawStatus: String?) -> Self? {
        switch rawStatus?
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        {
        case "running", "active", "inprogress", "in_progress":
            return .running
        case "completed", "complete", "done", "success", "succeeded":
            return .completed
        case "closed", "cancelled", "canceled", "skipped":
            return .closed
        case "failed", "failure", "error":
            return .failed
        default:
            return nil
        }
    }
}

extension CodexNotificationPayload {
    var normalizedKnownPayload: (method: CodexAppServerNotificationMethod, params: [String: CodexJSONValue])? {
        switch self {
        case .known(let method, let params):
            return (method, params)
        case .unknown(let rawMethod, let params):
            guard let method = CodexAppServerNotificationMethod(rawValue: rawMethod) else { return nil }
            return (method, params)
        default:
            return nil
        }
    }
}
