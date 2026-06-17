import Foundation

public extension CodexClient {
    @discardableResult
    func appServerRequest(
        _ method: CodexAppServerClientMethod,
        params: [String: CodexJSONValue] = [:]
    ) async throws -> CodexJSONValue {
        try await request(method: method.rawValue, params: params)
    }

    func appServerRequest<Response: Decodable>(
        _ method: CodexAppServerClientMethod,
        params: [String: CodexJSONValue] = [:],
        response: Response.Type
    ) async throws -> Response {
        let value = try await appServerRequest(method, params: params)
        return try value.decode(Response.self)
    }

    @discardableResult
    func appServerRequestWithRetryOnOverload(
        _ method: CodexAppServerClientMethod,
        params: [String: CodexJSONValue] = [:],
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(250),
        maxDelay: Duration = .seconds(2),
        jitterRatio: Double = 0.2
    ) async throws -> CodexJSONValue {
        try await requestWithRetryOnOverload(
            method: method.rawValue,
            params: params,
            maxAttempts: maxAttempts,
            initialDelay: initialDelay,
            maxDelay: maxDelay,
            jitterRatio: jitterRatio
        )
    }
}

extension CodexClient {
    @discardableResult
    func requestWithRetryOnOverload(
        method: String,
        params: [String: CodexJSONValue] = [:],
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(250),
        maxDelay: Duration = .seconds(2),
        jitterRatio: Double = 0.2
    ) async throws -> CodexJSONValue {
        try await retryOnOverload(
            maxAttempts: maxAttempts,
            initialDelay: initialDelay,
            maxDelay: maxDelay,
            jitterRatio: jitterRatio
        ) {
            try await self.request(method: method, params: params)
        }
    }
}

public extension Codex {
    @discardableResult
    func appServerRequest(
        _ method: CodexAppServerClientMethod,
        params: [String: CodexJSONValue] = [:]
    ) async throws -> CodexJSONValue {
        try await appServerRequest(method: method.rawValue, params: params)
    }

    func appServerRequest<Response: Decodable>(
        _ method: CodexAppServerClientMethod,
        params: [String: CodexJSONValue] = [:],
        response: Response.Type
    ) async throws -> Response {
        let value = try await appServerRequest(method, params: params)
        return try value.decode(Response.self)
    }

    @discardableResult
    func appServerRequestWithRetryOnOverload(
        _ method: CodexAppServerClientMethod,
        params: [String: CodexJSONValue] = [:],
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(250),
        maxDelay: Duration = .seconds(2),
        jitterRatio: Double = 0.2
    ) async throws -> CodexJSONValue {
        try await requestWithRetryOnOverload(
            method: method.rawValue,
            params: params,
            maxAttempts: maxAttempts,
            initialDelay: initialDelay,
            maxDelay: maxDelay,
            jitterRatio: jitterRatio
        )
    }
}

extension Codex {
    @discardableResult
    func requestWithRetryOnOverload(
        method: String,
        params: [String: CodexJSONValue] = [:],
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(250),
        maxDelay: Duration = .seconds(2),
        jitterRatio: Double = 0.2
    ) async throws -> CodexJSONValue {
        try await appServerRequestWithClientRetryOnOverload(
            method: method,
            params: params,
            maxAttempts: maxAttempts,
            initialDelay: initialDelay,
            maxDelay: maxDelay,
            jitterRatio: jitterRatio
        )
    }
}
