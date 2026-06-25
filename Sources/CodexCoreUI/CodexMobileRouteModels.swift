import Foundation
import CodexCore

public enum CodexRemoteControlStatusKind: String, Equatable, Sendable {
    case disabled
    case connecting
    case enabled
    case error

    public init(_ status: CodexSchemaRemoteControlConnectionStatus) {
        switch status {
        case .disabled:
            self = .disabled
        case .connecting:
            self = .connecting
        case .connected:
            self = .enabled
        case .errored:
            self = .error
        }
    }

    public var title: String {
        switch self {
        case .disabled: return "Disabled"
        case .connecting: return "Connecting"
        case .enabled: return "Enabled"
        case .error: return "Error"
        }
    }
}

public struct CodexRemoteControlStatusModel: Equatable, Sendable {
    public var kind: CodexRemoteControlStatusKind
    public var serverName: String
    public var installationID: String?
    public var environmentID: String?
    public var errorMessage: String?

    public init(
        kind: CodexRemoteControlStatusKind = .disabled,
        serverName: String = "Codex",
        installationID: String? = nil,
        environmentID: String? = nil,
        errorMessage: String? = nil
    ) {
        self.kind = kind
        self.serverName = serverName
        self.installationID = installationID
        self.environmentID = environmentID
        self.errorMessage = errorMessage
    }

    public init(response: CodexSchemaRemoteControlStatusReadResponse) {
        self.init(
            kind: CodexRemoteControlStatusKind(response.status),
            serverName: response.serverName,
            installationID: response.installationID,
            environmentID: response.environmentID
        )
    }

    public init(notification: CodexSchemaRemoteControlStatusChangedNotification) {
        self.init(
            kind: CodexRemoteControlStatusKind(notification.status),
            serverName: notification.serverName,
            installationID: notification.installationID,
            environmentID: notification.environmentID
        )
    }

    public var statusLine: String {
        errorMessage?.nilIfBlank ?? kind.title
    }
}

public struct CodexRemoteControlPairingModel: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case pending
        case claimed
        case error
    }

    public var state: State
    public var pairingCode: String?
    public var manualPairingCode: String?
    public var expiresAt: Int?
    public var errorMessage: String?

    public init(
        state: State = .idle,
        pairingCode: String? = nil,
        manualPairingCode: String? = nil,
        expiresAt: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.state = state
        self.pairingCode = pairingCode
        self.manualPairingCode = manualPairingCode
        self.expiresAt = expiresAt
        self.errorMessage = errorMessage
    }

    public init(start response: CodexSchemaRemoteControlPairingStartResponse) {
        self.init(
            state: .pending,
            pairingCode: response.pairingCode,
            manualPairingCode: response.manualPairingCode,
            expiresAt: response.expiresAt
        )
    }

    public mutating func apply(status response: CodexSchemaRemoteControlPairingStatusResponse) {
        state = response.claimed ? .claimed : .pending
    }

    public var statusLabel: String {
        switch state {
        case .idle:
            return "Not pairing"
        case .pending:
            return "Pairing pending"
        case .claimed:
            return "Paired"
        case .error:
            return errorMessage?.nilIfBlank ?? "Pairing error"
        }
    }
}

public struct CodexRemoteControlClientSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var platformLabel: String
    public var lastSeenAt: Int?

    public init(id: String, displayName: String, platformLabel: String, lastSeenAt: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.platformLabel = platformLabel
        self.lastSeenAt = lastSeenAt
    }

    public init(client: CodexSchemaRemoteControlClient) {
        self.init(
            id: client.clientID,
            displayName: client.displayName?.nilIfBlank ?? client.deviceModel?.nilIfBlank ?? "Authorized device",
            platformLabel: [client.platform, client.osVersion].compactMap { $0?.nilIfBlank }.joined(separator: " ").nilIfBlank ?? "Device",
            lastSeenAt: client.lastSeenAt
        )
    }
}

public struct CodexMobileRouteState: Equatable, Sendable {
    public var isPermissionGatePresented: Bool
    public var status: CodexRemoteControlStatusModel
    public var pairing: CodexRemoteControlPairingModel
    public var clients: [CodexRemoteControlClientSummary]
    public var lastActivity: CodexActivity?

