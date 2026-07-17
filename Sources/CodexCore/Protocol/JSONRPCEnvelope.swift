import Foundation

/// Exact JSON-RPC identity shared by client responses and server requests.
/// Integer `7` and string `"7"` are intentionally different values.
public typealias CodexJSONRPCID = CodexServerRequestID

/// Monotonic position of a frame within one physical transport connection.
/// Cursors are diagnostic/order coordinates, not durable app-server resume cursors.
public struct CodexWireCursor: Sendable, Hashable, Codable, Comparable {
    public let connectionEpoch: UInt64
    public let ordinal: UInt64

    public init(connectionEpoch: UInt64, ordinal: UInt64) {
        self.connectionEpoch = connectionEpoch
        self.ordinal = ordinal
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.connectionEpoch != rhs.connectionEpoch {
            return lhs.connectionEpoch < rhs.connectionEpoch
        }
        return lhs.ordinal < rhs.ordinal
    }
}

public struct CodexJSONRPCErrorObject: Error, Sendable, Equatable, Codable,
    LocalizedError
{
    public let code: Int
    public let message: String
    public let data: CodexJSONValue?

    public init(code: Int, message: String, data: CodexJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? {
        "JSON-RPC error \(code): \(message)"
    }
}

public enum CodexJSONRPCResponseOutcome: Sendable, Equatable {
    case result(CodexJSONValue)
    case error(CodexJSONRPCErrorObject)
}

public struct CodexJSONRPCResponseEnvelope: Sendable, Equatable {
    public let id: CodexJSONRPCID
    public let outcome: CodexJSONRPCResponseOutcome

    public init(id: CodexJSONRPCID, outcome: CodexJSONRPCResponseOutcome) {
        self.id = id
        self.outcome = outcome
    }
}

public struct CodexJSONRPCNotificationEnvelope: Sendable, Equatable {
    public let method: String
    public let params: [String: CodexJSONValue]

    public init(method: String, params: [String: CodexJSONValue] = [:]) {
        self.method = method
        self.params = params
    }
}

public struct CodexJSONRPCServerRequestEnvelope: Sendable, Equatable {
    public let id: CodexJSONRPCID
    public let method: String
    public let params: [String: CodexJSONValue]

    public init(
        id: CodexJSONRPCID,
        method: String,
        params: [String: CodexJSONValue] = [:]
    ) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// A validated, single-frame JSON-RPC message from app-server.
public enum CodexJSONRPCEnvelope: Sendable, Equatable {
    case response(CodexJSONRPCResponseEnvelope)
    case notification(CodexJSONRPCNotificationEnvelope)
    case serverRequest(CodexJSONRPCServerRequestEnvelope)
}

public enum CodexJSONRPCEnvelopeError: Error, Sendable, Equatable, LocalizedError {
    case invalidJSON(String)
    case topLevelMustBeObject
    case invalidVersion(CodexJSONValue?)
    case invalidMethod(CodexJSONValue?)
    case invalidIdentifier(CodexJSONValue?)
    case paramsMustBeObject(CodexJSONValue)
    case responseMustContainExactlyOneOutcome
    case errorMustBeObject(CodexJSONValue)
    case invalidErrorCode(CodexJSONValue?)
    case invalidErrorMessage(CodexJSONValue?)
    case mixedMessageShape

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let message):
            "Invalid JSON-RPC JSON: \(message)"
        case .topLevelMustBeObject:
            "A JSON-RPC frame must contain one top-level object."
        case .invalidVersion:
            "A JSON-RPC frame must declare jsonrpc \"2.0\"."
        case .invalidMethod:
            "A JSON-RPC request or notification must contain a string method."
        case .invalidIdentifier:
            "A JSON-RPC id must be a non-null integer or string."
        case .paramsMustBeObject:
            "App-server JSON-RPC params must be an object when present."
        case .responseMustContainExactlyOneOutcome:
            "A JSON-RPC response must contain exactly one of result or error."
        case .errorMustBeObject:
            "A JSON-RPC error member must be an object."
        case .invalidErrorCode:
            "A JSON-RPC error object must contain an integer code."
        case .invalidErrorMessage:
            "A JSON-RPC error object must contain a string message."
        case .mixedMessageShape:
            "A JSON-RPC frame mixes request and response members."
        }
    }
}

