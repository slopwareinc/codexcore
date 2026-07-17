import Foundation

/// Process and handshake configuration for one app-server session.
///
/// `Codex` always opts in to the alpha app-server API and always isolates the
/// subprocess under `codexHome`. Runtime state, requests, and observations are
/// owned by the resulting `CodexSession`; this value contains no mutable state.
public struct CodexConfig: Sendable {
    public static let isolatedAuthConfigOverride = #"cli_auth_credentials_store="file""#

    public let codexHome: CodexHome
    public let codexBinaryPath: String?
    public let launchArgumentsOverride: [String]?
    public let configOverrides: [String]
    public let cwd: String?
    public let environment: [String: String]
    public let clientName: String
    public let clientTitle: String?
    public let clientVersion: String
    public let capabilities: InitializeCapabilities
    public let reconnectPolicy: CodexReconnectPolicy
    public let maximumBufferedHandshakeFrames: Int
    public let maximumRetainedLoginCompletions: Int

    public init(
        codexHome: CodexHome = .default,
        codexBinaryPath: String? = nil,
        launchArgumentsOverride: [String]? = nil,
        configOverrides: [String] = [],
        cwd: String? = nil,
        environment: [String: String] = [:],
        clientName: String = "codex_swift_sdk",
        clientTitle: String? = "Codex Swift SDK",
        clientVersion: String = "1.0.0",
        capabilities: InitializeCapabilities = .init(
            experimentalAPI: true,
            requestAttestation: false
        ),
        reconnectPolicy: CodexReconnectPolicy = .init(),
        maximumBufferedHandshakeFrames: Int = 4_096,
        maximumRetainedLoginCompletions: Int = 256
    ) {
        precondition(maximumBufferedHandshakeFrames > 0)
        precondition(maximumRetainedLoginCompletions > 0)

        self.codexHome = codexHome
        self.codexBinaryPath = codexBinaryPath
        self.launchArgumentsOverride = launchArgumentsOverride

        // Credentials and every other mutable app-server artifact stay inside
        // the configured CodexCore home. The authoritative override is last.
        self.configOverrides = configOverrides.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("cli_auth_credentials_store")
        } + [Self.isolatedAuthConfigOverride]
        self.cwd = cwd

        var resolvedEnvironment = environment
        resolvedEnvironment[CodexHome.environmentKey] = codexHome.path
        self.environment = resolvedEnvironment
        self.clientName = clientName
        self.clientTitle = clientTitle
        self.clientVersion = clientVersion

        // This SDK intentionally targets the alpha app-server protocol. Do not
        // allow a caller-supplied capability value to silently select the old
        // notification/client architecture.
        var resolvedCapabilities = capabilities
        resolvedCapabilities.experimentalAPI = true
        resolvedCapabilities.optOutNotificationMethods =
            CodexNotificationOptOutPolicy.filtered(
                capabilities.optOutNotificationMethods
            )
        self.capabilities = resolvedCapabilities
        self.reconnectPolicy = reconnectPolicy
        self.maximumBufferedHandshakeFrames = maximumBufferedHandshakeFrames
        self.maximumRetainedLoginCompletions = maximumRetainedLoginCompletions
    }

    public var sessionConfiguration: CodexSessionConfiguration {
        .init(
            clientName: clientName,
            clientTitle: clientTitle,
            clientVersion: clientVersion,
            capabilities: capabilities,
            codexHome: codexHome,
            reconnectPolicy: reconnectPolicy,
            maximumBufferedHandshakeFrames: maximumBufferedHandshakeFrames,
            maximumRetainedLoginCompletions: maximumRetainedLoginCompletions
        )
    }

    /// Raw launch overrides may change the subcommand/stdio flags, but cannot
    /// bypass the SDK's isolated credential and configuration boundary.
    var appServerLaunchArguments: [String] {
        let configurationArguments = configOverrides.flatMap { ["--config", $0] }
        guard var arguments = launchArgumentsOverride else {
            return configurationArguments + ["app-server", "--listen", "stdio://"]
        }
        let insertionIndex = arguments.firstIndex(of: "app-server") ?? 0
        arguments.insert(contentsOf: configurationArguments, at: insertionIndex)
        return arguments
    }
}

public enum CodexSDKError: CodexError, Sendable, CustomStringConvertible, LocalizedError {
    case runtimeNotFound
    case invalidRuntimePath(String)
    case runtimeVersionProbeFailed(path: String, reason: String)
    case runtimeVersionMismatch(path: String, expected: String, actual: String)
    case invalidResponse(method: String, value: CodexJSONValue)
    case codexHomeMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .runtimeNotFound:
            "Codex runtime not found. Set CodexConfig.codexBinaryPath, CODEX_BINARY, or CODEX_APP_BUNDLE; install codex on PATH; or install Codex.app."
        case .invalidRuntimePath(let path):
            "Codex runtime not found at \(path)."
        case .runtimeVersionProbeFailed(let path, let reason):
            "Could not determine the Codex runtime version at \(path): \(reason)"
        case .runtimeVersionMismatch(let path, let expected, let actual):
            "Codex runtime at \(path) is \(actual); this SDK requires \(expected)."
        case .invalidResponse(let method, let value):
            "Invalid \(method) response: \(value)"
        case .codexHomeMismatch(let expected, let actual):
            "Codex app-server initialized with CODEX_HOME=\(actual), expected \(expected)."
        }
    }

    public var errorDescription: String? { description }
}