    public init(
        isPermissionGatePresented: Bool = false,
        status: CodexRemoteControlStatusModel = CodexRemoteControlStatusModel(),
        pairing: CodexRemoteControlPairingModel = CodexRemoteControlPairingModel(),
        clients: [CodexRemoteControlClientSummary] = [],
        lastActivity: CodexActivity? = nil
    ) {
        self.isPermissionGatePresented = isPermissionGatePresented
        self.status = status
        self.pairing = pairing
        self.clients = clients
        self.lastActivity = lastActivity
    }

    public var title: String { "Connect your phone to this Mac" }
    public var subtitle: String { "Keep working with Codex from your phone, or other device" }
    public var benefits: [String] { ["Pick up where you left off", "Stay in the loop", "Start something new"] }
    public var warning: String { "Codex will access your desktop (files, apps, and browser) to complete tasks you send from your phone. This may have security risks. Only connect devices that you own and trust." }
    public var getStartedTitle: String { "Get started" }
    public var permissionTitle: String { "Set up Codex Mobile" }
    public var permissionQuestion: String { "Allow devices to control this computer?" }
    public var permissionDetail: String { "This will allow authorized devices like your phone to discover and control Codex on this computer" }
}

public protocol CodexRemoteControlProvider: Sendable {
    func readStatus() async throws -> CodexRemoteControlStatusModel
    func enable() async throws -> CodexRemoteControlStatusModel
    func startPairing() async throws -> CodexRemoteControlPairingModel
    func readPairingStatus(pairingCode: String?, manualPairingCode: String?) async throws -> Bool
    func listClients(environmentID: String) async throws -> [CodexRemoteControlClientSummary]
    func revokeClient(clientID: String, environmentID: String) async throws
}

public struct CodexUnsupportedRemoteControlProvider: CodexRemoteControlProvider {
    public init() {}

    public func readStatus() async throws -> CodexRemoteControlStatusModel {
        CodexRemoteControlStatusModel(kind: .disabled, serverName: "Codex")
    }

    public func enable() async throws -> CodexRemoteControlStatusModel {
        throw CodexRemoteControlBoundaryError("Remote control enable is not wired in this build.")
    }

    public func startPairing() async throws -> CodexRemoteControlPairingModel {
        throw CodexRemoteControlBoundaryError("Remote control pairing is not wired in this build.")
    }

    public func readPairingStatus(pairingCode: String?, manualPairingCode: String?) async throws -> Bool {
        false
    }

    public func listClients(environmentID: String) async throws -> [CodexRemoteControlClientSummary] {
        []
    }

    public func revokeClient(clientID: String, environmentID: String) async throws {
        throw CodexRemoteControlBoundaryError("Remote control client revoke is not wired in this build.")
    }
}

public struct CodexAppServerRemoteControlProvider: CodexRemoteControlProvider {
    private let codex: Codex

    public init(codex: Codex) {
        self.codex = codex
    }

    public func readStatus() async throws -> CodexRemoteControlStatusModel {
        CodexRemoteControlStatusModel(response: try await codex.remoteControlStatusRead())
    }

    public func enable() async throws -> CodexRemoteControlStatusModel {
        let response = try await codex.remoteControlEnable()
        return CodexRemoteControlStatusModel(
            kind: CodexRemoteControlStatusKind(response.status),
            serverName: response.serverName,
            installationID: response.installationID,
            environmentID: response.environmentID
        )
    }

    public func startPairing() async throws -> CodexRemoteControlPairingModel {
        CodexRemoteControlPairingModel(start: try await codex.remoteControlPairingStart(manualCode: true))
    }

    public func readPairingStatus(pairingCode: String?, manualPairingCode: String?) async throws -> Bool {
        try await codex.remoteControlPairingStatus(pairingCode: pairingCode, manualPairingCode: manualPairingCode).claimed
    }

    public func listClients(environmentID: String) async throws -> [CodexRemoteControlClientSummary] {
        try await codex.remoteControlClientList(environmentID: environmentID).data.map(CodexRemoteControlClientSummary.init(client:))
    }

    public func revokeClient(clientID: String, environmentID: String) async throws {
        try await codex.remoteControlClientRevoke(clientID: clientID, environmentID: environmentID)
    }
}

