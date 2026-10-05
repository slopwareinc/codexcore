import Foundation
import Observation
import CodexCore

protocol CodexAppRemoteControlProviding: CodexAppRuntimeProviding {
    func observeStatus() async throws -> AsyncThrowingStream<CodexSchemaRemoteControlStatusChangedNotification, Error>
}

struct CodexAppRemoteControlRuntime: CodexAppRemoteControlProviding {
    let codex: Codex
    func perform<Response: Decodable & Sendable>(_ request: CodexAppServerRequest<Response>) async throws -> Response {
        try await codex.perform(request)
    }
    func observeStatus() async throws -> AsyncThrowingStream<CodexSchemaRemoteControlStatusChangedNotification, Error> {
        try await codex.observeRemoteControlStatusChanges()
    }
}

@Observable @MainActor
final class CodexAppRemoteControlFeatures {
    private(set) var status: CodexSchemaRemoteControlStatusReadResponse?
    private(set) var clients: [CodexSchemaRemoteControlClient] = []
    private(set) var pairing: CodexSchemaRemoteControlPairingStartResponse?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var notice: String?
    var temporaryChange = true
    @ObservationIgnored private var provider: (any CodexAppRemoteControlProviding)?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var statusRevision: UInt64 = 0
    @ObservationIgnored private var pairingRevision: UInt64 = 0
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// Binding only installs the local observer. It does not enable remote
    /// access, generate credentials, or make account/billing requests.
    func bind(_ provider: (any CodexAppRemoteControlProviding)?) async {
        generation &+= 1
        let expected = generation
        observationTask?.cancel()
        observationTask = nil
        clearPairing()
        self.provider = provider
        status = nil
        clients = []
        isBusy = false
        errorMessage = nil
        notice = nil
        guard let provider else { return }
        do {
            let events = try await provider.observeStatus()
            guard expected == generation else { return }
            observationTask = Task { [weak self] in
                do {
                    for try await event in events {
                        guard let self, self.generation == expected, !Task.isCancelled else { return }
                        self.apply(.init(environmentID: event.environmentID, installationID: event.installationID,
                                         serverName: event.serverName, status: event.status))
                    }
                } catch {
                    guard let self, self.generation == expected, !Task.isCancelled else { return }
                    self.errorMessage = "Remote-control status observation ended. Reconnect to restore live updates."
                }
            }
        } catch {
            if expected == generation { errorMessage = "Live remote-control status is unavailable. Refresh to read the current status." }
        }
    }

    func refresh() async {
        await run { provider, expected in
            let revision = self.statusRevision
            let result = try await provider.perform(CodexRequest.remoteControlStatusRead())
            guard expected == self.generation else { return }
            // A newer live transition wins over a read started before it.
            if revision == self.statusRevision { self.apply(result) }
            if let environmentID = self.status?.environmentID {
                let clients = try await Self.loadClients(provider, environmentID: environmentID)
                guard expected == self.generation, self.status?.environmentID == environmentID else { return }
                self.clients = clients
            }
        }
    }

    func enable() async {
        let ephemeral = temporaryChange
        await run { provider, expected in
            let revision = self.statusRevision
            let result = try await provider.perform(CodexRequest.remoteControlEnable(.value(.init(ephemeral: ephemeral))))
            guard expected == self.generation else { return }
            if revision == self.statusRevision {
                self.apply(.init(environmentID: result.environmentID, installationID: result.installationID,
                                 serverName: result.serverName, status: result.status))
            }
            self.notice = "Remote control: \(self.status?.status.rawValue ?? result.status.rawValue)."
        }
    }

    func disable() async {
        let ephemeral = temporaryChange
        await run { provider, expected in
            let revision = self.statusRevision
            let result = try await provider.perform(CodexRequest.remoteControlDisable(.value(.init(ephemeral: ephemeral))))
            guard expected == self.generation else { return }
            if revision == self.statusRevision {
                self.apply(.init(environmentID: result.environmentID, installationID: result.installationID,
                                 serverName: result.serverName, status: result.status))
            }
            self.clearPairing()
            self.clients = []
            self.notice = "Remote control: \(self.status?.status.rawValue ?? result.status.rawValue)."
        }
    }

