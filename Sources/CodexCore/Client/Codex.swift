import Dispatch
import Darwin
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

/// A runtime that differs from the version the generated types were dumped from
/// but still sits inside the supported range. Hosts can surface this warning
/// without treating a compatible upgrade as a launch failure.
public struct CodexRuntimeVersionWarning: Sendable, Equatable, CustomStringConvertible {
    public let path: String
    public let expected: String
    public let actual: String

    public init(path: String, expected: String, actual: String) {
        self.path = path
        self.expected = expected
        self.actual = actual
    }

    public var description: String {
        "Codex runtime at \(path) is \(actual); this SDK pins \(expected). The patch version differs, but major.minor matches."
    }
}

private struct CodexSemanticVersion: Sendable, Hashable, Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ value: String) {
        let core = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
        let components = core.split(separator: ".")
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              major >= 0,
              minor >= 0,
              patch >= 0 else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var displayText: String { "\(major).\(minor).\(patch)" }
}

/// `CodexPinnedRuntime` records the exact runtime used to generate the protocol
/// types. CodexCore 0.12.0 accepts the 0.148 runtime floor and the generated
/// 0.149 line; callers of 0.149-only project and Bedrock methods must use 0.149.
public enum CodexSupportedRuntime {
    fileprivate static let minimumVersion = CodexSemanticVersion(major: 0, minor: 148, patch: 0)

    /// Oldest accepted `codex-cli` version, for diagnostics and documentation.
    public static var minimum: String { minimumVersion.displayText }

    public static var descriptor: String {
        "\(CodexPinnedRuntime.package) >= \(minimum) (types generated from \(CodexPinnedRuntime.version))"
    }
}

private func runtimeVersionMismatchComponent(expected: String, actual: String) -> String {
    let expectedVersion = CodexSemanticVersion(CodexPinnedRuntime.version)
    let actualVersion = actual.split(separator: " ").last.map(String.init)
        .flatMap(CodexSemanticVersion.init)

    guard let actualVersion else {
        return "runtime version"
    }
    if let expectedVersion, expectedVersion.major != actualVersion.major {
        return "major version"
    }
    if actualVersion < CodexSupportedRuntime.minimumVersion {
        return "minimum supported version"
    }
    return "runtime version"
}

private final class CodexRuntimeVersionWarningBox: @unchecked Sendable {
    private let lock = NSLock()
    private var warning: CodexRuntimeVersionWarning?

    func store(_ warning: CodexRuntimeVersionWarning?) {
        lock.withLock {
            self.warning = warning
        }
    }

    var value: CodexRuntimeVersionWarning? {
        lock.withLock { warning }
    }
}

private struct CodexRuntimeProbeCacheKey: Sendable, Hashable {
    let path: String
    let modificationDate: Date?
}

private enum CodexRuntimeProbeOutcome: Sendable {
    case success(CodexRuntimeVersionWarning?)
    case failure(CodexSDKError)
}

private final class CodexRuntimeProbeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [CodexRuntimeProbeCacheKey: CodexRuntimeProbeOutcome] = [:]

    func outcome(for key: CodexRuntimeProbeCacheKey) -> CodexRuntimeProbeOutcome? {
        lock.withLock { outcomes[key] }
    }

    func store(_ outcome: CodexRuntimeProbeOutcome, for key: CodexRuntimeProbeCacheKey) {
        lock.withLock {
            outcomes[key] = outcome
        }
    }
}

private struct CodexRuntimeResolutionCacheKey: Sendable, Hashable {
    let codexHomePath: String
    let codexHomeConfigModificationDate: Date?
    let path: String
    let shell: String?
    let appBundle: String?
    let appBundlePath: String?
}

private final class CodexRuntimeResolutionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [CodexRuntimeResolutionCacheKey: String] = [:]

    func path(for key: CodexRuntimeResolutionCacheKey) -> String? {
        lock.withLock { paths[key] }
    }

    func store(_ path: String, for key: CodexRuntimeResolutionCacheKey) {
        lock.withLock {
            paths[key] = path
        }
    }
}

private final class CodexResolvedPathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var path: String?

    func store(_ path: String) {
        lock.withLock {
            self.path = path
        }
    }

    var value: String? {
        lock.withLock { path }
    }
}

