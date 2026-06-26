import Foundation

public extension Codex {
    
    // MARK: - Process Endpoints
    
    @discardableResult
    func processSpawn(_ params: CodexSchemaProcessSpawnParams) async throws -> CodexSchemaProcessSpawnResponse {
        try await appServerRequest(.processSpawn, params: try params.toCodexJSONValueDictionary(), response: CodexSchemaProcessSpawnResponse.self)
    }
    
    @discardableResult
    func processWriteStdin(_ params: CodexSchemaProcessWriteStdinParams) async throws -> CodexSchemaProcessWriteStdinResponse {
        try await appServerRequest(.processWriteStdin, params: try params.toCodexJSONValueDictionary(), response: CodexSchemaProcessWriteStdinResponse.self)
    }

    @discardableResult
    func processKill(_ params: CodexSchemaProcessKillParams) async throws -> CodexSchemaProcessKillResponse {
        try await appServerRequest(.processKill, params: try params.toCodexJSONValueDictionary(), response: CodexSchemaProcessKillResponse.self)
    }

    @discardableResult
    func processResizePTY(_ params: CodexSchemaProcessResizePTYParams) async throws -> CodexSchemaProcessResizePTYResponse {
        try await appServerRequest(.processResizePTY, params: try params.toCodexJSONValueDictionary(), response: CodexSchemaProcessResizePTYResponse.self)
    }

    // MARK: - Missing Command Endpoints

    @discardableResult
    func commandExecWrite(_ params: CodexSchemaCommandExecWriteParams) async throws -> CodexSchemaCommandExecWriteResponse {
        try await appServerRequest(.commandExecWrite, params: try params.toCodexJSONValueDictionary(), response: CodexSchemaCommandExecWriteResponse.self)
    }

    @discardableResult
    func commandExecTerminate(_ params: CodexSchemaCommandExecTerminateParams) async throws -> CodexSchemaCommandExecTerminateResponse {
        try await appServerRequest(.commandExecTerminate, params: try params.toCodexJSONValueDictionary(), response: CodexSchemaCommandExecTerminateResponse.self)
    }

    @discardableResult
    func commandExecResize(_ params: CodexSchemaCommandExecResizeParams) async throws -> CodexSchemaCommandExecResizeResponse {
        try await appServerRequest(.commandExecResize, params: try params.toCodexJSONValueDictionary(), response: CodexSchemaCommandExecResizeResponse.self)
    }
}

private extension Encodable {
    func toCodexJSONValueDictionary() throws -> [String: CodexJSONValue] {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode([String: CodexJSONValue].self, from: data)
    }
}