    func startPairing() async {
        guard status?.status == .connected else {
            errorMessage = "Enable remote control and wait for a connected status before pairing."
            return
        }
        clearPairing()
        let expectedPairingRevision = pairingRevision
        await run { provider, expected in
            let value = try await provider.perform(CodexRequest.remoteControlPairingStart(.init(manualCode: true)))
            guard expected == self.generation, expectedPairingRevision == self.pairingRevision else { return }
            guard self.status?.environmentID == value.environmentID, self.status?.status == .connected else {
                throw CodexAppFeatureError.invalidInput("The remote environment changed. Refresh before pairing.")
            }
            guard Date(timeIntervalSince1970: TimeInterval(value.expiresAt)) > .now else {
                throw CodexAppFeatureError.invalidInput("The pairing code has expired. Request a new code.")
            }
            self.pairing = value
            self.scheduleExpiry(value, generation: expected)
        }
    }

    func checkPairing() async {
        guard let pairing else { return }
        guard Date(timeIntervalSince1970: TimeInterval(pairing.expiresAt)) > .now else {
            clearPairing()
            notice = "Pairing code expired."
            return
        }
        await run { provider, expected in
            let response = try await provider.perform(CodexRequest.remoteControlPairingStatus(.init(pairingCode: pairing.pairingCode)))
            guard expected == self.generation, self.pairing?.pairingCode == pairing.pairingCode else { return }
            if response.claimed {
                self.clearPairing()
                self.notice = "Device paired."
                let clients = try await Self.loadClients(provider, environmentID: pairing.environmentID)
                guard expected == self.generation, self.status?.environmentID == pairing.environmentID else { return }
                self.clients = clients
            } else { self.notice = "Waiting for the device to claim this code." }
        }
    }

    func revoke(_ client: CodexSchemaRemoteControlClient) async {
        guard let environmentID = status?.environmentID else { return }
        await run { provider, expected in
            _ = try await provider.perform(CodexRequest.remoteControlClientRevoke(.init(clientID: client.clientID, environmentID: environmentID)))
            let clients = try await Self.loadClients(provider, environmentID: environmentID)
            guard expected == self.generation, self.status?.environmentID == environmentID else { return }
            self.clients = clients
            self.notice = "Device access revoked."
        }
    }

    func clearPairing() {
        pairingRevision &+= 1
        expiryTask?.cancel()
        expiryTask = nil
        pairing = nil
    }

    private func apply(_ value: CodexSchemaRemoteControlStatusReadResponse) {
        statusRevision &+= 1
        if status?.environmentID != value.environmentID || value.status == .disabled {
            clearPairing()
            clients = []
        }
        status = value
    }

    private func run(_ operation: (any CodexAppRemoteControlProviding, UInt64) async throws -> Void) async {
        guard let provider, !isBusy else { return }
        let expected = generation
        isBusy = true
        errorMessage = nil
        defer { if expected == generation { isBusy = false } }
        do { try await operation(provider, expected) }
        catch {
            guard expected == generation, !Task.isCancelled else { return }
            // Pairing codes are never included in diagnostics or error state.
            errorMessage = (error as? CodexAppFeatureError)?.localizedDescription
                ?? "Remote-control operation did not complete. Refresh its status before retrying."
        }
    }

    private func scheduleExpiry(_ pairing: CodexSchemaRemoteControlPairingStartResponse, generation: UInt64) {
        expiryTask?.cancel()
        let deadline = Date(timeIntervalSince1970: TimeInterval(pairing.expiresAt))
        // The timer retains the deadline and environment, never the code.
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = deadline.timeIntervalSinceNow
                if interval <= 0 {
                    guard let self, self.generation == generation else { return }
                    self.clearPairing()
                    self.notice = "Pairing code expired."
                    return
                }
                do { try await Task.sleep(for: .seconds(min(interval, 60))) }
                catch { return }
            }
        }
    }

    private static func loadClients(_ provider: any CodexAppRemoteControlProviding, environmentID: String) async throws -> [CodexSchemaRemoteControlClient] {
        var cursor: String?
        var seenCursors = Set<String>()
        var clients: [CodexSchemaRemoteControlClient] = []
        var seenClients = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await provider.perform(CodexRequest.remoteControlClientList(.init(cursor: cursor, environmentID: environmentID, limit: 100, order: .desc)))
            for client in page.data where seenClients.insert(client.clientID).inserted { clients.append(client) }
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted { throw CodexAppFeatureError.repeatedCursor }
        } while cursor != nil
        return clients
    }
}