public enum CodexSDKError: CodexError, Sendable, CustomStringConvertible, LocalizedError {
    case runtimeNotFound
    case invalidRuntimePath(String)
    case invalidCodexCoreConfig(path: String, reason: String)
    case runtimeVersionProbeFailed(path: String, reason: String)
    case runtimeVersionMismatch(path: String, expected: String, actual: String)
    case invalidResponse(method: String, value: CodexJSONValue)
    case codexHomeMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .runtimeNotFound:
            return "Codex runtime not found. Set CodexConfig.codexBinaryPath or [codexcore].codex_binary_path in CODEX_HOME/config.toml; set CODEX_BINARY or CODEX_APP_BUNDLE; install codex on PATH; or install Codex.app."
        case .invalidRuntimePath(let path):
            return "Codex runtime not found at \(path)."
        case .invalidCodexCoreConfig(let path, let reason):
            return "Invalid CodexCore configuration at \(path): \(reason)"
        case .runtimeVersionProbeFailed(let path, let reason):
            return "Could not determine the Codex runtime version at \(path): \(reason)"
        case .runtimeVersionMismatch(let path, let expected, let actual):
            let mismatch = runtimeVersionMismatchComponent(
                expected: expected,
                actual: actual
            )
            return "Codex runtime at \(path) has a \(mismatch) mismatch: \(actual); this SDK requires \(expected)."
        case .invalidResponse(let method, let value):
            return "Invalid \(method) response: \(value)"
        case .codexHomeMismatch(let expected, let actual):
            return "Codex app-server initialized with CODEX_HOME=\(actual), expected \(expected)."
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
    public let runtimeVersionWarning: CodexRuntimeVersionWarning?

    private static let runtimeProbeCache = CodexRuntimeProbeCache()
    private static let runtimeResolutionCache = CodexRuntimeResolutionCache()

    public convenience init(
        config: CodexConfig = CodexConfig(),
        serverRequestHandler: CodexSessionServerRequestHandler? = nil
    ) async throws {
        let warningBox = CodexRuntimeVersionWarningBox()
        let transport = try Self.makeDefaultTransport(
            config: config,
            warningBox: warningBox
        )
        try await self.init(
            transport: transport,
            config: config,
            serverRequestHandler: serverRequestHandler,
            runtimeVersionWarningBox: warningBox
        )
    }

    /// Creates and starts exactly one canonical session over an ordered frame
    /// transport. The initializer does not accept the legacy callback transport
    /// or a caller-provided store.
    public convenience init(
        transport: any CodexFrameTransport,
        config: CodexConfig = CodexConfig(),
        serverRequestHandler: CodexSessionServerRequestHandler? = nil
    ) async throws {
        try await self.init(
            transport: transport,
            config: config,
            serverRequestHandler: serverRequestHandler,
            runtimeVersionWarningBox: nil
        )
    }

