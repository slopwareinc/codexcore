import Foundation

public extension CodexJSONValue {
    init<T: Encodable>(encoding value: T, encoder: JSONEncoder = JSONEncoder()) throws {
        let data = try encoder.encode(value)
        self = try JSONDecoder().decode(CodexJSONValue.self, from: data)
    }

    func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(type, from: data)
    }

    var objectValue: [String: CodexJSONValue]? {
        guard case .dictionary(let object) = self else { return nil }
        return object
    }
}

public extension Dictionary where Key == String, Value == CodexJSONValue {
    func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try CodexJSONValue.dictionary(self).decode(type, decoder: decoder)
    }
}
