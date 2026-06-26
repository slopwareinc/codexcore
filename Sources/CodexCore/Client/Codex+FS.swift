import Foundation

public extension Codex {
    private func fsRequest<Params: Encodable, Response: Decodable>(
        _ method: CodexAppServerClientMethod,
        params: Params,
        response: Response.Type
    ) async throws -> Response {
        let encoded = try CodexJSONValue(encoding: params)
        guard let object = encoded.objectValue else {
            throw CodexJSONBridgeError.paramsMustBeObject(encoded)
        }
        return try await appServerRequest(method, params: object, response: Response.self)
    }

    func readFile(_ params: CodexSchemaFSReadFileParams) async throws -> CodexSchemaFSReadFileResponse {
        try await fsRequest(.fsReadFile, params: params, response: CodexSchemaFSReadFileResponse.self)
    }

    func writeFile(_ params: CodexSchemaFSWriteFileParams) async throws -> CodexSchemaFSWriteFileResponse {
        try await fsRequest(.fsWriteFile, params: params, response: CodexSchemaFSWriteFileResponse.self)
    }

    func createDirectory(_ params: CodexSchemaFSCreateDirectoryParams) async throws -> CodexSchemaFSCreateDirectoryResponse {
        try await fsRequest(.fsCreateDirectory, params: params, response: CodexSchemaFSCreateDirectoryResponse.self)
    }

    func getMetadata(_ params: CodexSchemaFSGetMetadataParams) async throws -> CodexSchemaFSGetMetadataResponse {
        try await fsRequest(.fsGetMetadata, params: params, response: CodexSchemaFSGetMetadataResponse.self)
    }

    func readDirectory(_ params: CodexSchemaFSReadDirectoryParams) async throws -> CodexSchemaFSReadDirectoryResponse {
        try await fsRequest(.fsReadDirectory, params: params, response: CodexSchemaFSReadDirectoryResponse.self)
    }

    func remove(_ params: CodexSchemaFSRemoveParams) async throws -> CodexSchemaFSRemoveResponse {
        try await fsRequest(.fsRemove, params: params, response: CodexSchemaFSRemoveResponse.self)
    }

    func copy(_ params: CodexSchemaFSCopyParams) async throws -> CodexSchemaFSCopyResponse {
        try await fsRequest(.fsCopy, params: params, response: CodexSchemaFSCopyResponse.self)
    }

    func watch(_ params: CodexSchemaFSWatchParams) async throws -> CodexSchemaFSWatchResponse {
        try await fsRequest(.fsWatch, params: params, response: CodexSchemaFSWatchResponse.self)
    }

    func unwatch(_ params: CodexSchemaFSUnwatchParams) async throws -> CodexSchemaFSUnwatchResponse {
        try await fsRequest(.fsUnwatch, params: params, response: CodexSchemaFSUnwatchResponse.self)
    }
}