public struct CodexRemoteControlBoundaryError: Error, LocalizedError, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct CodexMobileRouteSession: Equatable, Sendable {
    public private(set) var state: CodexMobileRouteState

    public init(state: CodexMobileRouteState = CodexMobileRouteState()) {
        self.state = state
    }

    public mutating func getStarted() -> CodexActivity {
        state.isPermissionGatePresented = true
        let activity = CodexActivity(kind: .notice, title: "Codex Mobile", detail: "Permission gate opened")
        state.lastActivity = activity
        return activity
    }

    public mutating func cancelPermissionGate() {
        state.isPermissionGatePresented = false
    }

    public mutating func apply(status: CodexRemoteControlStatusModel) {
        state.status = status
    }

    @discardableResult
    public mutating func refreshStatus(provider: any CodexRemoteControlProvider) async -> CodexActivity {
        do {
            state.status = try await provider.readStatus()
            let activity = CodexActivity(kind: .notice, title: "Remote control status", detail: state.status.statusLine)
            state.lastActivity = activity
            return activity
        } catch {
            return apply(error: error)
        }
    }

    @discardableResult
    public mutating func allow(provider: any CodexRemoteControlProvider) async -> CodexActivity {
        state.isPermissionGatePresented = false
        do {
            state.status = try await provider.enable()
            state.pairing = try await provider.startPairing()
            if let environmentID = state.status.environmentID {
                state.clients = try await provider.listClients(environmentID: environmentID)
            }
            let activity = CodexActivity(kind: .notice, title: "Codex Mobile enabled", detail: state.pairing.statusLabel)
            state.lastActivity = activity
            return activity
        } catch {
            return apply(error: error)
        }
    }

    @discardableResult
    public mutating func revoke(clientID: String, provider: any CodexRemoteControlProvider) async -> CodexActivity {
        guard let environmentID = state.status.environmentID else {
            let activity = CodexActivity(kind: .notice, title: "Remote control unavailable", detail: "No remote control environment is available.")
            state.lastActivity = activity
            return activity
        }
        do {
            try await provider.revokeClient(clientID: clientID, environmentID: environmentID)
            state.clients.removeAll { $0.id == clientID }
            let activity = CodexActivity(kind: .notice, title: "Device revoked", detail: clientID)
            state.lastActivity = activity
            return activity
        } catch {
            return apply(error: error)
        }
    }

    private mutating func apply(error: Error) -> CodexActivity {
        let message = (error as? LocalizedError)?.errorDescription?.nilIfBlank ?? String(describing: error)
        state.status = CodexRemoteControlStatusModel(kind: .error, serverName: state.status.serverName, errorMessage: message)
        state.pairing = CodexRemoteControlPairingModel(state: .error, errorMessage: message)
        let activity = CodexActivity(kind: .notice, title: "Remote control unavailable", detail: message)
        state.lastActivity = activity
        return activity
    }
}

public struct CodexAboutMetadata: Equatable, Sendable {
    public var appName: String
    public var version: String?
    public var build: String?
    public var releaseDate: String?
    public var copyright: String
    public var serverName: String?

    public init(
        appName: String = "Codex",
        version: String? = nil,
        build: String? = nil,
        releaseDate: String? = nil,
        copyright: String = "© OpenAI",
        serverName: String? = nil
    ) {
        self.appName = appName
        self.version = version?.nilIfBlank
        self.build = build?.nilIfBlank
        self.releaseDate = releaseDate?.nilIfBlank
        self.copyright = copyright
        self.serverName = serverName?.nilIfBlank
    }

    public init(bundle: Bundle, serverName: String? = nil) {
        let info = bundle.infoDictionary ?? [:]
        self.init(
            appName: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "Codex",
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            releaseDate: info["CodexReleaseDate"] as? String,
            copyright: (info["NSHumanReadableCopyright"] as? String) ?? "© OpenAI",
            serverName: serverName
        )
    }

    public var versionLine: String {
        var parts: [String] = []
        if let version {
            parts.append("Version \(version)")
        } else {
            parts.append("Version unavailable")
        }
        if let build {
            parts.append("Build \(build)")
        }
        if let releaseDate {
            parts.append("Released \(releaseDate)")
        } else {
            parts.append("Release date unavailable")
        }
        return parts.joined(separator: " • ")
    }
}