    private init(
        transport: any CodexFrameTransport,
        config: CodexConfig,
        serverRequestHandler: CodexSessionServerRequestHandler?,
        runtimeVersionWarningBox: CodexRuntimeVersionWarningBox?
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
        self.runtimeVersionWarning = runtimeVersionWarningBox?.value
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

    private static func makeDefaultTransport(
        config: CodexConfig,
        warningBox: CodexRuntimeVersionWarningBox? = nil
    ) throws -> CodexStdioTransport {
        let binaryURL = try resolveCodexBinary(config: config)

        return CodexStdioTransport(
            executableURL: binaryURL,
            arguments: config.appServerLaunchArguments,
            environment: config.environment,
            currentDirectoryURL: config.cwd.map { URL(fileURLWithPath: $0) },
            prepareForLaunch: {
                try config.codexHome.prepareForLaunch()
                let warning = try Self.verifyPinnedRuntime(at: binaryURL)
                warningBox?.store(warning)
            }
        )
    }

    /// Verifies the resolved executable itself before the SDK starts an
    /// app-server. `InitializeResponse.userAgent` remains descriptive server
    /// metadata; protocol identity is pinned at the process-launch boundary.
    private static func verifyPinnedRuntime(
        at executableURL: URL
    ) throws -> CodexRuntimeVersionWarning? {
        let key = CodexRuntimeProbeCacheKey(
            path: executableURL.path,
            modificationDate: runtimeModificationDate(at: executableURL)
        )
        if let outcome = runtimeProbeCache.outcome(for: key) {
            return try resolveRuntimeProbeOutcome(outcome)
        }

        let outcome: CodexRuntimeProbeOutcome
        do {
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

            outcome = .success(try validatePinnedRuntimeVersionOutput(
                result.output,
                executablePath: executableURL.path
            ))
        } catch let error as CodexSDKError {
            outcome = .failure(error)
        } catch {
            outcome = .failure(.runtimeVersionProbeFailed(
                path: executableURL.path,
                reason: String(describing: error)
            ))
        }

        runtimeProbeCache.store(outcome, for: key)
        return try resolveRuntimeProbeOutcome(outcome)
    }

    /// Internal for focused parser tests. The real CLI currently prints
    /// `codex-cli <version>`; line and whitespace normalization tolerates shell
    /// wrappers and harmless diagnostics. A patch-only difference is accepted
    /// and returned as a warning; major/minor differences remain hard failures.
    static func validatePinnedRuntimeVersionOutput(
        _ output: String,
        executablePath: String
    ) throws -> CodexRuntimeVersionWarning? {
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
            guard let expectedVersion = CodexSemanticVersion(CodexPinnedRuntime.version),
                  let actualVersion = CodexSemanticVersion(components[1]) else {
                throw CodexSDKError.runtimeVersionProbeFailed(
                    path: executablePath,
                    reason: "`--version` returned an unsupported semantic version: \(components[1])"
                )
            }
            // Accept every runtime from the supported floor through the
            // generated minor line. Newer minors require regeneration because
            // their protocol may add dispositions the handwritten adapters do
            // not classify yet.
            guard actualVersion.major == expectedVersion.major,
                  actualVersion >= CodexSupportedRuntime.minimumVersion,
                  actualVersion.minor <= expectedVersion.minor else {
                throw CodexSDKError.runtimeVersionMismatch(
                    path: executablePath,
                    expected: CodexSupportedRuntime.descriptor,
                    actual: "\(components[0]) \(components[1])"
                )
            }
            guard actualVersion == expectedVersion else {
                return CodexRuntimeVersionWarning(
                    path: executablePath,
                    expected: CodexPinnedRuntime.descriptor,
                    actual: "\(components[0]) \(components[1])"
                )
            }
            return nil
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

    private static func resolveRuntimeProbeOutcome(
        _ outcome: CodexRuntimeProbeOutcome
    ) throws -> CodexRuntimeVersionWarning? {
        switch outcome {
        case .success(let warning):
            return warning
        case .failure(let error):
            throw error
        }
    }

    private static func runtimeModificationDate(at executableURL: URL) -> Date? {
        try? FileManager.default.attributesOfItem(
            atPath: executableURL.path
        )[.modificationDate] as? Date
    }

    /// Resolves the Codex runtime executable used to launch the local app-server.
    ///
    /// Precedence is explicit SDK config, the isolated home's
    /// `[codexcore].codex_binary_path` pin, `CODEX_BINARY`, `CODEX_BIN`, `codex`
    /// from `PATH`, standard Homebrew locations, a login-shell lookup, then a
    /// macOS Codex app bundle. Discovered paths are cached while their inputs
    /// remain unchanged.
    public static func resolveCodexBinary(config: CodexConfig = CodexConfig()) throws -> URL {
        try resolveCodexBinary(
            config: config,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func resolveCodexBinary(
        config: CodexConfig,
        environment: [String: String],
        fileManager: FileManager = .default
    ) throws -> URL {
        if let path = config.codexBinaryPath {
            guard fileManager.isExecutableFile(atPath: path) else {
                throw CodexSDKError.invalidRuntimePath(path)
            }
            return URL(fileURLWithPath: path)
        }

        if let path = try codexCoreRuntimePath(in: config.codexHome.configFileURL) {
            guard fileManager.isExecutableFile(atPath: path) else {
                throw CodexSDKError.invalidRuntimePath(path)
            }
            return URL(fileURLWithPath: path)
        }

        for key in ["CODEX_BINARY", "CODEX_BIN"] {
            guard let path = environment[key], !path.isEmpty else { continue }
            guard fileManager.isExecutableFile(atPath: path) else {
                throw CodexSDKError.invalidRuntimePath(path)
            }
            return URL(fileURLWithPath: path)
        }

        let cacheKey = CodexRuntimeResolutionCacheKey(
            codexHomePath: config.codexHome.path,
            codexHomeConfigModificationDate: runtimeModificationDate(
                at: config.codexHome.configFileURL
            ),
            path: environment["PATH"] ?? "",
            shell: environment["SHELL"],
            appBundle: environment["CODEX_APP_BUNDLE"],
            appBundlePath: environment["CODEX_APP_BUNDLE_PATH"]
        )
        if let cachedPath = runtimeResolutionCache.path(for: cacheKey),
           fileManager.isExecutableFile(atPath: cachedPath) {
            return URL(fileURLWithPath: cachedPath)
        }

        let pathValue = environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":") {
            let candidate = String(directory) + "/codex"
            if fileManager.isExecutableFile(atPath: candidate) {
                return cacheResolvedRuntimePath(candidate, for: cacheKey)
            }
        }

        // The interactive shell reflects the PATH the user actually configured
        // (asdf, nvm, a custom Homebrew prefix), so it outranks the fixed
        // candidates below, which exist only as a last resort when the probe
        // fails or the shell startup files are broken.
        if let candidate = loginShellCodexPath(
            environment: environment,
            fileManager: fileManager
        ) {
            return cacheResolvedRuntimePath(candidate, for: cacheKey)
        }

        for directory in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = directory + "/codex"
            if fileManager.isExecutableFile(atPath: candidate) {
                return cacheResolvedRuntimePath(candidate, for: cacheKey)
            }
        }

        for appBundleURL in codexAppBundleCandidates(
            fileManager: fileManager,
            environment: environment
        ) {
            let candidate = appBundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent("codex")
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return cacheResolvedRuntimePath(candidate, for: cacheKey)
            }
        }

        throw CodexSDKError.runtimeNotFound
    }

    private static func cacheResolvedRuntimePath(
        _ path: String,
        for key: CodexRuntimeResolutionCacheKey
    ) -> URL {
        runtimeResolutionCache.store(path, for: key)
        return URL(fileURLWithPath: path)
    }

    /// Finder-launched apps do not inherit the user's interactive PATH. A
    /// bounded login-shell probe recovers shell-managed paths without allowing
    /// a broken shell startup file to hold up app launch indefinitely.
    private static func loginShellCodexPath(
        environment: [String: String],
        fileManager: FileManager
    ) -> String? {
        var shells: [String] = []
        if let configuredShell = environment["SHELL"], !configuredShell.isEmpty {
            shells.append(configuredShell)
        }
        shells.append(contentsOf: ["/bin/zsh", "/bin/bash"])

        var seenShells: Set<String> = []
        for shell in shells where seenShells.insert(shell).inserted {
            guard fileManager.isExecutableFile(atPath: shell) else { continue }
            if let path = runLoginShellLookup(
                shell: shell,
                environment: environment
            ) {
                return path
            }
        }
        return nil
    }

    /// A login shell sources the user's full startup files, so the budget has to
    /// cover a realistic `nvm`/`oh-my-zsh` profile on a cold spawn. It stays
    /// short enough that a wedged shell cannot hold up launch, and the resolved
    /// path is cached so the cost is paid once.
    private static let loginShellLookupTimeout = DispatchTimeInterval.milliseconds(2000)

    private static func runLoginShellLookup(
        shell: String,
        environment: [String: String]
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v codex"]
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            return nil
        }

        let result = CodexResolvedPathBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               let line = String(data: data, encoding: .utf8)?
                .split(whereSeparator: \Character.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: {
                    !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0)
                }),
               FileManager.default.isExecutableFile(atPath: line) {
                result.store(line)
            }
            finished.signal()
        }

        guard finished.wait(timeout: .now() + loginShellLookupTimeout) == .success else {
            if process.isRunning {
                process.terminate()
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            _ = finished.wait(timeout: .now() + .milliseconds(100))
            return nil
        }
        return result.value
    }

    /// Reads only CodexCore's namespaced runtime pin. The remainder of the
    /// shared TOML file belongs to app-server and is intentionally untouched.
    static func codexCoreRuntimePath(in configURL: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }

        let contents: String
        do {
            contents = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            throw CodexSDKError.invalidCodexCoreConfig(
                path: configURL.path,
                reason: "could not read the file: \(error.localizedDescription)"
            )
        }

        var isCodexCoreTable = false
        for (offset, rawLine) in contents.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("[") {
                isCodexCoreTable = line == "[codexcore]"
                continue
            }
            guard isCodexCoreTable,
                  let equals = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "codex_binary_path" else { continue }

            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.first == "\"",
                  let closingQuote = value.dropFirst().firstIndex(of: "\"") else {
                throw CodexSDKError.invalidCodexCoreConfig(
                    path: configURL.path,
                    reason: "line \(offset + 1): codex_binary_path must be a double-quoted string"
                )
            }
            let path = String(value[value.index(after: value.startIndex)..<closingQuote])
            let suffix = value[value.index(after: closingQuote)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard suffix.isEmpty || suffix.hasPrefix("#"), path.hasPrefix("/") else {
                throw CodexSDKError.invalidCodexCoreConfig(
                    path: configURL.path,
                    reason: "line \(offset + 1): codex_binary_path must contain only an absolute path"
                )
            }
            return path
        }
        return nil
    }

    private static func codexAppBundleCandidates(
        fileManager: FileManager,
        environment: [String: String]
    ) -> [URL] {
        var candidates: [URL] = []
        var seenPaths: Set<String> = []

        func append(_ url: URL) {
            let standardizedPath = url.standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else { return }
            candidates.append(URL(fileURLWithPath: standardizedPath, isDirectory: true))
        }

        for key in ["CODEX_APP_BUNDLE", "CODEX_APP_BUNDLE_PATH"] {
            guard let path = environment[key], !path.isEmpty else { continue }
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
