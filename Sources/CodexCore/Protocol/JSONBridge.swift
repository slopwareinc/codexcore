import Foundation

public enum CodexJSONBridgeError: Error, Sendable, CustomStringConvertible {
    case paramsMustBeObject(CodexJSONValue)

    public var description: String {
        switch self {
        case .paramsMustBeObject(let value):
            return "JSON-RPC params must encode to an object, got: \(value)"
        }
    }
}

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

public extension CodexConnection {
    func request<Response: Decodable>(
        method: String,
        response: Response.Type
    ) async throws -> Response {
        let result = try await request(method: method, params: [:])
        return try result.decode(Response.self)
    }

    func request<Params: Encodable, Response: Decodable>(
        method: String,
        params: Params,
        response: Response.Type
    ) async throws -> Response {
        let encoded = try CodexJSONValue(encoding: params)
        guard let object = encoded.objectValue else {
            throw CodexJSONBridgeError.paramsMustBeObject(encoded)
        }
        let result = try await request(method: method, params: object)
        return try result.decode(Response.self)
    }
}
