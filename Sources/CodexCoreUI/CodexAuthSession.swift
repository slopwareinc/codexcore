import Foundation
import CodexCore

public struct CodexAuthCheckResult: Equatable, Sendable {
    public var shouldContinue: Bool
    public var activity: CodexActivity?

    public init(shouldContinue: Bool, activity: CodexActivity? = nil) {
        self.shouldContinue = shouldContinue
        self.activity = activity
    }
}

public struct CodexAuthSession: Equatable, Sendable {
    public private(set) var connectionState: CodexConnectionState
    public private(set) var isAuthenticated: Bool
    public private(set) var authLabel: String
    public private(set) var deviceCodeURL: String?
    public private(set) var deviceCode: String?

    public var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    public var isConnecting: Bool {
        if case .connecting = connectionState { return true }
        return false
    }

    public var connectionErrorMessage: String? {
        if case .failed(let message) = connectionState { return message }
        return nil
    }

    public var serverName: String? {
        if case .connected(let server) = connectionState { return server }
        return nil
    }

    public init(
        connectionState: CodexConnectionState = .disconnected,
        isAuthenticated: Bool = true,
        authLabel: String = "Checking auth",
        deviceCodeURL: String? = nil,
        deviceCode: String? = nil
    ) {
        self.connectionState = connectionState
        self.isAuthenticated = isAuthenticated
        self.authLabel = authLabel
        self.deviceCodeURL = deviceCodeURL
        self.deviceCode = deviceCode
    }

    @discardableResult
    public mutating func beginConnecting() -> Bool {
        switch connectionState {
        case .connecting, .connected:
            return false
        case .disconnected, .failed:
            connectionState = .connecting
            return true
        }
    }

    public mutating func connected(server: String) {
        connectionState = .connected(server: server)
    }

    public mutating func connectionFailed(message: String) -> CodexActivity {
        connectionState = .failed(message)
        return CodexActivity(kind: .notice, title: "Connection failed", detail: message)
    }

    public mutating func disconnected() -> CodexActivity {
        connectionState = .disconnected
        return CodexActivity(kind: .notice, title: "Disconnected", detail: "Closed app-server session")
    }

    public mutating func resetAuthentication() {
        isAuthenticated = true
        authLabel = "Checking auth"
        deviceCode = nil
        deviceCodeURL = nil
    }

    public mutating func applyAccount(_ response: GetAccountResponse) -> CodexAuthCheckResult {
        isAuthenticated = response.account != nil || !response.requiresOpenAIAuth
        if let account = response.account {
            authLabel = account.email.map { "\(account.type) · \($0)" } ?? account.type
            return CodexAuthCheckResult(
                shouldContinue: true,
                activity: CodexActivity(kind: .login, title: "Signed in", detail: authLabel)
            )
        }
        if response.requiresOpenAIAuth {
            authLabel = "Sign-in required"
            return CodexAuthCheckResult(
                shouldContinue: false,
                activity: CodexActivity(kind: .login, title: "Authentication required", detail: "Sign in to continue")
            )
        }
        authLabel = "Available"
        return CodexAuthCheckResult(shouldContinue: true)
    }

    public mutating func accountCheckSkipped(message: String) -> CodexActivity {
        authLabel = "Account check skipped"
        return CodexActivity(kind: .login, title: "Account check skipped", detail: message)
    }

    public mutating func apiKeyAccepted() -> CodexActivity {
        isAuthenticated = true
        authLabel = "OpenAI API key"
        deviceCode = nil
        deviceCodeURL = nil
        return CodexActivity(kind: .login, title: "API key accepted", detail: "Authentication updated")
    }

    public func apiKeyFailed(message: String) -> CodexActivity {
        CodexActivity(kind: .login, title: "API key login failed", detail: message)
    }

    public mutating func deviceCodeStarted(url: String, code: String) -> CodexActivity {
        deviceCodeURL = url
        deviceCode = code
        return CodexActivity(kind: .login, title: "Device login started", detail: "Code \(code)")
    }

    public mutating func deviceCodeCompleted() -> CodexActivity {
        isAuthenticated = true
        authLabel = "ChatGPT"
        deviceCode = nil
        deviceCodeURL = nil
        return CodexActivity(kind: .login, title: "Signed in with ChatGPT", detail: "Authentication updated")
    }

    public func deviceCodeEnded(message: String) -> CodexActivity {
        CodexActivity(kind: .login, title: "Device login ended", detail: message)
    }

    public func deviceCodeFailed(message: String) -> CodexActivity {
        CodexActivity(kind: .login, title: "Device login failed", detail: message)
    }
}
