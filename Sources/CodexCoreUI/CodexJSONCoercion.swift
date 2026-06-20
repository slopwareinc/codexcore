import CodexCore

enum CodexJSONCoercion {
    static func flatString(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .array, .dictionary, .null, nil: return nil
        }
    }

    static func bool(in object: [String: CodexJSONValue], key: String) -> Bool? {
        switch object[key] {
        case .bool(let bool): return bool
        case .string(let string): return Bool(string)
        case .int(let int): return int != 0
        case .double(let double): return double != 0
        case .array, .dictionary, .null, nil: return nil
        }
    }
}
