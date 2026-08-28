import Foundation

public extension Codex {
    /// Register before `fuzzyFileSearchSessionStart(_:)` to receive updates and
    /// the terminal completion for that session.
    func observeFuzzyFileSearch(
        sessionID: String,
        maximumEventCount: Int = 128
    ) async throws -> AsyncThrowingStream<CodexFuzzyFileSearchEvent, Error> {
        try await session.observeFuzzyFileSearch(
            sessionID: sessionID,
            maximumEventCount: maximumEventCount
        )
    }

    /// Register before `mcpServerOAuthLogin(_:)` to receive its completion.
    func observeMCPServerOAuthLogin(
        name: String,
        threadID: String? = nil
    ) async throws -> AsyncThrowingStream<
        CodexSchemaMCPServerOAuthLoginCompletedNotification,
        Error
    > {
        try await session.observeMCPServerOAuthLogin(name: name, threadID: threadID)
    }

    /// Register before `mcpServerEventStreamStart(_:)`; filter concurrent
    /// subscriptions by the notification's `subscriptionID`.
    func observeMCPServerEventStreamNotifications() async throws -> AsyncThrowingStream<
        CodexSchemaMCPServerEventStreamNotification,
        Error
    > {
        try await session.observeMCPServerEventStreamNotifications()
    }

    /// Register before `externalAgentConfigImport(_:)` to receive progress and
    /// completion for its returned import id.
    func observeExternalAgentConfigImport(
        importID: String
    ) async throws -> AsyncThrowingStream<CodexExternalAgentConfigImportEvent, Error> {
        try await session.observeExternalAgentConfigImport(importID: importID)
    }

    func observeAppListChanges() async throws -> AsyncThrowingStream<
        CodexSchemaAppListUpdatedNotification,
        Error
    > {
        try await session.observeAppListChanges()
    }

    func observeRemoteControlStatusChanges() async throws -> AsyncThrowingStream<
        CodexSchemaRemoteControlStatusChangedNotification,
        Error
    > {
        try await session.observeRemoteControlStatusChanges()
    }

    func observeWindowsSandboxSetup() async throws -> AsyncThrowingStream<
        CodexSchemaWindowsSandboxSetupCompletedNotification,
        Error
    > {
        try await session.observeWindowsSandboxSetup()
    }
}