/// Production SDK facade for one ordered app-server session.
///
/// The facade owns process discovery and validates the isolated Codex home.
/// `CodexSession` is the sole mutable runtime owner: there is no parallel
/// client, notification router, or UI-shaped store behind this type.
public final class Codex: Sendable {
    public let session: CodexSession
    public let metadata: InitializeResponse
    public let codexHome: CodexHome

    public convenience init(
        config: CodexConfig = CodexConfig(),
        serverRequestHandler: CodexSessionServerRequestHandler? = nil
    ) async throws {
        let transport = try Self.makeDefaultTransport(config: config)
        try await self.init(
            transport: transport,
            config: config,
            serverRequestHandler: serverRequestHandler
        )
    }

    /// Creates and starts exactly one canonical session over an ordered frame
    /// transport. The initializer does not accept the legacy callback transport
    /// or a caller-provided store.
    public init(
        transport: any CodexFrameTransport,
        config: CodexConfig = CodexConfig(),
        serverRequestHandler: CodexSessionServerRequestHandler? = nil
    ) async throws {
        let session = CodexSession(
            transport: transport,
            configuration: config.sessionConfiguration,
            serverRequestHandler: serverRequestHandler
        )

        let metadata: InitializeResponse
        do {
            metadata = try await session.start()
        } catch CodexSessionError.codexHomeMismatch(let expected, let actual) {
            await session.stop()
            throw CodexSDKError.codexHomeMismatch(
                expected: expected,
                actual: actual
            )
        } catch {
            await session.stop()
            throw error
        }

        let reportedPath = metadata.codexHome
        let trimmedPath = reportedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentExpectedHome = CodexHome(path: config.codexHome.path)
        guard !trimmedPath.isEmpty,
              CodexHome(path: trimmedPath) == currentExpectedHome
        else {
            await session.stop()
            throw CodexSDKError.codexHomeMismatch(
                expected: config.codexHome.path,
                actual: reportedPath
            )
        }

        self.session = session
        self.metadata = metadata
        self.codexHome = config.codexHome
    }

    public func close() async {
        await session.stop()
    }

    /// Performs any generated ordinary app-server request. Lifecycle-sensitive
    /// thread and turn methods are intentionally available only through leases.
    public func perform<Response: Decodable & Sendable>(
        _ request: CodexAppServerRequest<Response>
    ) async throws -> Response {
        try await session.perform(request)
    }

    /// Starts an account login through the epoch-bound session API. Interactive
    /// modes return a handle whose completion cannot be confused with a reused
    /// login identifier from a later connection.
    public func startLogin(
        _ params: CodexSchemaLoginAccountParams
    ) async throws -> CodexLoginTransaction {
        try await session.startLogin(params)
    }

    /// Performs a generated request with bounded exponential backoff only for
    /// app-server overload and retry-limit responses.
    public func performWithRetryOnOverload<Response: Decodable & Sendable>(
        _ request: CodexAppServerRequest<Response>,
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(250),
        maxDelay: Duration = .seconds(2),
        jitterRatio: Double = 0.2
    ) async throws -> Response {
        try await retryOnOverload(
            maxAttempts: maxAttempts,
            initialDelay: initialDelay,
            maxDelay: maxDelay,
            jitterRatio: jitterRatio
        ) {
            try await self.session.perform(request)
        }
    }

    public func startThread(
        _ params: CodexSchemaThreadStartParams = .init()
    ) async throws -> CodexThreadLease {
        try await session.startThread(params)
    }

    public func resumeThread(
        _ params: CodexSchemaThreadResumeParams
    ) async throws -> CodexThreadLease {
        // The session seeds its history coordinator from this exact resume
        // response/cursor and returns only after all turn/item pages install.
        try await session.resumeThread(params)
    }

    public func forkThread(
        _ params: CodexSchemaThreadForkParams
    ) async throws -> CodexThreadLease {
        try await session.forkThread(params)
    }

    /// Retains an existing thread and lets the session's history coordinator
    /// reconcile it asynchronously. Use `resumeThread(_:)` when the caller must
    /// await the protocol response before continuing.
    public func retainThread(
        _ id: ThreadID,
        reason: ThreadLeaseReason = .explicitObserver("Codex facade")
    ) async -> CodexThreadLease {
        let revision = await session.canonicalSnapshot(
            scope: .thread(id, fields: .all)
        ).revision
        let token = await session.hydrateThreadHistory(id, reason: reason)
        return CodexThreadLease(
            id: id,
            startRevision: revision,
            responseRevision: revision,
            session: session,
            token: token
        )
    }

