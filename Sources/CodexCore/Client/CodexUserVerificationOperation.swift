import Foundation

/// A single connection-scoped native user-verification RPC.
///
/// Canceling signals the original RPC ID, discards late results, and never
/// cancels unrelated requests or an operation on a replacement connection.
/// The cancellation acknowledgment does not imply that an OS prompt has closed
/// or that completed enrollment/deletion effects have been rolled back.
public struct CodexUserVerificationOperation<Response: Sendable>: Sendable {
    public let connectionEpoch: UInt64
    public let requestID: CodexJSONRPCID
    private let response: Task<Response, Error>
    private let cancellation: @Sendable () async throws -> Void

    init(
        connectionEpoch: UInt64,
        requestID: CodexJSONRPCID,
        response: Task<Response, Error>,
        cancel: @escaping @Sendable () async throws -> Void
    ) {
        self.connectionEpoch = connectionEpoch
        self.requestID = requestID
        self.response = response
        self.cancellation = cancel
    }

    public func completion() async throws -> Response {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await response.value
        } onCancel: {
            Task { try? await cancellation() }
        }
    }

    public func cancel() async throws { try await cancellation() }
}

public extension Codex {
    func startUserVerification<Response: Decodable & Sendable>(
        _ request: CodexAppServerRequest<Response>
    ) async throws -> CodexUserVerificationOperation<Response> {
        try await session.startUserVerification(request)
    }
}
