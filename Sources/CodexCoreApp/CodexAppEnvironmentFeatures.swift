import Foundation
import Observation
import CodexCore

/// Executor setup is separate from remote-control pairing. Reading status never
/// starts an executor; requesting shell information is an explicit operation.
@Observable @MainActor
final class CodexAppEnvironmentFeatures {
    private(set) var environmentID: String?
    private(set) var status: CodexSchemaEnvironmentStatusResponse?
    private(set) var info: CodexSchemaEnvironmentInfoResponse?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var notice: String?
    @ObservationIgnored private var provider: (any CodexAppRuntimeProviding)?
    @ObservationIgnored private var generation: UInt64 = 0

    func bind(_ provider: (any CodexAppRuntimeProviding)?) {
        generation &+= 1
        self.provider = provider
        environmentID = nil
        status = nil
        info = nil
        isBusy = false
        errorMessage = nil
        notice = nil
    }

    static func addParameters(environmentID: String, endpoint: String, bearerToken: String,
                              timeoutMilliseconds: String) throws -> CodexSchemaEnvironmentAddParams {
        let id = environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw CodexAppFeatureError.invalidInput("Enter an environment ID.") }
        guard let url = URLComponents(string: endpoint), let host = url.host, !host.isEmpty,
              ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), url.user == nil,
              url.password == nil, url.fragment == nil else {
            throw CodexAppFeatureError.invalidInput("Enter a ws:// or wss:// executor URL without embedded credentials.")
        }
        if !bearerToken.isEmpty, url.scheme?.lowercased() != "wss", !isLoopback(host) {
            throw CodexAppFeatureError.invalidInput("Bearer authentication requires wss:// or a loopback executor.")
        }
        guard !bearerToken.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) else {
            throw CodexAppFeatureError.invalidInput("The bearer token must fit on one line.")
        }
        let rawTimeout = timeoutMilliseconds.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeout: Int?
        if rawTimeout.isEmpty { timeout = nil }
        else {
            guard let value = Int(rawTimeout), value >= 0 else {
                throw CodexAppFeatureError.invalidInput("Enter a nonnegative connection timeout in milliseconds.")
            }
            timeout = value
        }
        return .init(authBearerToken: bearerToken.isEmpty ? nil : bearerToken, connectTimeoutMs: timeout,
                     environmentID: id, execServerUrl: endpoint)
    }

    private static func isLoopback(_ host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value == "localhost" || value == "::1" { return true }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 4 && components.first == "127"
            && components.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    /// Keeps credentials in the scoped request only, never observable state.
    func add(_ params: CodexSchemaEnvironmentAddParams) async {
        await run { provider, expected in
            _ = try await provider.perform(CodexRequest.environmentAdd(params))
            guard expected == self.generation else { return }
            self.environmentID = params.environmentID
            self.status = nil
            self.info = nil
            self.notice = "Environment configured. Check status or explicitly read its shell information."
        }
    }

    func refreshStatus(environmentID: String) async {
        let id = environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { errorMessage = "Enter an environment ID."; return }
        await run { provider, expected in
            let result = try await provider.perform(CodexRequest.environmentStatus(.init(environmentID: id)))
            guard expected == self.generation else { return }
            if self.environmentID != id { self.info = nil }
            self.environmentID = id
            // Native transport errors may include connection details. Present
            // the typed status without retaining their diagnostic string.
            self.status = .init(status: result.status)
            self.notice = nil
        }
    }

    func readInfo(environmentID: String) async {
        let id = environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { errorMessage = "Enter an environment ID."; return }
        await run { provider, expected in
            let result = try await provider.perform(CodexRequest.environmentInfo(.init(environmentID: id)))
            guard expected == self.generation else { return }
            if self.environmentID != id { self.status = nil }
            self.environmentID = id
            self.info = result
            self.notice = "Shell information received."
        }
    }

    private func run(_ operation: (any CodexAppRuntimeProviding, UInt64) async throws -> Void) async {
        guard let provider, !isBusy else { return }
        let expected = generation
        isBusy = true
        errorMessage = nil
        defer { if expected == generation { isBusy = false } }
        do { try await operation(provider, expected) }
        catch {
            guard expected == generation, !Task.isCancelled else { return }
            errorMessage = "The environment operation could not be confirmed. Check its status before retrying."
        }
    }
}
