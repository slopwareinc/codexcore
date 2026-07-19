import Foundation

/// Lossless JSON value used at the alpha app-server protocol boundary.
public enum CodexJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([CodexJSONValue])
    case dictionary([String: CodexJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(
            [String: CodexJSONValue].self
        ) {
            self = .dictionary(value)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .dictionary(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var rawValue: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .double(let value): value
        case .bool(let value): value
        case .array(let value): value.map(\.rawValue)
        case .dictionary(let value): value.mapValues(\.rawValue)
        case .null: NSNull()
        }
    }
}

extension CodexJSONValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): String(value)
        case .array(let value):
            "[" + value.map(\.description).joined(separator: ", ") + "]"
        case .dictionary(let value):
            "{" + value.map { "\"\($0.key)\": \($0.value.description)" }
                .joined(separator: ", ") + "}"
        case .null: "null"
        }
    }
}

/// One structured action included with a command-approval server request.
public struct CodexCommandAction: Codable, Sendable, Equatable {
    public let type: String
    public let command: String
    public let name: String?
    public let path: String?
    public let query: String?

    public init(
        type: String,
        command: String,
        name: String? = nil,
        path: String? = nil,
        query: String? = nil
    ) {
        self.type = type
        self.command = command
        self.name = name
        self.path = path
        self.query = query
    }
}

public struct CodexNetworkApprovalContext: Codable, Sendable, Equatable {
    public let host: String
    public let `protocol`: String

    public init(host: String, protocol: String) {
        self.host = host
        self.protocol = `protocol`
    }
}

public struct CodexUserInputQuestion: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let question: String
    public let header: String?
    public let isSecret: Bool
    public let isOtherAllowed: Bool
    public let options: [CodexUserInputOption]

    public init(
        id: String,
        question: String,
        header: String? = nil,
        isSecret: Bool = false,
        isOtherAllowed: Bool = false,
        options: [CodexUserInputOption] = []
    ) {
        self.id = id
        self.question = question
        self.header = header
        self.isSecret = isSecret
        self.isOtherAllowed = isOtherAllowed
        self.options = options
    }
}

public struct CodexUserInputOption: Codable, Sendable, Equatable {
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}
