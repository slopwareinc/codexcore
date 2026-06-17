import Foundation

public protocol CodexError: Error {}

public enum CodexRPCErrorKind: String, Codable, Sendable, Equatable {
    case jsonRpc
    case codexRpc
    case parse
    case invalidRequest
    case methodNotFound
    case invalidParams
    case internalRpc
    case serverBusy
    case retryLimitExceeded
}

public struct CodexRPCError: CodexError, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let code: Int
    public let message: String
    public let data: CodexJSONValue?
    public let kind: CodexRPCErrorKind

    public init(code: Int, message: String, data: CodexJSONValue? = nil, kind: CodexRPCErrorKind = .jsonRpc) {
        self.code = code
        self.message = message
        self.data = data
        self.kind = kind
    }

    public var description: String {
        "JSON-RPC error \(code): \(message)"
    }

    public var errorDescription: String? { description }
}

public func mapJSONRPCError(code: Int, message: String, data: CodexJSONValue? = nil) -> CodexRPCError {
    switch code {
    case -32700:
        return CodexRPCError(code: code, message: message, data: data, kind: .parse)
    case -32600:
        return CodexRPCError(code: code, message: message, data: data, kind: .invalidRequest)
    case -32601:
        return CodexRPCError(code: code, message: message, data: data, kind: .methodNotFound)
    case -32602:
        return CodexRPCError(code: code, message: message, data: data, kind: .invalidParams)
    case -32603:
        return CodexRPCError(code: code, message: message, data: data, kind: .internalRpc)
    case -32099 ... -32000:
        if containsServerOverloaded(data) {
            if containsRetryLimitText(message) {
                return CodexRPCError(code: code, message: message, data: data, kind: .retryLimitExceeded)
            }
            return CodexRPCError(code: code, message: message, data: data, kind: .serverBusy)
        }
        if containsRetryLimitText(message) {
            return CodexRPCError(code: code, message: message, data: data, kind: .retryLimitExceeded)
        }
        return CodexRPCError(code: code, message: message, data: data, kind: .codexRpc)
    default:
        return CodexRPCError(code: code, message: message, data: data, kind: .jsonRpc)
    }
}

public func isRetryableError(_ error: Error) -> Bool {
    if let rpcError = error as? CodexRPCError {
        return rpcError.kind == .serverBusy || rpcError.kind == .retryLimitExceeded || containsServerOverloaded(rpcError.data)
    }

    if let wireError = error as? JSONRPCError {
        return containsServerOverloaded(wireError.data)
    }

    return false
}

public func retryOnOverload<T: Sendable>(
    maxAttempts: Int = 3,
    initialDelay: Duration = .milliseconds(250),
    maxDelay: Duration = .seconds(2),
    jitterRatio: Double = 0.2,
    operation: @Sendable () async throws -> T
) async throws -> T {
    precondition(maxAttempts >= 1, "maxAttempts must be >= 1")

    var delay = initialDelay
    var attempt = 0

    while true {
        attempt += 1
        do {
            return try await operation()
        } catch {
            if attempt >= maxAttempts || !isRetryableError(error) {
                throw error
            }

            let sleepFor = jitteredDelay(delay, maxDelay: maxDelay, jitterRatio: jitterRatio)
            if sleepFor > .zero {
                try await Task.sleep(for: sleepFor)
            }
            delay = minDuration(maxDelay, delay * 2)
        }
    }
}

private func containsRetryLimitText(_ message: String) -> Bool {
    let lowered = message.lowercased()
    return lowered.contains("retry limit") || lowered.contains("too many failed attempts")
}

private func containsServerOverloaded(_ value: CodexJSONValue?) -> Bool {
    guard let value else { return false }

    switch value {
    case .string(let string):
        return string.lowercased() == "server_overloaded"
    case .dictionary(let dictionary):
        for key in ["codex_error_info", "codexErrorInfo", "errorInfo"] {
            if let direct = dictionary[key] {
                if case .string(let string) = direct, string.lowercased() == "server_overloaded" {
                    return true
                }
                if containsServerOverloaded(direct) {
                    return true
                }
            }
        }
        return dictionary.values.contains { containsServerOverloaded($0) }
    case .array(let array):
        return array.contains { containsServerOverloaded($0) }
    default:
        return false
    }
}

private func jitteredDelay(_ delay: Duration, maxDelay: Duration, jitterRatio: Double) -> Duration {
    let capped = minDuration(delay, maxDelay)
    guard jitterRatio > 0 else { return capped }

    let seconds = capped.secondsValue
    let jitter = seconds * jitterRatio
    let randomized = seconds + Double.random(in: -jitter ... jitter)
    return Duration.nanoseconds(Int64(max(0, randomized) * 1_000_000_000))
}

private func minDuration(_ lhs: Duration, _ rhs: Duration) -> Duration {
    lhs <= rhs ? lhs : rhs
}

private extension Duration {
    var secondsValue: Double {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

extension JSONRPCError {
    public var mappedError: CodexRPCError {
        mapJSONRPCError(code: code, message: message, data: data)
    }
}

extension CodexSDKError: CodexError {}
extension CodexConnectionError: CodexError {}
