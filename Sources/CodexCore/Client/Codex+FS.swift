import Foundation

public extension Codex {
    func readFile(_ params: CodexSchemaFSReadFileParams) async throws -> CodexSchemaFSReadFileResponse {
        try await perform(CodexRequest.fsReadFile(params))
    }

    func writeFile(_ params: CodexSchemaFSWriteFileParams) async throws -> CodexSchemaFSWriteFileResponse {
        try await perform(CodexRequest.fsWriteFile(params))
    }

    func createDirectory(_ params: CodexSchemaFSCreateDirectoryParams) async throws -> CodexSchemaFSCreateDirectoryResponse {
        try await perform(CodexRequest.fsCreateDirectory(params))
    }

    func getMetadata(_ params: CodexSchemaFSGetMetadataParams) async throws -> CodexSchemaFSGetMetadataResponse {
        try await perform(CodexRequest.fsGetMetadata(params))
    }

    func readDirectory(_ params: CodexSchemaFSReadDirectoryParams) async throws -> CodexSchemaFSReadDirectoryResponse {
        try await perform(CodexRequest.fsReadDirectory(params))
    }

    func remove(_ params: CodexSchemaFSRemoveParams) async throws -> CodexSchemaFSRemoveResponse {
        try await perform(CodexRequest.fsRemove(params))
    }

    func copy(_ params: CodexSchemaFSCopyParams) async throws -> CodexSchemaFSCopyResponse {
        try await perform(CodexRequest.fsCopy(params))
    }

    func watch(_ params: CodexSchemaFSWatchParams) async throws -> CodexSchemaFSWatchResponse {
        try await perform(CodexRequest.fsWatch(params))
    }

    /// Register before `watch(_:)` to receive the watch's change stream.
    func observeFSChanges(
        watchID: String,
        maximumChangeCount: Int = 512
    ) async throws -> AsyncThrowingStream<CodexSchemaFSChangedNotification, Error> {
        try await session.observeFSChanges(
            watchID: watchID,
            maximumChangeCount: maximumChangeCount
        )
    }

    func unwatch(_ params: CodexSchemaFSUnwatchParams) async throws -> CodexSchemaFSUnwatchResponse {
        try await perform(CodexRequest.fsUnwatch(params))
    }
}