    private static func makeDefaultTransport(config: CodexConfig) throws -> CodexStdioTransport {
        let binaryURL = try resolveCodexBinary(config: config)

        return CodexStdioTransport(
            executableURL: binaryURL,
            arguments: config.appServerLaunchArguments,
            environment: config.environment,
            currentDirectoryURL: config.cwd.map { URL(fileURLWithPath: $0) },
            prepareForLaunch: {
                try config.codexHome.prepareForLaunch()
                try Self.verifyPinnedRuntime(at: binaryURL)
            }
        )
    }

    /// Verifies the resolved executable itself before the SDK starts an
    /// app-server. `InitializeResponse.userAgent` remains descriptive server
    /// metadata; protocol identity is pinned at the process-launch boundary.
    private static func verifyPinnedRuntime(at executableURL: URL) throws {
        let result: (status: Int32, output: String)
        do {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["--version"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            result = (
                process.terminationStatus,
                String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            throw CodexSDKError.runtimeVersionProbeFailed(
                path: executableURL.path,
                reason: String(describing: error)
            )
        }

        guard result.status == 0 else {
            let diagnostic = boundedRuntimeProbeDiagnostic(result.output)
            throw CodexSDKError.runtimeVersionProbeFailed(
                path: executableURL.path,
                reason: diagnostic.isEmpty
                    ? "`--version` exited with status \(result.status)."
                    : "`--version` exited with status \(result.status): \(diagnostic)"
            )
        }

        try validatePinnedRuntimeVersionOutput(
            result.output,
            executablePath: executableURL.path
        )
    }

    /// Internal for focused parser tests. The real CLI currently prints
    /// `codex-cli <version>`; line and whitespace normalization tolerates shell
    /// wrappers and harmless diagnostics without weakening the exact version.
    static func validatePinnedRuntimeVersionOutput(
        _ output: String,
        executablePath: String
    ) throws {
        let lines = output
            .split(whereSeparator: \Character.isNewline)
            .map { line in
                line.split(whereSeparator: \Character.isWhitespace)
                    .map(String.init)
            }

        if let components = lines.first(where: {
            $0.first == CodexPinnedRuntime.package
        }) {
            guard components.count >= 2 else {
                throw CodexSDKError.runtimeVersionProbeFailed(
                    path: executablePath,
                    reason: "`--version` did not include a version after \(CodexPinnedRuntime.package)."
                )
            }
            guard components[1] == CodexPinnedRuntime.version else {
                throw CodexSDKError.runtimeVersionMismatch(
                    path: executablePath,
                    expected: CodexPinnedRuntime.descriptor,
                    actual: "\(components[0]) \(components[1])"
                )
            }
            return
        }

        let diagnostic = boundedRuntimeProbeDiagnostic(output)
        guard !diagnostic.isEmpty else {
            throw CodexSDKError.runtimeVersionProbeFailed(
                path: executablePath,
                reason: "`--version` produced no version output."
            )
        }
        throw CodexSDKError.runtimeVersionProbeFailed(
            path: executablePath,
            reason: "unrecognized `--version` output: \(diagnostic)"
        )
    }

    private static func boundedRuntimeProbeDiagnostic(_ value: String) -> String {
        let normalized = value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return String(normalized.prefix(512))
    }

    /// Resolves the Codex runtime executable used to launch the local app-server.
    ///
    /// Precedence is explicit SDK config, `CODEX_BINARY`, `CODEX_BIN`, `codex`
    /// from `PATH`, then a macOS Codex app bundle.
    public static func resolveCodexBinary(config: CodexConfig = CodexConfig()) throws -> URL {
        let fileManager = FileManager.default

        if let path = config.codexBinaryPath {
            guard fileManager.isExecutableFile(atPath: path) else {
                throw CodexSDKError.invalidRuntimePath(path)
            }
            return URL(fileURLWithPath: path)
        }

        for key in ["CODEX_BINARY", "CODEX_BIN"] {
            guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { continue }
            guard fileManager.isExecutableFile(atPath: path) else {
                throw CodexSDKError.invalidRuntimePath(path)
            }
            return URL(fileURLWithPath: path)
        }

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":") {
            let candidate = String(directory) + "/codex"
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        for appBundleURL in codexAppBundleCandidates(fileManager: fileManager) {
            let candidate = appBundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent("codex")
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        throw CodexSDKError.runtimeNotFound
    }

    private static func codexAppBundleCandidates(fileManager: FileManager) -> [URL] {
        var candidates: [URL] = []
        var seenPaths: Set<String> = []

        func append(_ url: URL) {
            let standardizedPath = url.standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else { return }
            candidates.append(URL(fileURLWithPath: standardizedPath, isDirectory: true))
        }

        for key in ["CODEX_APP_BUNDLE", "CODEX_APP_BUNDLE_PATH"] {
            guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { continue }
            append(URL(fileURLWithPath: path, isDirectory: true))
        }

        #if os(macOS)
        for directory in fileManager.urls(
            for: .applicationDirectory,
            in: [.userDomainMask, .localDomainMask]
        ) {
            append(directory.appendingPathComponent("Codex.app", isDirectory: true))
        }
        #endif

        return candidates
    }
}