/// One-pass JSON-RPC frame codec. It preserves wire identity and validates the
/// envelope before protocol-specific decoding begins.
public enum CodexJSONRPCCodec {
    public static func decode(_ frame: Data) throws -> CodexJSONRPCEnvelope {
        let value: CodexJSONValue
        do {
            value = try JSONDecoder().decode(CodexJSONValue.self, from: frame)
        } catch {
            throw CodexJSONRPCEnvelopeError.invalidJSON(String(describing: error))
        }

        guard case .dictionary(let object) = value else {
            throw CodexJSONRPCEnvelopeError.topLevelMustBeObject
        }
        guard object["jsonrpc"] == .string("2.0") else {
            throw CodexJSONRPCEnvelopeError.invalidVersion(object["jsonrpc"])
        }

        if let rawMethod = object["method"] {
            guard case .string(let method) = rawMethod, !method.isEmpty else {
                throw CodexJSONRPCEnvelopeError.invalidMethod(rawMethod)
            }
            guard object["result"] == nil, object["error"] == nil else {
                throw CodexJSONRPCEnvelopeError.mixedMessageShape
            }
            let params = try decodeParams(object["params"])

            if let rawID = object["id"] {
                return .serverRequest(.init(
                    id: try decodeID(rawID),
                    method: method,
                    params: params
                ))
            }
            return .notification(.init(method: method, params: params))
        }

        guard object["params"] == nil else {
            throw CodexJSONRPCEnvelopeError.mixedMessageShape
        }
        let id = try decodeID(object["id"])
        let hasResult = object.keys.contains("result")
        let hasError = object.keys.contains("error")
        guard hasResult != hasError else {
            throw CodexJSONRPCEnvelopeError.responseMustContainExactlyOneOutcome
        }

        if hasResult {
            return .response(.init(id: id, outcome: .result(object["result"] ?? .null)))
        }
        guard let rawError = object["error"] else {
            throw CodexJSONRPCEnvelopeError.responseMustContainExactlyOneOutcome
        }
        return .response(.init(id: id, outcome: .error(try decodeError(rawError))))
    }

    public static func encodeRequest(
        id: CodexJSONRPCID,
        method: String,
        params: CodexJSONValue?
    ) throws -> Data {
        var object: [String: CodexJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "method": .string(method),
        ]
        if let params {
            object["params"] = params
        }
        return try encodeObject(object)
    }

    public static func encodeRequest(
        id: CodexJSONRPCID,
        method: String,
        objectParams: [String: CodexJSONValue]
    ) throws -> Data {
        try encodeRequest(id: id, method: method, params: .dictionary(objectParams))
    }

    public static func encodeNotification(
        method: String,
        params: CodexJSONValue?
    ) throws -> Data {
        var object: [String: CodexJSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params {
            object["params"] = params
        }
        return try encodeObject(object)
    }

    public static func encodeNotification(
        method: String,
        objectParams: [String: CodexJSONValue]
    ) throws -> Data {
        try encodeNotification(
            method: method,
            params: .dictionary(objectParams)
        )
    }

    public static func encodeNotification(method: String) throws -> Data {
        try encodeNotification(method: method, params: nil)
    }

    public static func encodeResult(
        id: CodexJSONRPCID,
        result: CodexJSONValue
    ) throws -> Data {
        try encodeObject([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "result": result,
        ])
    }

    public static func encodeError(
        id: CodexJSONRPCID,
        error: CodexJSONRPCErrorObject
    ) throws -> Data {
        var errorObject: [String: CodexJSONValue] = [
            "code": .int(error.code),
            "message": .string(error.message),
        ]
        if let data = error.data {
            errorObject["data"] = data
        }
        return try encodeObject([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "error": .dictionary(errorObject),
        ])
    }

    private static func decodeID(_ raw: CodexJSONValue?) throws -> CodexJSONRPCID {
        guard let raw else {
            throw CodexJSONRPCEnvelopeError.invalidIdentifier(nil)
        }
        do {
            return try CodexJSONRPCID(jsonValue: raw)
        } catch {
            throw CodexJSONRPCEnvelopeError.invalidIdentifier(raw)
        }
    }

    private static func decodeParams(
        _ raw: CodexJSONValue?
    ) throws -> [String: CodexJSONValue] {
        switch raw {
        case nil, .null?:
            return [:]
        case .dictionary(let params)?:
            return params
        case .some(let value):
            throw CodexJSONRPCEnvelopeError.paramsMustBeObject(value)
        }
    }

    private static func decodeError(
        _ raw: CodexJSONValue
    ) throws -> CodexJSONRPCErrorObject {
        guard case .dictionary(let object) = raw else {
            throw CodexJSONRPCEnvelopeError.errorMustBeObject(raw)
        }
        guard case .int(let code)? = object["code"] else {
            throw CodexJSONRPCEnvelopeError.invalidErrorCode(object["code"])
        }
        guard case .string(let message)? = object["message"] else {
            throw CodexJSONRPCEnvelopeError.invalidErrorMessage(object["message"])
        }
        return .init(code: code, message: message, data: object["data"])
    }

    private static func encodeObject(
        _ object: [String: CodexJSONValue]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(object)
    }
}
