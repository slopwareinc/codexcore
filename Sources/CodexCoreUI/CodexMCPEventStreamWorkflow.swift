import CodexCore

enum CodexMCPEventStreamWorkflow {
    static func run(
        _ params: CodexSchemaMCPServerEventStreamStartParams,
        provider: any CodexIntegrationControlPlaneProvider,
        onEvent: @MainActor @Sendable (CodexSchemaMCPServerEventNotification) async -> Void
    ) async throws {
        // Observation precedes start because notifications may beat its response.
        let stream = try await provider.observeMCPServerEvents()
        try Task.checkCancellation()
        var failure: Error?
        do {
            _ = try await provider.perform(.mcpEventStreamStart(params))
            for try await event in stream where event.subscriptionID == params.subscriptionID {
                try Task.checkCancellation()
                await onEvent(event.notification)
            }
        } catch { failure = error }
        // The write may have succeeded even if its response was cancelled. An
        // independent task lets stop complete after the consumer is cancelled.
        do {
            _ = try await Task {
                try await provider.perform(.mcpEventStreamStop(.init(subscriptionID: params.subscriptionID)))
            }.value
        } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }
}
