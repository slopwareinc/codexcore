import Foundation

public extension Codex {
    
    // MARK: - Process Endpoints
    
    @discardableResult
    func processSpawn(_ params: CodexSchemaProcessSpawnParams) async throws -> CodexSchemaProcessSpawnResponse {
        try await perform(CodexRequest.processSpawn(params))
    }
    
    @discardableResult
    func processWriteStdin(_ params: CodexSchemaProcessWriteStdinParams) async throws -> CodexSchemaProcessWriteStdinResponse {
        try await perform(CodexRequest.processWriteStdin(params))
    }

    @discardableResult
    func processKill(_ params: CodexSchemaProcessKillParams) async throws -> CodexSchemaProcessKillResponse {
        try await perform(CodexRequest.processKill(params))
    }

    @discardableResult
    func processResizePTY(_ params: CodexSchemaProcessResizePTYParams) async throws -> CodexSchemaProcessResizePTYResponse {
        try await perform(CodexRequest.processResizePTY(params))
    }

    // MARK: - Missing Command Endpoints

    @discardableResult
    func commandExecWrite(_ params: CodexSchemaCommandExecWriteParams) async throws -> CodexSchemaCommandExecWriteResponse {
        try await perform(CodexRequest.commandExecWrite(params))
    }

    @discardableResult
    func commandExecTerminate(_ params: CodexSchemaCommandExecTerminateParams) async throws -> CodexSchemaCommandExecTerminateResponse {
        try await perform(CodexRequest.commandExecTerminate(params))
    }

    @discardableResult
    func commandExecResize(_ params: CodexSchemaCommandExecResizeParams) async throws -> CodexSchemaCommandExecResizeResponse {
        try await perform(CodexRequest.commandExecResize(params))
    }
}
