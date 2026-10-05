import Foundation
import CodexCore

/// Keeps feature controllers on the sealed, generated request surface.
protocol CodexAppRuntimeProviding: Sendable {
    func perform<Response: Decodable & Sendable>(
        _ request: CodexAppServerRequest<Response>
    ) async throws -> Response
}

struct CodexAppRuntimeProvider: CodexAppRuntimeProviding {
    let codex: Codex

    func perform<Response: Decodable & Sendable>(
        _ request: CodexAppServerRequest<Response>
    ) async throws -> Response {
        try await codex.perform(request)
    }
}

enum CodexAppFeatureError: Error, LocalizedError {
    case disconnected
    case invalidInput(String)
    case repeatedCursor

    var errorDescription: String? {
        switch self {
        case .disconnected: "Connect to Codex first."
        case .invalidInput(let message): message
        case .repeatedCursor: "The runtime repeated a pagination cursor. Refresh to retry."
        }
    }
}
