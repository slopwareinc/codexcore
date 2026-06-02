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
}

public extension Codex {
    @discardableResult
    func appServerRequest(
        _ method: CodexAppServerClientMethod,
        params: [String: CodexJSONValue] = [:]
    ) async throws -> CodexJSONValue {
        try await rawRequest(method: method.rawValue, params: params)
    }

    func appServerRequest<Response: Decodable>(
        _ method: CodexAppServerClientMethod,
        params: [String: CodexJSONValue] = [:],
        response: Response.Type
    ) async throws -> Response {
        let value = try await appServerRequest(method, params: params)
        return try value.decode(Response.self)
    }
}
