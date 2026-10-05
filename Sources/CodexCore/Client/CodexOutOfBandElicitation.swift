import Foundation

/// The external interaction finished, but its original server counter could not
/// be released. No decrement is replayed on a replacement connection.
public struct CodexOutOfBandElicitationReleaseError: Error, Sendable, LocalizedError {
    public let threadID: ThreadID
    public let connectionEpoch: UInt64
    public let operationFailure: String?
    public let releaseFailure: String

    public var errorDescription: String? {
        "The external interaction for thread \(threadID) ended, but its pause could not be released on connection \(connectionEpoch): \(releaseFailure)"
    }
}

enum CodexOutOfBandElicitation {
    static func perform<Response: Decodable & Sendable>(
        _ request: CodexAppServerRequest<Response>, session: CodexSession, epoch: UInt64
    ) async throws -> Response {
        let result = try await session.performCall(
            method: request.method, params: try request.encodeParameters(),
            expectedConnectionEpoch: epoch
        )
        return try result.value.decode(Response.self)
    }
}
