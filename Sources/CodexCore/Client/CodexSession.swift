import Foundation

/// Capability-boundary policy for notifications the app-server may suppress.
/// The allowlist is intentionally closed: new protocol notifications remain
/// enabled until their state semantics are explicitly classified.
enum CodexNotificationOptOutPolicy {
    static func filtered(_ requested: [String]?) -> [String]? {
        guard let requested else { return nil }
        var seen = Set<CodexAppServerNotificationMethod>()
        return requested.compactMap { rawMethod in
            guard let method = CodexAppServerNotificationMethod(rawValue: rawMethod),
                  maySuppress(method),
                  seen.insert(method).inserted else {
                return nil
            }
            return method.rawValue
        }
    }

    static func maySuppress(_ method: CodexAppServerNotificationMethod) -> Bool {
        switch method {
        // Only bounded diagnostic metadata is optional. State, request
        // resolution, and operation channels are all session-owned behavior.
        case .warning, .guardianWarning, .deprecationNotice, .configWarning,
             .windowsWorldWritableWarning:
            true

        // All consumed and future methods stay enabled by default.
        default:
            false
        }
    }
}

// MARK: - Public session interface

public enum CodexSessionLifecycle: Sendable, Equatable {
    case stopped
    case connecting(attempt: Int)
    case initializing(connectionEpoch: UInt64)
    case ready(connectionEpoch: UInt64)
    case reconnecting(afterConnectionEpoch: UInt64?, attempt: Int)
    case closing

    public var connectionEpoch: UInt64? {
        switch self {
        case .initializing(let epoch), .ready(let epoch): epoch
        case .reconnecting(let epoch, _): epoch
        case .stopped, .connecting, .closing: nil
        }
    }
}

public struct CodexReconnectPolicy: Sendable, Equatable {
    public var isEnabled: Bool
    public var initialDelayMilliseconds: UInt64
    public var maximumDelayMilliseconds: UInt64
    public var multiplier: Double

    public init(
        isEnabled: Bool = true,
        initialDelayMilliseconds: UInt64 = 250,
        maximumDelayMilliseconds: UInt64 = 5_000,
        multiplier: Double = 2
    ) {
        precondition(initialDelayMilliseconds <= maximumDelayMilliseconds)
        precondition(multiplier >= 1)
        self.isEnabled = isEnabled
        self.initialDelayMilliseconds = initialDelayMilliseconds
        self.maximumDelayMilliseconds = maximumDelayMilliseconds
        self.multiplier = multiplier
    }

    public static let disabled = Self(
        isEnabled: false,
        initialDelayMilliseconds: 0,
        maximumDelayMilliseconds: 0
    )

    fileprivate func delayMilliseconds(forAttempt attempt: Int) -> UInt64 {
        guard attempt > 1, initialDelayMilliseconds > 0 else {
            return attempt > 0 ? initialDelayMilliseconds : 0
        }
        let exponent = Double(attempt - 1)
        let delay = Double(initialDelayMilliseconds) * pow(multiplier, exponent)
        return min(maximumDelayMilliseconds, UInt64(min(delay, Double(UInt64.max))))
    }
}

public struct CodexSessionConfiguration: Sendable, Equatable {
    public var clientName: String
    public var clientTitle: String?
    public var clientVersion: String
    public var capabilities: InitializeCapabilities
    /// Expected server filesystem namespace. `CodexConfig` always supplies
    /// this; `nil` is reserved for externally managed/in-memory transports.
    public var codexHome: CodexHome?
    public var reconnectPolicy: CodexReconnectPolicy
    public var maximumBufferedHandshakeFrames: Int
    public var maximumRetainedLoginCompletions: Int
    /// Warm canonical transcript details that were materialized without an
    /// owning lease. Lease-owned threads are never counted or evicted here;
    /// the last successfully unsubscribed lease is evicted immediately.
    public var maximumRetainedUnleasedThreadDetails: Int

    public init(
        clientName: String = "CodexCore",
        clientTitle: String? = "CodexCore",
        clientVersion: String = "0.1.0",
        capabilities: InitializeCapabilities = .init(
            experimentalAPI: true,
            requestAttestation: false
        ),
        codexHome: CodexHome? = nil,
        reconnectPolicy: CodexReconnectPolicy = .init(),
        maximumBufferedHandshakeFrames: Int = 4_096,
        maximumRetainedLoginCompletions: Int = 256,
        maximumRetainedUnleasedThreadDetails: Int = 8
    ) {
        precondition(maximumBufferedHandshakeFrames > 0)
        precondition(maximumRetainedLoginCompletions > 0)
        precondition(maximumRetainedUnleasedThreadDetails >= 0)
        self.clientName = clientName
        self.clientTitle = clientTitle
        self.clientVersion = clientVersion
        var resolvedCapabilities = capabilities
        resolvedCapabilities.experimentalAPI = true
        resolvedCapabilities.optOutNotificationMethods =
            CodexNotificationOptOutPolicy.filtered(
                capabilities.optOutNotificationMethods
            )
        self.capabilities = resolvedCapabilities
        self.codexHome = codexHome
        self.reconnectPolicy = reconnectPolicy
        self.maximumBufferedHandshakeFrames = maximumBufferedHandshakeFrames
        self.maximumRetainedLoginCompletions = maximumRetainedLoginCompletions
        self.maximumRetainedUnleasedThreadDetails = maximumRetainedUnleasedThreadDetails
    }
}

public enum CodexSessionError: Error, Sendable, Equatable, LocalizedError {
    case notReady(CodexSessionLifecycle)
    case closed
    case connectionFailed(String)
    case connectionLost(connectionEpoch: UInt64, message: String)
    case protocolViolation(String)
    case codexHomePreparationFailed(CodexHomePreparationError)
    case codexHomeMismatch(expected: String, actual: String)
    case handshakeBufferOverflow(limit: Int)
    case requestIdentifierExhausted
    case stateCommitFailed(String)
    case historyReconciliationFailed(threadID: ThreadID, message: String)
    case unknownServerRequest(CodexServerRequestKey)
    case anonymousLoginAlreadyInProgress(connectionEpoch: UInt64)
    case loginCancellationNotFound(CodexLoginKey)
    case loginCancellationDidNotCancel(CodexLoginKey)

    public var errorDescription: String? {
        switch self {
        case .notReady(let lifecycle):
            "Codex session is not ready (\(lifecycle))."
        case .closed:
            "Codex session is closed."
        case .connectionFailed(let message):
            "Codex connection failed: \(message)"
        case .connectionLost(let epoch, let message):
            "Codex connection epoch \(epoch) ended: \(message)"
        case .protocolViolation(let message):
            "Codex app-server protocol violation: \(message)"
        case .codexHomePreparationFailed(let error):
            error.localizedDescription
        case .codexHomeMismatch(let expected, let actual):
            "Codex app-server initialized with CODEX_HOME=\(actual), expected \(expected)."
        case .handshakeBufferOverflow(let limit):
            "More than \(limit) frames arrived before initialization completed."
        case .requestIdentifierExhausted:
            "The JSON-RPC client request identifier space is exhausted."
        case .stateCommitFailed(let message):
            "Canonical state commit failed: \(message)"
        case .historyReconciliationFailed(let threadID, let message):
            "History reconciliation for \(threadID) failed: \(message)"
        case .unknownServerRequest(let key):
            "No server request exists for epoch \(key.connectionEpoch), id \(key.requestID)."
        case .anonymousLoginAlreadyInProgress(let epoch):
            "Connection epoch \(epoch) already has an unresolved anonymous login."
        case .loginCancellationNotFound(let key):
            "The app-server no longer recognizes login attempt \(key)."
        case .loginCancellationDidNotCancel(let key):
            "Login attempt \(key) completed successfully before cancellation took effect."
        }
    }
}

public typealias CodexLoginCompletion = CodexSchemaAccountLoginCompletedNotification

public enum CodexLoginIdentity: Sendable, Hashable, Codable {
    case identified(String)
    case anonymous

    public var loginID: String? {
        guard case .identified(let loginID) = self else { return nil }
        return loginID
    }
}

/// Exact identity for one login transaction. Identifiers may be reused after
/// reconnect, and anonymous completions carry `loginId: null`, so both the
/// connection epoch and explicit identity kind participate in correlation.
public struct CodexLoginKey: Sendable, Hashable, Codable {
    public let connectionEpoch: UInt64
    public let identity: CodexLoginIdentity

    public init(connectionEpoch: UInt64, loginID: String) {
        self.connectionEpoch = connectionEpoch
        self.identity = .identified(loginID)
    }

    public init(connectionEpoch: UInt64, identity: CodexLoginIdentity) {
        self.connectionEpoch = connectionEpoch
        self.identity = identity
    }

    public var loginID: String? { identity.loginID }
}

/// Handle for an interactive login whose terminal fact arrives as an
/// `account/login/completed` notification on the response's connection epoch.
public struct CodexLoginAttempt: Sendable {
    public let key: CodexLoginKey
    public let response: CodexSchemaLoginAccountResponse

    private let session: CodexSession

    init(
        key: CodexLoginKey,
        response: CodexSchemaLoginAccountResponse,
        session: CodexSession
    ) {
        self.key = key
        self.response = response
        self.session = session
    }

    public func completion() async throws -> CodexLoginCompletion {
        try await session.awaitLogin(key)
    }

    /// Cancels this exact identified login and waits for its later
    /// `success: false` terminal notification.
    public func cancel() async throws -> CodexLoginCompletion {
        try await session.cancelLogin(key)
    }
}

/// Handle for login modes whose terminal notification carries `loginId: null`.
/// The protocol has no cancellation request for anonymous transactions.
public struct CodexAnonymousLoginAttempt: Sendable {
    public let key: CodexLoginKey
    public let response: CodexSchemaLoginAccountResponse

    private let session: CodexSession

    init(
        key: CodexLoginKey,
        response: CodexSchemaLoginAccountResponse,
        session: CodexSession
    ) {
        precondition(key.identity == .anonymous)
        self.key = key
        self.response = response
        self.session = session
    }

    public func completion() async throws -> CodexLoginCompletion {
        try await session.awaitLogin(key)
    }
}

public enum CodexLoginTransaction: Sendable {
    case identified(CodexLoginAttempt)
    case anonymous(CodexAnonymousLoginAttempt)

    public var response: CodexSchemaLoginAccountResponse {
        switch self {
        case .identified(let attempt): attempt.response
        case .anonymous(let attempt): attempt.response
        }
    }

    public func completion() async throws -> CodexLoginCompletion {
        switch self {
        case .identified(let attempt): try await attempt.completion()
        case .anonymous(let attempt): try await attempt.completion()
        }
    }
}

public struct CodexSessionStateSnapshot: Sendable, Equatable {
    public let stateRevision: StateRevision
    public let canonical: CanonicalStateSnapshot
    public let serverRequests: CodexPendingInteractionSnapshotBatch
    public let lifecycle: CodexSessionLifecycle

    public init(
        stateRevision: StateRevision,
        canonical: CanonicalStateSnapshot,
        serverRequests: CodexPendingInteractionSnapshotBatch,
        lifecycle: CodexSessionLifecycle
    ) {
        self.stateRevision = stateRevision
        self.canonical = canonical
        self.serverRequests = serverRequests
        self.lifecycle = lifecycle
    }
}

/// Atomic terminal projection captured at one canonical-state revision.
public struct CodexTerminalTurn: Sendable, Equatable {
    public let revision: StateRevision
    public let turn: CanonicalTurn
    public let items: [CanonicalItem]

    public init(
        revision: StateRevision,
        turn: CanonicalTurn,
        items: [CanonicalItem]
    ) {
        self.revision = revision
        self.turn = turn
        self.items = items
    }
}

public protocol CodexStateObserving: Actor {
    func canonicalSnapshot(scope: StateObservationScope) -> CanonicalStateSnapshot
    func observe(
        scope: StateObservationScope
    ) -> StateSnapshotObservation<CanonicalStateSnapshot>
    func cancelObservation(_ observationID: StateObservationID)
}

public protocol CodexSessionStateObserving: CodexStateObserving {
    func sessionStateSnapshot(
        scope: StateObservationScope
    ) -> CodexSessionStateSnapshot
    func observeSessionState(
        scope: StateObservationScope
    ) -> StateSnapshotObservation<CodexSessionStateSnapshot>
}

/// Lightweight thread catalogue observation for sidebar/status consumers.
public protocol CodexThreadIndexObserving: CodexStateObserving {
    func threadIndexSnapshot() -> CanonicalThreadIndexSnapshot
    func observeThreadIndex() -> StateSnapshotObservation<CanonicalThreadIndexSnapshot>
}

public extension CodexSessionStateObserving {
    func sessionStateSnapshot() -> CodexSessionStateSnapshot {
        sessionStateSnapshot(scope: .all)
    }

    func observeSessionState() -> StateSnapshotObservation<CodexSessionStateSnapshot> {
        observeSessionState(scope: .all)
    }
}

public extension CodexStateObserving {
    func canonicalSnapshot() -> CanonicalStateSnapshot {
        canonicalSnapshot(scope: .all)
    }

    func observe() -> StateSnapshotObservation<CanonicalStateSnapshot> {
        observe(scope: .all)
    }
}

public typealias CodexSessionServerRequestHandler = @Sendable (
    CodexParsedServerRequest
) async -> CodexServerRequestHandlerDecision

// MARK: - Scoped snapshot projection

public extension CanonicalStateSnapshot {
    /// Narrows entity collections without changing the snapshot revision.
    /// Field masks remain invalidation filters; canonical records are never
    /// partially copied into a second, lossy model.
    func scoped(to scope: StateObservationScope) -> CanonicalStateSnapshot {
        switch scope.entities {
        case .all:
            return self

        case .global:
            return CanonicalStateSnapshot(
                revision: revision,
                account: account,
                mcpServerStartupStatuses: mcpServerStartupStatuses
            )

        case .threads(let selectedThreadIDs):
            let scopedThreads = threads.filter { selectedThreadIDs.contains($0.key) }
            let scopedTurns = turns.filter { selectedThreadIDs.contains($0.key.threadID) }
            let scopedItems = items.filter { selectedThreadIDs.contains($0.key.threadID) }
            let scopedIntents = submissionIntents.filter {
                selectedThreadIDs.contains($0.value.threadID)
            }
            return CanonicalStateSnapshot(
                revision: revision,
                account: account,
                mcpServerStartupStatuses: mcpServerStartupStatuses,
                threadOrder: threadOrder.filter(selectedThreadIDs.contains),
                threads: scopedThreads,
                turns: scopedTurns,
                items: scopedItems,
                submissionIntents: scopedIntents
            )

        case .turns(let selectedTurnKeys):
            let selectedThreadIDs = Set(selectedTurnKeys.map(\.threadID))
            var scopedThreads = threads.filter { selectedThreadIDs.contains($0.key) }
            for (threadID, var thread) in scopedThreads {
                thread.turnOrder = thread.turnOrder.filter {
                    selectedTurnKeys.contains(.init(threadID: threadID, turnID: $0))
                }
                scopedThreads[threadID] = thread
            }
            let scopedTurns = turns.filter { selectedTurnKeys.contains($0.key) }
            let scopedItems = items.filter { selectedTurnKeys.contains($0.key.turnKey) }
            let scopedIntents = submissionIntents.filter { _, intent in
                guard let turnID = intent.expectedTurnID else { return false }
                return selectedTurnKeys.contains(.init(
                    threadID: intent.threadID,
                    turnID: turnID
                ))
            }
            return CanonicalStateSnapshot(
                revision: revision,
                account: account,
                mcpServerStartupStatuses: mcpServerStartupStatuses,
                threadOrder: threadOrder.filter(selectedThreadIDs.contains),
                threads: scopedThreads,
                turns: scopedTurns,
                items: scopedItems,
                submissionIntents: scopedIntents
            )

        case .items(let selectedItemKeys):
            let selectedTurnKeys = Set(selectedItemKeys.map(\.turnKey))
            let selectedThreadIDs = Set(selectedItemKeys.map(\.threadID))
            var scopedThreads = threads.filter { selectedThreadIDs.contains($0.key) }
            for (threadID, var thread) in scopedThreads {
                thread.turnOrder = thread.turnOrder.filter {
                    selectedTurnKeys.contains(.init(threadID: threadID, turnID: $0))
                }
                scopedThreads[threadID] = thread
            }
            var scopedTurns = turns.filter { selectedTurnKeys.contains($0.key) }
            for (turnKey, var turn) in scopedTurns {
                turn.itemOrder = turn.itemOrder.filter {
                    selectedItemKeys.contains(.init(
                        threadID: turnKey.threadID,
                        turnID: turnKey.turnID,
                        itemID: $0
                    ))
                }
                scopedTurns[turnKey] = turn
            }
            return CanonicalStateSnapshot(
                revision: revision,
                account: account,
                mcpServerStartupStatuses: mcpServerStartupStatuses,
                threadOrder: threadOrder.filter(selectedThreadIDs.contains),
                threads: scopedThreads,
                turns: scopedTurns,
                items: items.filter { selectedItemKeys.contains($0.key) }
            )
        }
    }
}

// MARK: - Sole ordered session actor

struct CodexSessionCallResult: Sendable {
    let value: CodexJSONValue
    let startRevision: StateRevision
    let responseRevision: StateRevision
    let responseCursor: CodexWireCursor
    let threadLeaseToken: ThreadLeaseToken?
}

public actor CodexSession:
    CodexSessionStateObserving,
    CodexThreadIndexObserving,
    CodexServerRequestInboxObserving
{
    private struct ClientRequestKey: Sendable, Hashable {
        let connectionEpoch: UInt64
        let id: CodexJSONRPCID
    }

    private struct PendingClientRequest {
        let key: ClientRequestKey
        let context: ProtocolResponseContext
        let startRevision: StateRevision
        let submissionIntentID: SubmissionIntentID?
        let resumeHistoryReason: ThreadLeaseReason?
        let outboundToken: UInt64
        let reducesResponse: Bool
        var writeAttempted: Bool
        var continuation: CheckedContinuation<CodexSessionCallResult, Error>?
    }

    private enum OutboundCorrelation: Sendable {
        case clientRequest(ClientRequestKey)
        case serverRequest(CodexServerRequestKey)
    }

    private struct OutboundFrame: Sendable {
        let token: UInt64
        let connectionEpoch: UInt64
        let correlation: OutboundCorrelation
        let data: Data
    }

    private struct BufferedEnvelope: Sendable {
        let cursor: CodexWireCursor
        let envelope: CodexJSONRPCEnvelope
    }

    private struct TerminalWaiter {
        let token: ThreadLeaseToken
        let continuation: CheckedContinuation<CodexTerminalTurn, Error>
    }

    private struct HistoryWaiter {
        let connectionEpoch: UInt64?
        let continuation: CheckedContinuation<CanonicalHistoryState, Error>
    }

    private enum ReaderTermination: Sendable {
        case ended
        case failed(String)

        var message: String {
            switch self {
            case .ended: "Transport frame stream ended"
            case .failed(let message): message
            }
        }
    }

    private let transport: any CodexFrameTransport
    private let configuration: CodexSessionConfiguration
    private let serverRequestHandler: CodexSessionServerRequestHandler?
    private let reconnectSleep: @Sendable (UInt64) async -> Void

    private var graph = CanonicalStateGraph()
    private var reducer = CanonicalStateReducer()
    private let adapter = ProtocolStateAdapter()
    private let observations = ObservationHub()
    private var interactions = CodexInteractionInbox()
    private var serverRequestTasks: [CodexServerRequestKey: Task<Void, Never>] = [:]
    private var serverRequestThreadLeases: [CodexServerRequestKey: ThreadLeaseToken] = [:]
    private var leases = ThreadLeaseRegistry()
    private var history = PaginatedHistoryCoordinator()
    private var diagnostics = CodexProtocolDiagnosticRing()
    private var commandOutputs = CodexCommandOutputRouter()
    private var skillsChanges = CodexSkillsChangeObserverHub()

    public private(set) var lifecycle: CodexSessionLifecycle = .stopped {
        didSet {
            guard oldValue != lifecycle else { return }
            try? commitSessionInvalidation(fields: .connection)
        }
    }
    public private(set) var initializeResponse: InitializeResponse?

    private var shouldRun = false
    private var coordinatorGeneration: UInt64 = 0
    private var coordinatorTask: Task<Void, Never>?
    private var readerTask: Task<ReaderTermination, Never>?
    private var activeConnectionEpoch: UInt64?
    private var nextConnectionEpoch: UInt64 = 1
    private var nextWireOrdinal: UInt64 = 0
    private var nextClientRequestID: Int64 = 1
    private var nextOutboundToken: UInt64 = 1
    private var nextWaiterID: UInt64 = 1
    private var nextSubmissionOrdinal: UInt64 = 1
    private var reconnectAttempt = 0
    private var terminalErrorByConnectionEpoch: [UInt64: Error] = [:]

    private var pendingClientRequests: [ClientRequestKey: PendingClientRequest] = [:]
    private var handshakeRequestKey: ClientRequestKey?
    private var bufferedHandshakeEnvelopes: [BufferedEnvelope] = []
    private var outboundFrames: [OutboundFrame] = []
    private var outboundDrainTask: Task<Void, Never>?
    private var outboundWriteInFlightToken: UInt64?
    private var leaseEffectQueue: [ThreadLeaseEffect] = []
    private var leaseEffectDrainTask: Task<Void, Never>?
    private var historyEffectQueue: [PaginatedHistoryEffect] = []
    private var historyEffectDrainTask: Task<Void, Never>?
    private var historyRequestTasks: [PaginatedHistoryRequestID: Task<Void, Never>] = [:]
    private var startWaiters: [UInt64: CheckedContinuation<InitializeResponse, Error>] = [:]
    private var terminalWaiters: [TurnKey: [UInt64: TerminalWaiter]] = [:]
    private var historyWaiters: [ThreadID: [UInt64: HistoryWaiter]] = [:]
    private var loginWaiters: [CodexLoginKey: [UInt64: CheckedContinuation<CodexLoginCompletion, Error>]] = [:]
    private var retainedLoginCompletions: [CodexLoginKey: CodexLoginCompletion] = [:]
    private var retainedLoginOrder: [CodexLoginKey] = []
    private var activeLoginKeys: Set<CodexLoginKey> = []
    private var anonymousLoginRequestEpochs: Set<UInt64> = []
    private var resumeGenerationByThread: [ThreadID: UInt64] = [:]
    private var threadAttentionRevisions: [ThreadID: StateRevision] = [:]
    private var unleasedThreadDetailLRU: [ThreadID] = []

    public init(
        transport: any CodexFrameTransport,
        configuration: CodexSessionConfiguration = .init(),
        serverRequestHandler: CodexSessionServerRequestHandler? = nil
    ) {
        self.transport = transport
        self.configuration = configuration
        self.serverRequestHandler = serverRequestHandler
        self.reconnectSleep = { milliseconds in
            guard milliseconds > 0 else { return }
            try? await Task.sleep(for: .milliseconds(Int64(milliseconds)))
        }
    }

    init(
        transport: any CodexFrameTransport,
        configuration: CodexSessionConfiguration = .init(),
        serverRequestHandler: CodexSessionServerRequestHandler? = nil,
        reconnectSleep: @escaping @Sendable (UInt64) async -> Void
    ) {
        self.transport = transport
        self.configuration = configuration
        self.serverRequestHandler = serverRequestHandler
        self.reconnectSleep = reconnectSleep
    }

    deinit {
        coordinatorTask?.cancel()
        readerTask?.cancel()
        outboundDrainTask?.cancel()
        leaseEffectDrainTask?.cancel()
        historyEffectDrainTask?.cancel()
        for task in historyRequestTasks.values {
            task.cancel()
        }
        for task in serverRequestTasks.values {
            task.cancel()
        }
    }

    public func start() async throws -> InitializeResponse {
        if case .ready = lifecycle, let initializeResponse {
            return initializeResponse
        }
        guard !Task.isCancelled else { throw CancellationError() }
        if case .closing = lifecycle { throw CodexSessionError.closed }

        shouldRun = true
        ensureCoordinator()
        let waiterID = allocateWaiterID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelStartWaiter(waiterID) }
        }
    }

    public func stop() async {
        guard lifecycle != .stopped else { return }
        shouldRun = false
        coordinatorGeneration &+= 1
        lifecycle = .closing
        coordinatorTask?.cancel()
        coordinatorTask = nil
        readerTask?.cancel()
        readerTask = nil
        outboundDrainTask?.cancel()
        outboundDrainTask = nil
        leaseEffectDrainTask?.cancel()
        leaseEffectDrainTask = nil
        leaseEffectQueue.removeAll(keepingCapacity: false)
        historyEffectDrainTask?.cancel()
        historyEffectDrainTask = nil
        historyEffectQueue.removeAll(keepingCapacity: false)
        for task in historyRequestTasks.values {
            task.cancel()
        }
        historyRequestTasks.removeAll(keepingCapacity: false)
        if let epoch = activeConnectionEpoch {
            sealConnection(
                epoch,
                error: CodexSessionError.connectionLost(
                    connectionEpoch: epoch,
                    message: "Session closed"
                )
            )
        }
        await transport.close()
        failStartWaiters(with: CodexSessionError.closed)
        failOperationWaiters(with: CodexSessionError.closed)
        lifecycle = .stopped
    }

    func perform(
        method: CodexAppServerClientMethod,
        params: CodexJSONValue?
    ) async throws -> CodexJSONValue {
        try await performCall(method: method, params: params).value
    }

    func performCall(
        method: CodexAppServerClientMethod,
        params: CodexJSONValue?,
        submissionIntent: SubmissionIntent? = nil,
        resumeHistoryReason: ThreadLeaseReason? = nil
    ) async throws -> CodexSessionCallResult {
        guard case .ready(let epoch) = lifecycle,
              activeConnectionEpoch == epoch else {
            throw CodexSessionError.notReady(lifecycle)
        }
        return try await beginClientRequest(
            method: method,
            params: params,
            connectionEpoch: epoch,
            submissionIntent: submissionIntent,
            resumeHistoryReason: resumeHistoryReason,
            isHandshake: false
        )
    }

    func makeSubmissionIntent(
        threadID: ThreadID,
        expectedTurnID: TurnID?,
        input: [CodexJSONValue],
        clientUserMessageID: SubmissionIntentID? = nil
    ) -> SubmissionIntent {
        precondition(
            nextSubmissionOrdinal < UInt64.max,
            "Submission intent ordinal space exhausted"
        )
        let ordinal = nextSubmissionOrdinal
        nextSubmissionOrdinal += 1
        return SubmissionIntent(
            id: clientUserMessageID ?? SubmissionIntentID("codexcore-\(ordinal)"),
            threadID: threadID,
            expectedTurnID: expectedTurnID,
            input: input,
            localOrdinal: ordinal
        )
    }

    public func canonicalSnapshot(
        scope: StateObservationScope = .all
    ) -> CanonicalStateSnapshot {
        graph.snapshot().scoped(to: scope)
    }

    public func observe(
        scope: StateObservationScope = .all
    ) -> StateSnapshotObservation<CanonicalStateSnapshot> {
        observations.observe(scope: scope, revision: graph.revision) {
            graph.snapshot().scoped(to: scope)
        }
    }

    public func cancelObservation(_ observationID: StateObservationID) {
        observations.cancelObservation(observationID)
    }

    public func threadIndexSnapshot() -> CanonicalThreadIndexSnapshot {
        graph.threadIndexSnapshot(
            attentionRevisions: threadAttentionRevisions,
            pendingRequestThreadIDs: Set(
                interactions.pendingSnapshots().compactMap { snapshot in
                    snapshot.scope.threadID.map { ThreadID($0) }
                }
            )
        )
    }

    public func observeThreadIndex() -> StateSnapshotObservation<CanonicalThreadIndexSnapshot> {
        observations.observe(
            scope: CanonicalThreadIndexSnapshot.observationScope,
            revision: graph.revision
        ) {
            threadIndexSnapshot()
        }
    }

    public func pendingServerRequests() -> [CodexPendingInteractionSnapshot] {
        interactions.pendingSnapshots()
    }

    public func serverRequestSnapshotBatch(
        scope: StateObservationScope = .all
    ) -> CodexPendingInteractionSnapshotBatch {
        .init(
            revision: graph.revision,
            requests: scopedServerRequests(scope: scope)
        )
    }

    /// Returns the current typed prompt inbox without materializing the
    /// canonical graph. Its revision is the same ordered canonical revision used
    /// by canonical and atomic session-state observations.
    public func serverRequestInboxSnapshot(
        entities: StateEntityScope = .all
    ) -> CodexServerRequestInboxSnapshot {
        makeServerRequestInboxSnapshot(entities: entities)
    }

    /// Atomically captures the typed prompt inbox and a wake-up stream filtered
    /// to pending-interaction changes only. Consumers fetch a fresh snapshot
    /// after each coalesced signal.
    public func observeServerRequests(
        entities: StateEntityScope = .all
    ) -> StateSnapshotObservation<CodexServerRequestInboxSnapshot> {
        let scope = StateObservationScope(entities: entities, fields: .requests)
        return observations.observe(scope: scope, revision: graph.revision) {
            makeServerRequestInboxSnapshot(entities: entities)
        }
    }

    public func sessionStateSnapshot(
        scope: StateObservationScope = .all
    ) -> CodexSessionStateSnapshot {
        let canonical = graph.snapshot().scoped(to: scope)
        return .init(
            stateRevision: graph.revision,
            canonical: canonical,
            serverRequests: .init(
                revision: graph.revision,
                requests: scopedServerRequests(scope: scope)
            ),
            lifecycle: lifecycle
        )
    }

    public func observeSessionState(
        scope: StateObservationScope = .all
    ) -> StateSnapshotObservation<CodexSessionStateSnapshot> {
        observations.observe(scope: scope, revision: graph.revision) {
            sessionStateSnapshot(scope: scope)
        }
    }

    public func serverRequest(
        for key: CodexServerRequestKey
    ) -> CodexParsedServerRequest? {
        interactions.parsedRequest(for: key)
    }

    /// Observes coalesced global skill invalidations for this connection.
    public func observeSkillsChanges() throws -> AsyncThrowingStream<
        CodexSchemaSkillsChangedNotification,
        Error
    > {
        guard case .ready(let epoch) = lifecycle,
              activeConnectionEpoch == epoch else {
            throw CodexSessionError.notReady(lifecycle)
        }
        let observation = skillsChanges.observe(
            connectionEpoch: epoch,
            onTermination: { [weak self] id in
                Task { await self?.cancelSkillsChangeObservation(id) }
            }
        )
        return observation.changes
    }

    func cancelSkillsChangeObservation(_ id: CodexSkillsChangeObservationID) {
        _ = skillsChanges.cancel(id)
    }

    func registerCommandOutput(
        processID: String,
        maximumDeltaCount: Int
    ) throws -> CodexCommandOutputSubscription {
        guard case .ready(let epoch) = lifecycle,
              activeConnectionEpoch == epoch else {
            throw CodexSessionError.notReady(lifecycle)
        }
        return try commandOutputs.register(
            connectionEpoch: epoch,
            processID: processID,
            maximumDeltaCount: maximumDeltaCount,
            onTermination: { [weak self] token in
                Task { await self?.cancelCommandOutput(token) }
            }
        )
    }

    func cancelCommandOutput(_ token: CodexCommandOutputSubscriptionToken) {
        _ = commandOutputs.cancel(token)
    }

    public func protocolDiagnostics() -> CodexProtocolDiagnosticsSnapshot {
        diagnostics.snapshot()
    }

    public func resolveServerRequest(
        _ key: CodexServerRequestKey,
        result: CodexJSONValue
    ) throws {
        guard let parsed = interactions.parsedRequest(for: key) else {
            throw CodexSessionError.unknownServerRequest(key)
        }
        _ = try parsed.validate(result: result)
        try completeServerRequest(key, reply: .result(result))
    }

    public func failServerRequest(
        _ key: CodexServerRequestKey,
        error: CodexServerRequestResponseError
    ) throws {
        try completeServerRequest(key, reply: .error(error))
    }

    /// Starts a login transaction and binds its later terminal notification to
    /// the exact connection epoch that produced the response.
    public func startLogin(
        _ params: CodexSchemaLoginAccountParams
    ) async throws -> CodexLoginTransaction {
        guard case .ready(let requestEpoch) = lifecycle,
              activeConnectionEpoch == requestEpoch else {
            throw CodexSessionError.notReady(lifecycle)
        }

        let expectsAnonymous: Bool
        switch params {
        case .apiKey, .chatgptAuthTokens, .amazonBedrock:
            expectsAnonymous = true
        case .chatgpt, .chatgptDeviceCode:
            expectsAnonymous = false
        case .unrecognized(let type, _):
            throw CodexSessionError.protocolViolation(
                "Unsupported account/login/start parameter type \(type)"
            )
        }

        let anonymousKey = CodexLoginKey(
            connectionEpoch: requestEpoch,
            identity: .anonymous
        )
        if expectsAnonymous, activeLoginKeys.contains(anonymousKey) {
            throw CodexSessionError.anonymousLoginAlreadyInProgress(
                connectionEpoch: requestEpoch
            )
        }
        if expectsAnonymous,
           !anonymousLoginRequestEpochs.insert(requestEpoch).inserted {
            throw CodexSessionError.anonymousLoginAlreadyInProgress(
                connectionEpoch: requestEpoch
            )
        }

        let call: CodexSessionCallResult
        do {
            call = try await performCall(
                method: .accountLoginStart,
                params: try CodexJSONValue(encoding: params)
            )
        } catch {
            if expectsAnonymous {
                anonymousLoginRequestEpochs.remove(requestEpoch)
            }
            throw error
        }
        let response = try call.value.decode(CodexSchemaLoginAccountResponse.self)

        do {
            let identity = try loginIdentity(in: response.rawValue)
            guard (identity == .anonymous) == expectsAnonymous else {
                throw CodexSessionError.protocolViolation(
                    "account/login/start response identity did not match request type \(params.type)"
                )
            }
            let key = CodexLoginKey(
                connectionEpoch: call.responseCursor.connectionEpoch,
                identity: identity
            )

            if expectsAnonymous {
                anonymousLoginRequestEpochs.remove(requestEpoch)
            }
            if retainedLoginCompletions[key] == nil,
               !activeLoginKeys.insert(key).inserted {
                throw CodexSessionError.protocolViolation(
                    "account/login/start reused an unresolved login identity"
                )
            }

            switch identity {
            case .identified:
                return .identified(.init(
                    key: key,
                    response: response,
                    session: self
                ))
            case .anonymous:
                return .anonymous(.init(
                    key: key,
                    response: response,
                    session: self
                ))
            }
        } catch {
            if expectsAnonymous {
                anonymousLoginRequestEpochs.remove(requestEpoch)
            }
            let violation = CodexSessionError.protocolViolation(
                "Invalid account/login/start response: \(error)"
            )
            abortConnection(call.responseCursor.connectionEpoch, error: violation)
            throw violation
        }
    }

    func cancelLogin(_ key: CodexLoginKey) async throws -> CodexLoginCompletion {
        guard case .identified(let loginID) = key.identity else {
            preconditionFailure("Anonymous login attempts do not expose cancel()")
        }
        if let completion = retainedLoginCompletions[key] {
            guard !completion.success else {
                throw CodexSessionError.loginCancellationDidNotCancel(key)
            }
            return completion
        }
        guard case .ready(let epoch) = lifecycle,
              activeConnectionEpoch == epoch,
              key.connectionEpoch == epoch else {
            throw CodexSessionError.connectionLost(
                connectionEpoch: key.connectionEpoch,
                message: "Login attempt belongs to a sealed connection"
            )
        }

        let call = try await performCall(
            method: .accountLoginCancel,
            params: try CodexJSONValue(encoding: CodexSchemaCancelLoginAccountParams(
                loginID: loginID
            ))
        )
        guard call.responseCursor.connectionEpoch == key.connectionEpoch else {
            throw CodexSessionError.connectionLost(
                connectionEpoch: key.connectionEpoch,
                message: "Login cancellation response crossed connection epochs"
            )
        }
        let response = try call.value.decode(
            CodexSchemaCancelLoginAccountResponse.self
        )
        switch response.status {
        case .canceled:
            let completion = try await awaitLogin(key)
            guard !completion.success else {
                throw CodexSessionError.loginCancellationDidNotCancel(key)
            }
            return completion
        case .notFound:
            if let completion = retainedLoginCompletions[key] {
                guard !completion.success else {
                    throw CodexSessionError.loginCancellationDidNotCancel(key)
                }
                return completion
            }
            throw CodexSessionError.loginCancellationNotFound(key)
        case .unrecognized(let status):
            let violation = CodexSessionError.protocolViolation(
                "account/login/cancel returned unknown status \(status)"
            )
            abortConnection(key.connectionEpoch, error: violation)
            throw violation
        }
    }

    public func awaitLogin(_ key: CodexLoginKey) async throws -> CodexLoginCompletion {
        if let completion = retainedLoginCompletions[key] {
            return completion
        }
        guard case .ready(let epoch) = lifecycle,
              activeConnectionEpoch == epoch,
              key.connectionEpoch == epoch else {
            if key.connectionEpoch < nextConnectionEpoch {
                throw CodexSessionError.connectionLost(
                    connectionEpoch: key.connectionEpoch,
                    message: "Login attempt belongs to a sealed connection"
                )
            }
            throw CodexSessionError.notReady(lifecycle)
        }
        guard !Task.isCancelled else { throw CancellationError() }
        let waiterID = allocateWaiterID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loginWaiters[key, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelLoginWaiter(key: key, waiterID: waiterID) }
        }
    }

    public func awaitTerminalTurn(_ key: TurnKey) async throws -> CodexTerminalTurn {
        if let terminal = terminalTurn(for: key) {
            return terminal
        }
        guard !Task.isCancelled else { throw CancellationError() }
        let waiterID = allocateWaiterID()
        let token = acquireThreadLease(
            threadID: key.threadID,
            reason: .terminalWaiter(String(waiterID))
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                terminalWaiters[key, default: [:]][waiterID] = .init(
                    token: token,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelTerminalWaiter(key: key, waiterID: waiterID) }
        }
    }

    func acquireThreadLease(
        threadID: ThreadID,
        reason: ThreadLeaseReason
    ) -> ThreadLeaseToken {
        unleasedThreadDetailLRU.removeAll { $0 == threadID }
        let acquisition = leases.acquire(threadID: threadID, reason: reason)
        scheduleLeaseEffects(acquisition.effects)
        return acquisition.token
    }

    func adoptThreadSubscription(
        threadID: ThreadID,
        reason: ThreadLeaseReason
    ) throws -> ThreadLeaseToken {
        guard case .ready(let epoch) = lifecycle,
              activeConnectionEpoch == epoch else {
            throw CodexSessionError.notReady(lifecycle)
        }
        unleasedThreadDetailLRU.removeAll { $0 == threadID }
        let acquisition: ThreadLeaseAcquisition
        if let existing = leases.snapshot(for: threadID), !existing.leases.isEmpty {
            acquisition = leases.acquire(threadID: threadID, reason: reason)
        } else {
            acquisition = leases.acquireAdoptingLiveSubscription(
                threadID: threadID,
                reason: reason,
                connectionEpoch: epoch
            )
        }
        scheduleLeaseEffects(acquisition.effects)
        return acquisition.token
    }

    /// Seeds full paging from a successful explicit `thread/resume` response.
    /// No second resume request is emitted, and the response's actual wire
    /// cursor remains the cut used to filter buffered live events.
    func adoptResumeAndSeedHistory(
        threadID: ThreadID,
        reason: ThreadLeaseReason,
        resumeResult: CodexJSONValue,
        responseCursor: CodexWireCursor,
        requestParams: [String: CodexJSONValue]
    ) throws -> ThreadLeaseToken {
        guard case .ready(let epoch) = lifecycle,
              activeConnectionEpoch == epoch,
              responseCursor.connectionEpoch == epoch else {
            throw CodexSessionError.notReady(lifecycle)
        }
        let object = try historyObject(resumeResult, method: "thread/resume")
        guard let resumeThread = object["thread"] else {
            throw CodexSessionError.protocolViolation(
                "thread/resume omitted thread during history reconciliation"
            )
        }
        let turnsCursor = try historyCursor(
            object,
            key: "turnsBackwardsCursor"
        )
        let itemsCursor = try historyCursor(
            object,
            key: "itemsBackwardsCursor"
        )
        if case .dictionary(let threadObject) = resumeThread,
           case .string(let actualID)? = threadObject["id"],
           ThreadID(actualID) != threadID {
            throw CodexLeaseError.responseThreadMismatch(
                expected: threadID,
                actual: ThreadID(actualID)
            )
        }

        unleasedThreadDetailLRU.removeAll { $0 == threadID }
        let seeded = leases.acquireAdoptingResumeReconciliation(
            threadID: threadID,
            reason: reason,
            connectionEpoch: epoch
        )
        let initial = history.beginReconciliation(seeded.reconciliation)
        guard initial.count == 1,
              case .requestResume(let placeholder) = initial[0] else {
            leases.reconciliationFailed(
                seeded.reconciliation,
                message: "History coordinator rejected seeded resume"
            )
            throw CodexSessionError.historyReconciliationFailed(
                threadID: threadID,
                message: "History coordinator rejected seeded resume"
            )
        }
        let historyEffects = history.receiveResumeCut(
            threadID: threadID,
            requestID: placeholder.requestID,
            turnsBackwardsCursor: turnsCursor,
            itemsBackwardsCursor: itemsCursor,
            responseCursor: responseCursor,
            resumeThread: resumeThread,
            resumeResult: resumeResult,
            resumeRequestParams: requestParams
        )
        scheduleHistoryEffects(historyEffects)
        scheduleLeaseEffects(leases.reconciliationSucceeded(seeded.reconciliation))
        resolveHistoryWaiters(
            threadID: threadID,
            history: graph.threads[threadID]?.history ?? .init()
        )
        return seeded.token
    }

    func releaseThreadLease(_ token: ThreadLeaseToken) {
        let release = leases.release(token)
        scheduleLeaseEffects(release.effects)
        guard release.didRelease else { return }
        refreshThreadDetailRetention(for: [token.threadID])
    }

    /// Retains a thread and drives alpha.20 resume plus complete cursor paging.
    /// Releasing the returned token deterministically tears the subscription down.
    public func hydrateThreadHistory(
        _ threadID: ThreadID,
        reason: ThreadLeaseReason = .explicitObserver("history")
    ) -> ThreadLeaseToken {
        acquireThreadLease(threadID: threadID, reason: reason)
    }

    public func releaseThreadHistory(_ token: ThreadLeaseToken) {
        releaseThreadLease(token)
    }

    public func threadHistoryLoadingState(
        _ threadID: ThreadID
    ) -> PaginatedHistoryScopeSnapshot? {
        history.snapshot(for: threadID)
    }

    /// Waits until the retained thread has installed all turn and item pages.
    /// The returned value is the canonical history metadata from that same
    /// actor transaction.
    public func awaitThreadHistory(
        _ threadID: ThreadID
    ) async throws -> CanonicalHistoryState {
        guard let snapshot = history.snapshot(for: threadID) else {
            throw CodexSessionError.historyReconciliationFailed(
                threadID: threadID,
                message: "The thread has no retained history scope"
            )
        }

        let connectionEpoch: UInt64?
        switch snapshot.phase {
        case .live:
            return graph.threads[threadID]?.history ?? .init()
        case .failed(let failure):
            throw CodexSessionError.historyReconciliationFailed(
                threadID: threadID,
                message: String(describing: failure.reason)
            )
        case .paging:
            // Resume has already established the subscription and installed
            // its metadata/anchors. Older pages continue incrementally.
            return graph.threads[threadID]?.history ?? .init()
        case .awaitingResume(let epoch, _):
            connectionEpoch = epoch
        case .stale:
            connectionEpoch = nil
        }

        guard !Task.isCancelled else { throw CancellationError() }
        let waiterID = allocateWaiterID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                historyWaiters[threadID, default: [:]][waiterID] = .init(
                    connectionEpoch: connectionEpoch,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelHistoryWaiter(
                    threadID: threadID,
                    waiterID: waiterID
                )
            }
        }
    }
}

// MARK: - Connection lifecycle and handshake

private extension CodexSession {
    func ensureCoordinator() {
        guard coordinatorTask == nil else { return }
        coordinatorGeneration &+= 1
        let generation = coordinatorGeneration
        coordinatorTask = Task { [weak self] in
            await self?.runConnectionLoop(generation: generation)
        }
    }

    func runConnectionLoop(generation: UInt64) async {
        var attempt = 0
        var previousEpoch: UInt64?

        while shouldRun,
              coordinatorGeneration == generation,
              !Task.isCancelled
        {
            attempt += 1
            reconnectAttempt = attempt
            let isFirstAttempt = previousEpoch == nil && attempt == 1
            if isFirstAttempt {
                lifecycle = .connecting(attempt: attempt)
            } else {
                lifecycle = .reconnecting(
                    afterConnectionEpoch: previousEpoch,
                    attempt: attempt
                )
                let delay = configuration.reconnectPolicy.delayMilliseconds(
                    forAttempt: attempt
                )
                await reconnectSleep(delay)
                guard shouldRun,
                      coordinatorGeneration == generation,
                      !Task.isCancelled else { break }
            }

            do {
                if let codexHome = configuration.codexHome {
                    do {
                        try codexHome.prepareForLaunch()
                    } catch let error as CodexHomePreparationError {
                        throw CodexSessionError.codexHomePreparationFailed(error)
                    }
                }
                let stream = try await transport.open()
                guard shouldRun,
                      coordinatorGeneration == generation,
                      !Task.isCancelled else {
                    await transport.close()
                    break
                }

                let epoch = beginConnection()
                previousEpoch = epoch
                lifecycle = .initializing(connectionEpoch: epoch)
                let reader = makeReader(stream: stream, connectionEpoch: epoch)
                readerTask = reader

                do {
                    let metadata = try await initializeConnection(epoch)
                    guard activeConnectionEpoch == epoch else {
                        throw CodexSessionError.connectionLost(
                            connectionEpoch: epoch,
                            message: "Connection ended during initialization"
                        )
                    }
                    initializeResponse = metadata
                    reconnectAttempt = 0
                    attempt = 0
                    resumeStartWaiters(with: metadata)

                    let termination = await reader.value
                    readerTask = nil
                    await transport.close()
                    let terminalError = terminalErrorByConnectionEpoch
                        .removeValue(forKey: epoch)
                        ?? CodexSessionError.connectionLost(
                            connectionEpoch: epoch,
                            message: termination.message
                        )
                    throw terminalError
                } catch {
                    reader.cancel()
                    readerTask = nil
                    terminalErrorByConnectionEpoch.removeValue(forKey: epoch)
                    if activeConnectionEpoch == epoch {
                        sealConnection(epoch, error: error)
                    }
                    await transport.close()

                    guard shouldReconnect(after: error) else {
                        shouldRun = false
                        failStartWaiters(with: error)
                        failOperationWaiters(with: error)
                        break
                    }
                }
            } catch {
                guard shouldReconnect(after: error) else {
                    shouldRun = false
                    failStartWaiters(with: error)
                    failOperationWaiters(with: error)
                    break
                }
            }
        }

        if coordinatorGeneration == generation {
            coordinatorTask = nil
            if !shouldRun, lifecycle != .closing {
                lifecycle = .stopped
            }
        }
    }

    func beginConnection() -> UInt64 {
        precondition(nextConnectionEpoch < UInt64.max, "Connection epoch space exhausted")
        let epoch = nextConnectionEpoch
        nextConnectionEpoch += 1
        activeConnectionEpoch = epoch
        nextWireOrdinal = 0
        handshakeRequestKey = nil
        bufferedHandshakeEnvelopes.removeAll(keepingCapacity: true)
        return epoch
    }

    private func makeReader(
        stream: AsyncThrowingStream<Data, Error>,
        connectionEpoch: UInt64
    ) -> Task<ReaderTermination, Never> {
        Task { [weak self] in
            let termination: ReaderTermination
            do {
                for try await frame in stream {
                    guard !Task.isCancelled else { break }
                    await self?.receiveFrame(frame, connectionEpoch: connectionEpoch)
                }
                termination = .ended
            } catch {
                termination = .failed(String(describing: error))
            }
            await self?.readerEnded(
                connectionEpoch: connectionEpoch,
                termination: termination
            )
            return termination
        }
    }

    private func readerEnded(
        connectionEpoch: UInt64,
        termination: ReaderTermination
    ) {
        guard activeConnectionEpoch == connectionEpoch else { return }
        sealConnection(
            connectionEpoch,
            error: CodexSessionError.connectionLost(
                connectionEpoch: connectionEpoch,
                message: termination.message
            )
        )
    }

    func initializeConnection(_ epoch: UInt64) async throws -> InitializeResponse {
        let params = try CodexJSONValue(encoding: CodexSchemaInitializeParams(
            capabilities: configuration.capabilities,
            clientInfo: .init(
                name: configuration.clientName,
                title: configuration.clientTitle,
                version: configuration.clientVersion
            )
        ))

        let call = try await beginClientRequest(
            method: .initialize,
            params: params,
            connectionEpoch: epoch,
            submissionIntent: nil,
            isHandshake: true
        )
        let metadata = try call.value.decode(InitializeResponse.self)
        try validateInitializeResponse(metadata)

        guard activeConnectionEpoch == epoch else {
            throw CodexSessionError.connectionLost(
                connectionEpoch: epoch,
                message: "Connection ended before initialized notification"
            )
        }
        do {
            try await transport.write(CodexJSONRPCCodec.encodeNotification(method: "initialized"))
        } catch {
            sealConnection(epoch, error: error)
            throw error
        }

        guard activeConnectionEpoch == epoch else {
            throw CodexSessionError.connectionLost(
                connectionEpoch: epoch,
                message: "Connection ended while sending initialized notification"
            )
        }
        lifecycle = .ready(connectionEpoch: epoch)
        // Register every retained scope with the history coordinator before
        // replaying frames buffered during initialization. The effect workers
        // cannot run until this synchronous drain returns, but live frames now
        // enter the correct cursor-bounded staging scope.
        scheduleLeaseEffects(leases.connectionReady(epoch))

        let buffered = bufferedHandshakeEnvelopes
        bufferedHandshakeEnvelopes.removeAll(keepingCapacity: true)
        for message in buffered {
            guard activeConnectionEpoch == epoch else {
                throw CodexSessionError.connectionLost(
                    connectionEpoch: epoch,
                    message: "Connection ended while draining handshake frames"
                )
            }
            processEnvelope(message.envelope, cursor: message.cursor)
        }

        guard activeConnectionEpoch == epoch else {
            throw CodexSessionError.connectionLost(
                connectionEpoch: epoch,
                message: "Buffered protocol frame invalidated initialization"
            )
        }
        return metadata
    }

    func validateInitializeResponse(_ response: InitializeResponse) throws {
        if let expectedHome = configuration.codexHome {
            let reportedHome = response.codexHome
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reportedHome.isEmpty,
                  CodexHome(path: reportedHome) == expectedHome else {
                throw CodexSessionError.codexHomeMismatch(
                    expected: expectedHome.path,
                    actual: response.codexHome
                )
            }
        }
        // `userAgent` is descriptive server metadata, not a negotiated protocol
        // version. Production pins the executable before launch; retain the raw
        // value in `InitializeResponse` without inferring a wire contract from it.
    }

    func shouldReconnect(after error: Error) -> Bool {
        guard shouldRun, configuration.reconnectPolicy.isEnabled else { return false }
        switch error {
        case is CodexJSONRPCErrorObject,
             is DecodingError,
             CodexSessionError.protocolViolation,
             CodexSessionError.codexHomePreparationFailed,
             CodexSessionError.codexHomeMismatch,
             CodexSessionError.handshakeBufferOverflow,
             CodexSessionError.stateCommitFailed:
            return false
        default:
            return true
        }
    }

    func sealConnection(_ epoch: UInt64, error: Error) {
        guard activeConnectionEpoch == epoch else { return }
        terminalErrorByConnectionEpoch[epoch] = error
        activeConnectionEpoch = nil
        handshakeRequestKey = nil
        bufferedHandshakeEnvelopes.removeAll(keepingCapacity: true)
        leases.connectionLost(epoch)
        refreshThreadDetailRetention(for: Set(graph.threads.keys))
        for task in historyRequestTasks.values {
            task.cancel()
        }
        historyRequestTasks.removeAll(keepingCapacity: true)
        scheduleHistoryEffects(history.connectionLost(epoch))
        _ = commandOutputs.disconnect(connectionEpoch: epoch)
        _ = skillsChanges.disconnect(connectionEpoch: epoch)
        sealLoginAttempts(connectionEpoch: epoch, error: error)
        for threadID in Array(historyWaiters.keys) {
            failHistoryWaiters(
                threadID: threadID,
                connectionEpoch: epoch,
                error: error
            )
        }

        let requestKeys = pendingClientRequests.keys.filter {
            $0.connectionEpoch == epoch
        }
        for key in requestKeys {
            guard let pending = pendingClientRequests.removeValue(forKey: key) else {
                continue
            }
            if let intentID = pending.submissionIntentID {
                let mutation: CanonicalStateMutation = pending.writeAttempted
                    ? .submissionIntentMarkedIndeterminate(
                        id: intentID,
                        message: "Connection ended before the response was observed"
                    )
                    : .submissionIntentFailed(
                        id: intentID,
                        message: "Request was not written before the connection ended"
                    )
                try? commit(mutation)
            }
            pending.continuation?.resume(throwing: error)
        }

        outboundFrames.removeAll { $0.connectionEpoch == epoch }
        for request in interactions.disconnect(connectionEpoch: epoch) {
            try? commitRequestInvalidation(scope: request.registration.scope)
            serverRequestTasks.removeValue(forKey: request.key)?.cancel()
            releaseThreadForServerRequest(request.key)
        }
        for key in Array(serverRequestThreadLeases.keys)
        where key.connectionEpoch == epoch {
            releaseThreadForServerRequest(key)
        }
        if shouldRun, lifecycle != .closing {
            lifecycle = .reconnecting(
                afterConnectionEpoch: epoch,
                attempt: max(1, reconnectAttempt)
            )
        }
    }
}

// MARK: - Client request correlation and one-attempt outbound queue

private extension CodexSession {
    func beginClientRequest(
        method: CodexAppServerClientMethod,
        params: CodexJSONValue?,
        connectionEpoch: UInt64,
        submissionIntent: SubmissionIntent?,
        resumeHistoryReason: ThreadLeaseReason? = nil,
        isHandshake: Bool,
        reducesResponse: Bool = true
    ) async throws -> CodexSessionCallResult {
        try Task.checkCancellation()
        guard activeConnectionEpoch == connectionEpoch else {
            throw CodexSessionError.connectionLost(
                connectionEpoch: connectionEpoch,
                message: "Request was created for a stale connection"
            )
        }

        let id = try allocateClientRequestID()
        let key = ClientRequestKey(connectionEpoch: connectionEpoch, id: id)
        let frame = try CodexJSONRPCCodec.encodeRequest(
            id: id,
            method: method.rawValue,
            params: params
        )
        let startRevision = graph.revision
        if let submissionIntent {
            try commit(.submissionIntentRegistered(submissionIntent))
        }
        let context = responseContext(
            method: method,
            params: params,
            connectionEpoch: connectionEpoch
        )
        let outboundToken = allocateOutboundToken()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingClientRequests[key] = PendingClientRequest(
                    key: key,
                    context: context,
                    startRevision: startRevision,
                    submissionIntentID: submissionIntent?.id,
                    resumeHistoryReason: resumeHistoryReason,
                    outboundToken: outboundToken,
                    reducesResponse: reducesResponse,
                    writeAttempted: false,
                    continuation: continuation
                )
                if isHandshake {
                    handshakeRequestKey = key
                }
                enqueueOutbound(.init(
                    token: outboundToken,
                    connectionEpoch: connectionEpoch,
                    correlation: .clientRequest(key),
                    data: frame
                ))
            }
        } onCancel: {
            Task { await self.cancelClientRequestWaiter(key) }
        }
    }

    func responseContext(
        method: CodexAppServerClientMethod,
        params: CodexJSONValue?,
        connectionEpoch: UInt64
    ) -> ProtocolResponseContext {
        let object = params?.objectValue ?? [:]
        let threadID = object["threadId"].flatMap { value -> ThreadID? in
            guard case .string(let raw) = value else { return nil }
            return ThreadID(raw)
        }

        var resumeGeneration: UInt64 = 0
        if method == .threadResume, let threadID {
            resumeGeneration = (resumeGenerationByThread[threadID] ?? 0) &+ 1
            resumeGenerationByThread[threadID] = resumeGeneration
        }

        let itemPolicy: CanonicalItemCollectionMergePolicy
        switch method {
        case .threadStart, .threadFork, .threadRollback:
            itemPolicy = .authoritativeReplacement
        case .threadRead:
            itemPolicy = object["includeTurns"] == .bool(true)
                ? .authoritativeReplacement
                : .mergePreservingExistingOrder
        case .threadTurnsList, .threadItemsList:
            itemPolicy = .mergeIncomingFirst
        default:
            itemPolicy = .mergePreservingExistingOrder
        }

        return ProtocolResponseContext(
            method: method,
            requestParams: object,
            connectionEpoch: connectionEpoch,
            resumeGeneration: resumeGeneration,
            itemCollectionPolicy: itemPolicy,
            assertedItemsCoverage: nil
        )
    }

    private func enqueueOutbound(_ frame: OutboundFrame) {
        outboundFrames.append(frame)
        guard outboundDrainTask == nil else { return }
        outboundDrainTask = Task { [weak self] in
            await self?.drainOutboundFrames()
        }
    }

    func drainOutboundFrames() async {
        while let frame = outboundFrames.first {
            guard activeConnectionEpoch == frame.connectionEpoch else {
                outboundFrames.removeFirst()
                continue
            }

            if case .clientRequest(let key) = frame.correlation,
               var pending = pendingClientRequests[key] {
                pending.writeAttempted = true
                pendingClientRequests[key] = pending
            }

            outboundWriteInFlightToken = frame.token
            do {
                try await transport.write(frame.data)
            } catch {
                if outboundWriteInFlightToken == frame.token {
                    outboundWriteInFlightToken = nil
                }
                if activeConnectionEpoch == frame.connectionEpoch {
                    sealConnection(frame.connectionEpoch, error: error)
                    readerTask?.cancel()
                }
                await transport.close()
                break
            }
            if outboundWriteInFlightToken == frame.token {
                outboundWriteInFlightToken = nil
            }

            if outboundFrames.first?.token == frame.token {
                outboundFrames.removeFirst()
            } else {
                outboundFrames.removeAll { $0.token == frame.token }
            }
        }
        outboundDrainTask = nil
    }

    /// Drops only a server response that is still waiting in the ordered
    /// outbound queue. Once `transport.write` has begun, the frame is retained:
    /// the transport boundary may already have accepted some or all bytes.
    func discardQueuedServerResponse(for key: CodexServerRequestKey) {
        outboundFrames.removeAll { frame in
            guard frame.token != outboundWriteInFlightToken,
                  case .serverRequest(let candidate) = frame.correlation else {
                return false
            }
            return candidate == key
        }
    }

    private func cancelClientRequestWaiter(_ key: ClientRequestKey) {
        guard var pending = pendingClientRequests[key],
              let continuation = pending.continuation else { return }
        pending.continuation = nil
        continuation.resume(throwing: CancellationError())

        if pending.writeAttempted {
            pendingClientRequests[key] = pending
        } else {
            pendingClientRequests.removeValue(forKey: key)
            outboundFrames.removeAll { $0.token == pending.outboundToken }
            finishCommandOutput(for: pending)
            if handshakeRequestKey == key {
                handshakeRequestKey = nil
            }
            if let intentID = pending.submissionIntentID {
                try? commit(.submissionIntentFailed(
                    id: intentID,
                    message: "Request was cancelled before its first write attempt"
                ))
            }
        }
    }

    private func finishCommandOutput(for pending: PendingClientRequest) {
        guard pending.context.method == .commandExec,
              case .string(let processID)? = pending.context
                .requestParams["processId"] else {
            return
        }
        _ = commandOutputs.finish(
            connectionEpoch: pending.key.connectionEpoch,
            processID: processID
        )
    }

    func allocateClientRequestID() throws -> CodexJSONRPCID {
        guard nextClientRequestID < Int64.max else {
            throw CodexSessionError.requestIdentifierExhausted
        }
        let id = nextClientRequestID
        nextClientRequestID += 1
        return .integer(id)
    }

    func allocateOutboundToken() -> UInt64 {
        precondition(nextOutboundToken < UInt64.max, "Outbound token space exhausted")
        defer { nextOutboundToken += 1 }
        return nextOutboundToken
    }
}

// MARK: - Ordered ingress transaction

private extension CodexSession {
    func receiveFrame(_ frame: Data, connectionEpoch: UInt64) {
        guard activeConnectionEpoch == connectionEpoch else { return }
        guard nextWireOrdinal < UInt64.max else {
            abortConnection(
                connectionEpoch,
                error: CodexSessionError.protocolViolation("Wire ordinal space exhausted")
            )
            return
        }

        let cursor = CodexWireCursor(
            connectionEpoch: connectionEpoch,
            ordinal: nextWireOrdinal
        )
        nextWireOrdinal += 1

        let envelope: CodexJSONRPCEnvelope
        do {
            envelope = try CodexJSONRPCCodec.decode(frame)
        } catch {
            abortConnection(
                connectionEpoch,
                error: CodexSessionError.protocolViolation(String(describing: error))
            )
            return
        }

        if case .initializing(let epoch) = lifecycle, epoch == connectionEpoch {
            if isHandshakeResponse(envelope, connectionEpoch: connectionEpoch) {
                processEnvelope(envelope, cursor: cursor)
            } else if bufferedHandshakeEnvelopes.count
                        < configuration.maximumBufferedHandshakeFrames
            {
                bufferedHandshakeEnvelopes.append(.init(
                    cursor: cursor,
                    envelope: envelope
                ))
            } else {
                abortConnection(
                    connectionEpoch,
                    error: CodexSessionError.handshakeBufferOverflow(
                        limit: configuration.maximumBufferedHandshakeFrames
                    )
                )
            }
            return
        }

        guard case .ready(let epoch) = lifecycle, epoch == connectionEpoch else {
            abortConnection(
                connectionEpoch,
                error: CodexSessionError.protocolViolation(
                    "Received a frame outside initializing/ready lifecycle"
                )
            )
            return
        }
        processEnvelope(envelope, cursor: cursor)
    }

    func isHandshakeResponse(
        _ envelope: CodexJSONRPCEnvelope,
        connectionEpoch: UInt64
    ) -> Bool {
        guard case .response(let response) = envelope,
              let handshakeRequestKey else { return false }
        return handshakeRequestKey.connectionEpoch == connectionEpoch
            && handshakeRequestKey.id == response.id
    }

    func processEnvelope(
        _ envelope: CodexJSONRPCEnvelope,
        cursor: CodexWireCursor
    ) {
        guard activeConnectionEpoch == cursor.connectionEpoch else { return }
        switch envelope {
        case .response(let response):
            processResponse(response, cursor: cursor)
        case .notification(let notification):
            processNotification(notification, cursor: cursor)
        case .serverRequest(let request):
            processServerRequest(request, cursor: cursor)
        }
    }

    func processResponse(
        _ response: CodexJSONRPCResponseEnvelope,
        cursor: CodexWireCursor
    ) {
        let key = ClientRequestKey(
            connectionEpoch: cursor.connectionEpoch,
            id: response.id
        )
        guard let pending = pendingClientRequests.removeValue(forKey: key) else {
            diagnostics.record(
                kind: .unmatchedResponse,
                method: "jsonrpc/response",
                cursor: cursor,
                keyDescription: String(describing: response.id),
                detail: "No pending request exists for this response id"
            )
            try? commitSessionInvalidation(fields: .diagnostics)
            return
        }
        outboundFrames.removeAll { $0.token == pending.outboundToken }
        if handshakeRequestKey == key {
            handshakeRequestKey = nil
        }
        finishCommandOutput(for: pending)

        switch response.outcome {
        case .result(let result):
            do {
                var threadLeaseToken: ThreadLeaseToken?
                if pending.reducesResponse {
                    let adaptation = try adapter.adaptResponse(
                        pending.context,
                        result: result
                    )
                    try apply(adaptation)
                    resolveTerminalWaitersIfPossible()
                }
                if let reason = pending.resumeHistoryReason {
                    guard pending.context.method == .threadResume,
                          case .string(let rawThreadID)? = pending.context
                            .requestParams["threadId"] else {
                        throw CodexSessionError.protocolViolation(
                            "Seeded history requires thread/resume threadId context"
                        )
                    }
                    let threadID = ThreadID(rawThreadID)
                    if pending.continuation != nil {
                        threadLeaseToken = try adoptResumeAndSeedHistory(
                            threadID: threadID,
                            reason: reason,
                            resumeResult: result,
                            responseCursor: cursor,
                            requestParams: pending.context.requestParams
                        )
                    } else {
                        // Cancellation after write still leaves a server-side
                        // subscription. Adopt and release it so teardown remains
                        // deterministic without creating ownerless history work.
                        let abandoned = try adoptThreadSubscription(
                            threadID: threadID,
                            reason: .ephemeralOwner("cancelled-thread-resume")
                        )
                        releaseThreadLease(abandoned)
                    }
                }
                pending.continuation?.resume(returning: .init(
                    value: result,
                    startRevision: pending.startRevision,
                    responseRevision: graph.revision,
                    responseCursor: cursor,
                    threadLeaseToken: threadLeaseToken
                ))
            } catch {
                pending.continuation?.resume(throwing: error)
                abortConnection(
                    cursor.connectionEpoch,
                    error: CodexSessionError.protocolViolation(String(describing: error))
                )
            }

        case .error(let error):
            if let intentID = pending.submissionIntentID {
                try? commit(.submissionIntentFailed(
                    id: intentID,
                    message: error.message
                ))
            }
            pending.continuation?.resume(throwing: error)
        }
    }

    func processNotification(
        _ notification: CodexJSONRPCNotificationEnvelope,
        cursor: CodexWireCursor
    ) {
        do {
            let adaptation = try adapter.adaptNotification(
                method: notification.method,
                params: notification.params
            )

            let knownMethod = CodexAppServerNotificationMethod(
                rawValue: notification.method
            )
            if let knownMethod {
                switch knownMethod {
                case .commandExecOutputDelta:
                    let output = try notification.params.decode(
                        CodexSchemaCommandExecOutputDeltaNotification.self
                    )
                    switch commandOutputs.publish(
                        connectionEpoch: cursor.connectionEpoch,
                        notification: output
                    ) {
                    case .delivered:
                        break
                    case .unmatched(let key):
                        diagnostics.record(
                            kind: .unmatchedOperation,
                            method: notification.method,
                            cursor: cursor,
                            keyDescription: "epoch=\(key.connectionEpoch),commandExec(process=\(key.processID))"
                        )
                        try commitSessionInvalidation(fields: .diagnostics)
                    case .overflowed(let key):
                        diagnostics.record(
                            kind: .bufferOverflow,
                            method: notification.method,
                            cursor: cursor,
                            keyDescription: "epoch=\(key.connectionEpoch),commandExec(process=\(key.processID))",
                            detail: "Command output delta buffer overflowed"
                        )
                        try commitSessionInvalidation(fields: .diagnostics)
                    }

                case .skillsChanged:
                    let change = try notification.params.decode(
                        CodexSchemaSkillsChangedNotification.self
                    )
                    _ = skillsChanges.publish(
                        connectionEpoch: cursor.connectionEpoch,
                        notification: change
                    )

                case .accountLoginCompleted:
                    let completion = try notification.params.decode(
                        CodexSchemaAccountLoginCompletedNotification.self
                    )
                    recordLoginCompletion(
                        completion,
                        connectionEpoch: cursor.connectionEpoch
                    )

                default:
                    break
                }
            }

            switch adaptation.disposition {
            case .diagnostic:
                diagnostics.record(
                    kind: .warning,
                    method: notification.method,
                    cursor: cursor,
                    detail: adaptation.diagnostic
                )
                try commitSessionInvalidation(fields: .diagnostics)
            case .unknownMethod:
                diagnostics.record(
                    kind: .unknownMethod,
                    method: notification.method,
                    cursor: cursor,
                    detail: adaptation.diagnostic
                )
                try commitSessionInvalidation(fields: .diagnostics)
            case .state, .requestResolution, .operation, .ignored:
                break
            }

            if adaptation.disposition == .state,
               let threadID = notificationThreadID(notification.params),
               history.snapshot(for: threadID) != nil {
                let event = PaginatedHistoryBufferedLiveEvent(
                    cursor: cursor,
                    method: notification.method,
                    params: .dictionary(notification.params)
                )
                switch history.receiveLiveEvent(threadID: threadID, event: event) {
                case .buffered, .ignoredDuplicate, .ignoredStale:
                    return
                case .applyImmediately:
                    break
                case .failed(let failure):
                    scheduleHistoryEffects([.failed(failure)])
                    // A durable-history failure reduces coverage; it does not
                    // make current-epoch live state disposable.
                    break
                }
            }

            if notification.method
                == CodexAppServerNotificationMethod.serverRequestResolved.rawValue
            {
                try applyServerResolvedNotification(
                    notification,
                    cursor: cursor
                )
            }

            try apply(adaptation)
            resolveTerminalWaitersIfPossible()
        } catch {
            abortConnection(
                cursor.connectionEpoch,
                error: CodexSessionError.protocolViolation(String(describing: error))
            )
        }
    }

    func processServerRequest(
        _ request: CodexJSONRPCServerRequestEnvelope,
        cursor: CodexWireCursor
    ) {
        let key = CodexServerRequestKey(
            connectionEpoch: cursor.connectionEpoch,
            requestID: request.id
        )

        do {
            let parsed = try CodexServerRequestParser.parse(
                connectionEpoch: cursor.connectionEpoch,
                id: request.id.jsonValue,
                method: request.method,
                params: request.params
            )
            switch interactions.register(parsed) {
            case .identicalDuplicate:
                return
            case .conflictingDuplicate:
                abortConnection(
                    cursor.connectionEpoch,
                    error: CodexSessionError.protocolViolation(
                        "Conflicting server request id \(request.id) in one epoch"
                    )
                )
            case .registered(let snapshot):
                try commitRequestInvalidation(scope: snapshot.scope)
                guard retainThreadForServerRequest(parsed) else { return }
                startServerRequestHandler(parsed)
            }
        } catch {
            do {
                try enqueueServerResponse(
                    key: key,
                    reply: .error(.init(
                        code: -32_602,
                        message: "Invalid app-server request parameters",
                        data: .dictionary([
                            "method": .string(request.method),
                            "detail": .string(String(describing: error)),
                        ])
                    ))
                )
            } catch {
                abortConnection(cursor.connectionEpoch, error: error)
            }
        }
    }

    func apply(
        _ adaptation: ProtocolStateAdaptation
    ) throws {
        try commit(adaptation.mutations)
    }

    func commit(_ mutation: CanonicalStateMutation) throws {
        try commit([mutation])
    }

    func commit(_ mutations: [CanonicalStateMutation]) throws {
        guard let batch = reducer.apply(mutations, to: &graph) else { return }
        let removedThreadIDs = Set(batch.changes.compactMap { change -> ThreadID? in
            guard case .threadRemoved(let threadID) = change else { return nil }
            return threadID
        })
        let detailEvictedThreadIDs = Set(batch.changes.compactMap { change -> ThreadID? in
            guard case .threadDetailEvicted(let threadID) = change else { return nil }
            return threadID
        })
        publishStateInvalidation(
            StateInvalidation(batch),
            removedThreadIDs: removedThreadIDs,
            attentionExcludedThreadIDs: detailEvictedThreadIDs
        )
        try updateThreadDetailRetention(for: batch.affectedThreadIDs)
    }

    func commitRequestInvalidation(
        scope: CodexServerRequestScope
    ) throws {
        guard graph.revision.rawValue < UInt64.max else {
            throw CodexSessionError.stateCommitFailed("State revision space exhausted")
        }
        graph.revision = graph.revision.successor

        let threadIDs = scope.threadID.map { Set([ThreadID($0)]) } ?? []
        let turnKeys: Set<TurnKey>
        if let threadID = scope.threadID,
           let turnID = scope.turnID {
            turnKeys = [.init(threadID: .init(threadID), turnID: .init(turnID))]
        } else {
            turnKeys = []
        }
        let itemKeys: Set<ItemKey>
        if let threadID = scope.threadID,
           let turnID = scope.turnID,
           let itemID = scope.itemID {
            itemKeys = [.init(
                threadID: .init(threadID),
                turnID: .init(turnID),
                itemID: .init(itemID)
            )]
        } else {
            itemKeys = []
        }

        publishStateInvalidation(.init(
            revision: graph.revision,
            fields: .requests,
            threadIDs: threadIDs,
            turnKeys: turnKeys,
            itemKeys: itemKeys
        ))
    }

    func abortConnection(_ epoch: UInt64, error: Error) {
        guard activeConnectionEpoch == epoch else { return }
        sealConnection(epoch, error: error)
        readerTask?.cancel()
        Task { await self.closeTransportAfterAbort() }
    }

    func closeTransportAfterAbort() async {
        await transport.close()
    }
}

// MARK: - Server-originated interactions

private extension CodexSession {
    enum ServerRequestReply {
        case result(CodexJSONValue)
        case error(CodexServerRequestResponseError)
    }

    func loginIdentity(in value: CodexJSONValue) throws -> CodexLoginIdentity {
        guard case .dictionary(let object) = value,
              case .string(let type)? = object["type"] else {
            throw CodexSessionError.protocolViolation(
                "account/login/start response must be an object with a string type"
            )
        }

        switch type {
        case "apiKey", "chatgptAuthTokens", "amazonBedrock":
            return .anonymous

        case "chatgpt":
            guard case .string(let loginID)? = object["loginId"],
                  !loginID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  case .string? = object["authUrl"] else {
                throw CodexSessionError.protocolViolation(
                    "chatgpt login response omitted loginId or authUrl"
                )
            }
            return .identified(loginID)

        case "chatgptDeviceCode":
            guard case .string(let loginID)? = object["loginId"],
                  !loginID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  case .string? = object["verificationUrl"],
                  case .string? = object["userCode"] else {
                throw CodexSessionError.protocolViolation(
                    "device-code login response omitted loginId, verificationUrl, or userCode"
                )
            }
            return .identified(loginID)

        default:
            throw CodexSessionError.protocolViolation(
                "account/login/start returned unknown type \(type)"
            )
        }
    }

    func retainThreadForServerRequest(_ request: CodexParsedServerRequest) -> Bool {
        guard let rawThreadID = request.body.scope.threadID else { return true }
        let key = request.key
        precondition(
            serverRequestThreadLeases[key] == nil,
            "A server request can own only one thread lease"
        )
        let identity: String
        switch key.requestID {
        case .integer(let value):
            identity = "\(key.connectionEpoch):integer:\(value)"
        case .string(let value):
            identity = "\(key.connectionEpoch):string:\(value)"
        }
        do {
            serverRequestThreadLeases[key] = try adoptThreadSubscription(
                threadID: ThreadID(rawThreadID),
                reason: .pendingServerRequest(identity)
            )
            return true
        } catch {
            abortConnection(key.connectionEpoch, error: error)
            return false
        }
    }

    func releaseThreadForServerRequest(_ key: CodexServerRequestKey) {
        guard let token = serverRequestThreadLeases.removeValue(forKey: key) else {
            return
        }
        releaseThreadLease(token)
    }

    func startServerRequestHandler(_ request: CodexParsedServerRequest) {
        guard let serverRequestHandler else {
            applyDefaultServerRequestPolicy(request)
            return
        }
        let key = request.key
        let task = Task { [weak self] in
            let outcome = await serverRequestHandler(request)
            await self?.serverRequestHandlerCompleted(
                key: key,
                outcome: outcome
            )
        }
        serverRequestTasks[key] = task
    }

    func serverRequestHandlerCompleted(
        key: CodexServerRequestKey,
        outcome: CodexServerRequestHandlerDecision
    ) {
        serverRequestTasks.removeValue(forKey: key)
        do {
            switch outcome {
            case .pending:
                guard let request = interactions.parsedRequest(for: key) else { return }
                applyDefaultServerRequestPolicy(request)

            case .result(let result):
                guard let parsed = interactions.parsedRequest(for: key) else { return }
                do {
                    _ = try parsed.validate(result: result)
                    try completeServerRequest(
                        key,
                        reply: .result(result),
                        tolerateMissing: true
                    )
                } catch {
                    try completeServerRequest(
                        key,
                        reply: .error(.init(
                            code: -32_603,
                            message: "Client produced an invalid server-request result",
                            data: .dictionary([
                                "detail": .string(String(describing: error))
                            ])
                        )),
                        tolerateMissing: true
                    )
                }

            case .error(let error):
                try completeServerRequest(
                    key,
                    reply: .error(error),
                    tolerateMissing: true
                )

            }
        } catch {
            if activeConnectionEpoch == key.connectionEpoch {
                abortConnection(key.connectionEpoch, error: error)
            }
        }
    }

    func applyDefaultServerRequestPolicy(_ request: CodexParsedServerRequest) {
        let outcome: CodexServerRequestHandlerDecision?
        switch request.body {
        case .currentTime:
            outcome = .result(.dictionary([
                "currentTimeAt": .int(Int(Date().timeIntervalSince1970.rounded(.down)))
            ]))

        case .dynamicToolCall:
            outcome = .result(.dictionary([
                "success": .bool(false),
                "contentItems": .array([]),
            ]))

        case .tokenRefresh, .attestation:
            outcome = .error(.init(
                code: -32_004,
                message: "Client capability is not configured",
                data: .dictionary(["method": .string(request.body.method)])
            ))

        case .unknown(let method, _):
            outcome = .error(.init(
                code: -32_601,
                message: "Method not found",
                data: .dictionary(["method": .string(method)])
            ))

        case .commandApproval, .fileChangeApproval, .userInput,
             .mcpElicitation, .permissionsApproval,
             .legacyApplyPatchApproval, .legacyExecCommandApproval:
            // These are interactive inbox entries. They remain pending until
            // an explicit host decision, cancellation, timeout, or disconnect.
            outcome = nil
        }

        if let outcome {
            serverRequestHandlerCompleted(key: request.key, outcome: outcome)
        }
    }

    func applyServerResolvedNotification(
        _ notification: CodexJSONRPCNotificationEnvelope,
        cursor: CodexWireCursor
    ) throws {
        let resolved: CodexSchemaServerRequestResolvedNotification
        do {
            resolved = try notification.params.decode(
                CodexSchemaServerRequestResolvedNotification.self
            )
        } catch {
            throw CodexSessionError.protocolViolation(
                "Malformed serverRequest/resolved: \(error)"
            )
        }
        let id: CodexJSONRPCID
        do {
            id = try .init(jsonValue: resolved.requestID.rawValue)
        } catch {
            throw CodexSessionError.protocolViolation(
                "serverRequest/resolved contained an invalid requestId"
            )
        }
        let key = CodexServerRequestKey(
            connectionEpoch: cursor.connectionEpoch,
            requestID: id
        )
        // A local reply may already have left the pending inbox while still
        // waiting behind another transport write. The server's resolution wins
        // until that response actually crosses the transport boundary.
        discardQueuedServerResponse(for: key)
        guard let pending = interactions.parsedRequest(for: key) else {
            diagnostics.record(
                kind: .lateServerRequestResolution,
                method: notification.method,
                cursor: cursor,
                keyDescription: String(describing: id),
                detail: "No pending server request exists for this resolution"
            )
            try? commitSessionInvalidation(fields: .diagnostics)
            return
        }
        if pending.registration.scope.threadID != resolved.threadID {
            diagnostics.record(
                kind: .lateServerRequestResolution,
                method: notification.method,
                cursor: cursor,
                keyDescription: String(describing: id),
                detail: "Resolution threadId \(resolved.threadID) did not match pending request scope \(pending.registration.scope.threadID ?? "global")"
            )
            try? commitSessionInvalidation(fields: .diagnostics)
        }
        guard let removed = interactions.takeOnServerResolved(key) else { return }
        try commitRequestInvalidation(scope: removed.registration.scope)
        serverRequestTasks.removeValue(forKey: key)?.cancel()
        releaseThreadForServerRequest(key)
    }

    func completeServerRequest(
        _ key: CodexServerRequestKey,
        reply: ServerRequestReply,
        tolerateMissing: Bool = false
    ) throws {
        guard let request = interactions.takeForLocalReply(key) else {
            if tolerateMissing { return }
            throw CodexSessionError.unknownServerRequest(key)
        }
        defer { releaseThreadForServerRequest(key) }
        try commitRequestInvalidation(scope: request.registration.scope)
        serverRequestTasks.removeValue(forKey: key)?.cancel()
        try enqueueServerResponse(key: key, reply: reply)
    }

    func enqueueServerResponse(
        key: CodexServerRequestKey,
        reply: ServerRequestReply
    ) throws {
        guard activeConnectionEpoch == key.connectionEpoch,
              case .ready(let epoch) = lifecycle,
              epoch == key.connectionEpoch else { return }

        let frame: Data
        switch reply {
        case .result(let result):
            frame = try CodexJSONRPCCodec.encodeResult(id: key.requestID, result: result)
        case .error(let error):
            frame = try CodexJSONRPCCodec.encodeError(
                id: key.requestID,
                error: .init(code: error.code, message: error.message, data: error.data)
            )
        }
        enqueueOutbound(.init(
            token: allocateOutboundToken(),
            connectionEpoch: key.connectionEpoch,
            correlation: .serverRequest(key),
            data: frame
        ))
    }

    func scopedServerRequests(
        scope: StateObservationScope
    ) -> [CodexPendingInteractionSnapshot] {
        guard scope.fields.contains(.requests) else { return [] }
        return interactions.pendingSnapshots().filter { request in
            switch scope.entities {
            case .all:
                return true
            case .global:
                return request.scope.threadID == nil
            case .threads(let threadIDs):
                guard let threadID = request.scope.threadID else { return false }
                return threadIDs.contains(ThreadID(threadID))
            case .turns(let turnKeys):
                guard let threadID = request.scope.threadID,
                      let turnID = request.scope.turnID else { return false }
                return turnKeys.contains(.init(
                    threadID: .init(threadID),
                    turnID: .init(turnID)
                ))
            case .items(let itemKeys):
                guard let threadID = request.scope.threadID,
                      let turnID = request.scope.turnID,
                      let itemID = request.scope.itemID else { return false }
                return itemKeys.contains(.init(
                    threadID: .init(threadID),
                    turnID: .init(turnID),
                    itemID: .init(itemID)
                ))
            }
        }
    }

    func makeServerRequestInboxSnapshot(
        entities: StateEntityScope
    ) -> CodexServerRequestInboxSnapshot {
        let scope = StateObservationScope(entities: entities, fields: .requests)
        let included = Set(scopedServerRequests(scope: scope).map(\.key))
        let requests = interactions.inboxEntries().filter { entry in
            included.contains(entry.key)
        }
        return .init(revision: graph.revision, requests: requests)
    }
}

// MARK: - Waiters and atomic operation facts

private extension CodexSession {
    func allocateWaiterID() -> UInt64 {
        precondition(nextWaiterID < UInt64.max, "Waiter identity space exhausted")
        defer { nextWaiterID += 1 }
        return nextWaiterID
    }

    func cancelStartWaiter(_ waiterID: UInt64) {
        startWaiters.removeValue(forKey: waiterID)?.resume(
            throwing: CancellationError()
        )
    }

    func resumeStartWaiters(with response: InitializeResponse) {
        let continuations = startWaiters.values
        startWaiters.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume(returning: response)
        }
    }

    func failStartWaiters(with error: Error) {
        let continuations = startWaiters.values
        startWaiters.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    func recordLoginCompletion(
        _ completion: CodexLoginCompletion,
        connectionEpoch: UInt64
    ) {
        let key = CodexLoginKey(
            connectionEpoch: connectionEpoch,
            identity: completion.loginID.map(CodexLoginIdentity.identified)
                ?? .anonymous
        )

        // A terminal notification is a fact. Duplicates cannot rewrite it.
        guard retainedLoginCompletions[key] == nil else { return }
        activeLoginKeys.remove(key)
        if key.identity == .anonymous {
            anonymousLoginRequestEpochs.remove(connectionEpoch)
        }
        retainedLoginOrder.append(key)
        retainedLoginCompletions[key] = completion
        while retainedLoginOrder.count
                > configuration.maximumRetainedLoginCompletions
        {
            let evicted = retainedLoginOrder.removeFirst()
            retainedLoginCompletions.removeValue(forKey: evicted)
        }

        if let waiters = loginWaiters.removeValue(forKey: key) {
            for continuation in waiters.values {
                continuation.resume(returning: completion)
            }
        }
    }

    func cancelLoginWaiter(key: CodexLoginKey, waiterID: UInt64) {
        guard let continuation = loginWaiters[key]?.removeValue(
            forKey: waiterID
        ) else { return }
        if loginWaiters[key]?.isEmpty == true {
            loginWaiters.removeValue(forKey: key)
        }
        continuation.resume(throwing: CancellationError())
    }

    func sealLoginAttempts(connectionEpoch: UInt64, error: Error) {
        let waiterKeys = loginWaiters.keys.filter {
            $0.connectionEpoch == connectionEpoch
        }
        for key in waiterKeys {
            guard let waiters = loginWaiters.removeValue(forKey: key) else {
                continue
            }
            for continuation in waiters.values {
                continuation.resume(throwing: error)
            }
        }
        activeLoginKeys = activeLoginKeys.filter {
            $0.connectionEpoch != connectionEpoch
        }
        anonymousLoginRequestEpochs.remove(connectionEpoch)
    }

    func terminalTurn(for key: TurnKey) -> CodexTerminalTurn? {
        guard let turn = graph.turns[key], turn.status.isTerminal else { return nil }
        let items = turn.itemOrder.compactMap { itemID in
            graph.items[.init(
                threadID: key.threadID,
                turnID: key.turnID,
                itemID: itemID
            )]
        }
        return .init(revision: graph.revision, turn: turn, items: items)
    }

    func resolveTerminalWaitersIfPossible() {
        for key in Array(terminalWaiters.keys) {
            guard let terminal = terminalTurn(for: key),
                  let waiters = terminalWaiters.removeValue(forKey: key) else {
                continue
            }
            for waiter in waiters.values {
                let release = leases.release(waiter.token)
                scheduleLeaseEffects(release.effects)
                waiter.continuation.resume(returning: terminal)
            }
        }
    }

    func cancelTerminalWaiter(key: TurnKey, waiterID: UInt64) {
        guard let waiter = terminalWaiters[key]?.removeValue(forKey: waiterID) else {
            return
        }
        if terminalWaiters[key]?.isEmpty == true {
            terminalWaiters.removeValue(forKey: key)
        }
        let release = leases.release(waiter.token)
        scheduleLeaseEffects(release.effects)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func resolveHistoryWaiters(
        threadID: ThreadID,
        history state: CanonicalHistoryState
    ) {
        guard let waiters = historyWaiters.removeValue(forKey: threadID) else {
            return
        }
        for waiter in waiters.values {
            waiter.continuation.resume(returning: state)
        }
    }

    func failHistoryWaiters(
        threadID: ThreadID,
        connectionEpoch: UInt64? = nil,
        error: Error
    ) {
        guard var waiters = historyWaiters[threadID] else { return }
        let matchingIDs: [UInt64] = waiters.compactMap { id, waiter -> UInt64? in
            guard connectionEpoch == nil || waiter.connectionEpoch == connectionEpoch else {
                return nil
            }
            return id
        }
        for id in matchingIDs {
            waiters.removeValue(forKey: id)?.continuation.resume(throwing: error)
        }
        if waiters.isEmpty {
            historyWaiters.removeValue(forKey: threadID)
        } else {
            historyWaiters[threadID] = waiters
        }
    }

    func cancelHistoryWaiter(threadID: ThreadID, waiterID: UInt64) {
        guard let waiter = historyWaiters[threadID]?.removeValue(forKey: waiterID) else {
            return
        }
        if historyWaiters[threadID]?.isEmpty == true {
            historyWaiters.removeValue(forKey: threadID)
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    func failOperationWaiters(with error: Error) {
        let loginContinuations = loginWaiters.values.flatMap(\.values)
        loginWaiters.removeAll(keepingCapacity: true)
        for continuation in loginContinuations {
            continuation.resume(throwing: error)
        }

        let turnWaiters = terminalWaiters.values.flatMap(\.values)
        terminalWaiters.removeAll(keepingCapacity: true)
        for waiter in turnWaiters {
            _ = leases.release(waiter.token)
            waiter.continuation.resume(throwing: error)
        }

        let historyContinuations = historyWaiters.values
            .flatMap(\.values)
            .map(\.continuation)
        historyWaiters.removeAll(keepingCapacity: true)
        for continuation in historyContinuations {
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - Thread lease effect execution

private extension CodexSession {
    func scheduleLeaseEffects(_ effects: [ThreadLeaseEffect]) {
        guard !effects.isEmpty else { return }
        for effect in effects {
            switch effect {
            case .reconcile(let command):
                scheduleHistoryEffects(history.beginReconciliation(command))
            case .unsubscribe:
                leaseEffectQueue.append(effect)
            case .evictDetail(let threadID):
                evictThreadDetailAfterUnsubscribe(threadID)
            }
        }
        guard !leaseEffectQueue.isEmpty else { return }
        guard leaseEffectDrainTask == nil else { return }
        leaseEffectDrainTask = Task { [weak self] in
            await self?.drainLeaseEffects()
        }
    }

    func drainLeaseEffects() async {
        while !leaseEffectQueue.isEmpty {
            let effect = leaseEffectQueue.removeFirst()
            await executeLeaseEffect(effect)
        }
        leaseEffectDrainTask = nil
    }

    func executeLeaseEffect(_ effect: ThreadLeaseEffect) async {
        switch effect {
        case .reconcile:
            return

        case .evictDetail:
            return

        case .unsubscribe(let command):
            guard activeConnectionEpoch == command.connectionEpoch else { return }
            do {
                _ = try await performCall(
                    method: .threadUnsubscribe,
                    params: .dictionary([
                        "threadId": .string(command.threadID.rawValue)
                    ])
                )
                scheduleLeaseEffects(leases.unsubscribeSucceeded(command))
            } catch {
                scheduleLeaseEffects(leases.unsubscribeFailed(
                    command,
                    message: String(describing: error)
                ))
            }
        }
    }

    func evictThreadDetailAfterUnsubscribe(_ threadID: ThreadID) {
        guard leases.snapshot(for: threadID) == nil else { return }
        unleasedThreadDetailLRU.removeAll { $0 == threadID }
        do {
            try commit(.threadDetailEvicted(threadID))
        } catch {
            if let epoch = activeConnectionEpoch {
                abortConnection(epoch, error: error)
            }
        }
    }

    func refreshThreadDetailRetention(for threadIDs: Set<ThreadID>) {
        do {
            try updateThreadDetailRetention(for: threadIDs)
        } catch {
            if let epoch = activeConnectionEpoch {
                abortConnection(epoch, error: error)
            }
        }
    }

    func updateThreadDetailRetention(for threadIDs: Set<ThreadID>) throws {
        for threadID in threadIDs.sorted() {
            unleasedThreadDetailLRU.removeAll { $0 == threadID }
            guard isWarmUnleasedThreadDetail(threadID) else { continue }
            unleasedThreadDetailLRU.append(threadID)
        }

        while unleasedThreadDetailLRU.count
            > configuration.maximumRetainedUnleasedThreadDetails {
            let threadID = unleasedThreadDetailLRU.removeFirst()
            guard isWarmUnleasedThreadDetail(threadID) else { continue }
            try commit(.threadDetailEvicted(threadID))
        }
    }

    func isWarmUnleasedThreadDetail(_ threadID: ThreadID) -> Bool {
        guard leases.snapshot(for: threadID) == nil,
              let thread = graph.threads[threadID]
        else { return false }
        let hasDetail = thread.isLoaded
            || !thread.turnOrder.isEmpty
            || thread.history.turnsCoverage != .notLoaded
            || thread.history.resumeCut != nil
            || !thread.history.itemPagesByTurn.isEmpty
        guard hasDetail, !thread.status.isActive else { return false }
        return !thread.turnOrder.contains { turnID in
            guard let turn = graph.turns[TurnKey(threadID: threadID, turnID: turnID)] else {
                return false
            }
            return !turn.status.isTerminal
        }
    }
}

// MARK: - Alpha.20 paginated history reconciliation

private extension CodexSession {
    func scheduleHistoryEffects(_ effects: [PaginatedHistoryEffect]) {
        guard !effects.isEmpty else { return }
        historyEffectQueue.append(contentsOf: effects)
        guard historyEffectDrainTask == nil else { return }
        historyEffectDrainTask = Task { [weak self] in
            await self?.drainHistoryEffects()
        }
    }

    func drainHistoryEffects() async {
        while !historyEffectQueue.isEmpty {
            let effect = historyEffectQueue.removeFirst()
            switch effect {
            case .requestResume(let request):
                launchHistoryRequest(effect, id: request.requestID)
            case .requestTurns(let request):
                launchHistoryRequest(effect, id: request.requestID)
            case .requestItems(let request):
                launchHistoryRequest(effect, id: request.requestID)
            case .install, .failed, .markStale:
                await executeHistoryEffect(effect)
            }
        }
        historyEffectDrainTask = nil
    }

    func launchHistoryRequest(
        _ effect: PaginatedHistoryEffect,
        id: PaginatedHistoryRequestID
    ) {
        guard historyRequestTasks[id] == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.executeTrackedHistoryRequest(effect, id: id)
        }
        historyRequestTasks[id] = task
    }

    func executeTrackedHistoryRequest(
        _ effect: PaginatedHistoryEffect,
        id: PaginatedHistoryRequestID
    ) async {
        defer { historyRequestTasks.removeValue(forKey: id) }
        await executeHistoryEffect(effect)
    }

    func executeHistoryEffect(_ effect: PaginatedHistoryEffect) async {
        switch effect {
        case .requestResume(let request):
            guard activeConnectionEpoch == request.reconciliation.connectionEpoch else {
                return
            }
            do {
                let call = try await performHistoryRequest(
                    method: .threadResume,
                    params: .dictionary([
                        "threadId": .string(request.reconciliation.threadID.rawValue),
                        "excludeTurns": .bool(request.excludeTurns),
                    ]),
                    connectionEpoch: request.reconciliation.connectionEpoch
                )
                let object = try historyObject(call.value, method: "thread/resume")
                guard let resumeThread = object["thread"] else {
                    throw CodexSessionError.protocolViolation(
                        "thread/resume omitted thread during history reconciliation"
                    )
                }
                let turnsCursor = try historyCursor(
                    object,
                    key: "turnsBackwardsCursor"
                )
                let itemsCursor = try historyCursor(
                    object,
                    key: "itemsBackwardsCursor"
                )
                try apply(adapter.adaptResponse(
                    .init(
                        method: .threadResume,
                        requestParams: [
                            "threadId": .string(request.reconciliation.threadID.rawValue),
                            "excludeTurns": .bool(request.excludeTurns),
                        ],
                        connectionEpoch: request.reconciliation.connectionEpoch,
                        resumeGeneration: request.reconciliation.operationID.rawValue,
                        itemCollectionPolicy: .mergePreservingExistingOrder
                    ),
                    result: call.value
                ))
                let historyEffects = history.receiveResumeCut(
                    threadID: request.reconciliation.threadID,
                    requestID: request.requestID,
                    turnsBackwardsCursor: turnsCursor,
                    itemsBackwardsCursor: itemsCursor,
                    responseCursor: call.responseCursor,
                    resumeThread: resumeThread,
                    resumeResult: call.value,
                    resumeRequestParams: [
                        "threadId": .string(request.reconciliation.threadID.rawValue),
                        "excludeTurns": .bool(request.excludeTurns),
                    ]
                )
                scheduleHistoryEffects(historyEffects)
                scheduleLeaseEffects(leases.reconciliationSucceeded(request.reconciliation))
                resolveHistoryWaiters(
                    threadID: request.reconciliation.threadID,
                    history: graph.threads[request.reconciliation.threadID]?.history ?? .init()
                )
            } catch {
                scheduleHistoryEffects(history.requestFailed(
                    threadID: request.reconciliation.threadID,
                    requestID: request.requestID,
                    message: String(describing: error)
                ))
            }

        case .requestTurns(let request):
            guard activeConnectionEpoch == request.reconciliation.connectionEpoch else {
                return
            }
            do {
                let call = try await performHistoryRequest(
                    method: .threadTurnsList,
                    params: .dictionary([
                        "threadId": .string(request.reconciliation.threadID.rawValue),
                        "cursor": .string(request.cursor),
                        "limit": .int(request.limit),
                        "sortDirection": .string(request.sortDirection.rawValue),
                        "itemsView": .string(request.itemsView.rawValue),
                    ]),
                    connectionEpoch: request.reconciliation.connectionEpoch
                )
                let object = try historyObject(call.value, method: "thread/turns/list")
                let rawTurns = try historyArray(object, key: "data")
                let records = try rawTurns.map { value -> PaginatedHistoryTurnRecord in
                    guard case .dictionary(let turn) = value,
                          case .string(let id)? = turn["id"] else {
                        throw CodexSessionError.protocolViolation(
                            "thread/turns/list returned a turn without an id"
                        )
                    }
                    return .init(turnID: .init(id), value: value)
                }
                try apply(adapter.adaptResponse(
                    .init(
                        method: .threadTurnsList,
                        requestParams: [
                            "threadId": .string(request.reconciliation.threadID.rawValue),
                            "cursor": .string(request.cursor),
                            "limit": .int(request.limit),
                            "sortDirection": .string(request.sortDirection.rawValue),
                            "itemsView": .string(request.itemsView.rawValue),
                        ],
                        connectionEpoch: request.reconciliation.connectionEpoch,
                        resumeGeneration: request.reconciliation.operationID.rawValue,
                        itemCollectionPolicy: .historyPage,
                        assertedItemsCoverage: .summary
                    ),
                    result: call.value
                ))
                scheduleHistoryEffects(history.receiveTurnsPage(
                    threadID: request.reconciliation.threadID,
                    requestID: request.requestID,
                    data: records,
                    backwardsCursor: try historyCursor(
                        object,
                        key: "backwardsCursor"
                    ),
                    nextCursor: try historyCursor(
                        object,
                        key: "nextCursor"
                    )
                ))
            } catch {
                scheduleHistoryEffects(history.requestFailed(
                    threadID: request.reconciliation.threadID,
                    requestID: request.requestID,
                    message: String(describing: error)
                ))
            }

        case .requestItems(let request):
            guard activeConnectionEpoch == request.reconciliation.connectionEpoch else {
                return
            }
            do {
                let call = try await performHistoryRequest(
                    method: .threadItemsList,
                    params: .dictionary([
                        "threadId": .string(request.reconciliation.threadID.rawValue),
                        "turnId": .string(request.turnID.rawValue),
                        "cursor": .string(request.cursor),
                        "limit": .int(request.limit),
                        "sortDirection": .string(request.sortDirection.rawValue),
                    ]),
                    connectionEpoch: request.reconciliation.connectionEpoch
                )
                let object = try historyObject(call.value, method: "thread/items/list")
                let rawEntries = try historyArray(object, key: "data")
                let records = try rawEntries.map { value -> PaginatedHistoryItemRecord in
                    guard case .dictionary(let entry) = value,
                          case .string(let turnID)? = entry["turnId"],
                          case .dictionary(let item)? = entry["item"],
                          case .string(let itemID)? = item["id"] else {
                        throw CodexSessionError.protocolViolation(
                            "thread/items/list returned an entry without composite identity"
                        )
                    }
                    return .init(
                        turnID: .init(turnID),
                        itemID: .init(itemID),
                        value: .dictionary(item)
                    )
                }
                var incrementalResult = object
                incrementalResult["data"] = .array(Array(rawEntries.reversed()))
                let nextCursor = try historyCursor(object, key: "nextCursor")
                try apply(adapter.adaptResponse(
                    .init(
                        method: .threadItemsList,
                        requestParams: [
                            "threadId": .string(request.reconciliation.threadID.rawValue),
                            "turnId": .string(request.turnID.rawValue),
                            "cursor": .string(request.cursor),
                            "limit": .int(request.limit),
                            "sortDirection": .string(request.sortDirection.rawValue),
                        ],
                        connectionEpoch: request.reconciliation.connectionEpoch,
                        resumeGeneration: request.reconciliation.operationID.rawValue,
                        itemCollectionPolicy: .historyPage,
                        assertedItemsCoverage: nextCursor == nil ? .full : .summary
                    ),
                    result: .dictionary(incrementalResult)
                ))
                scheduleHistoryEffects(history.receiveItemsPage(
                    threadID: request.reconciliation.threadID,
                    turnID: request.turnID,
                    requestID: request.requestID,
                    data: records,
                    backwardsCursor: try historyCursor(
                        object,
                        key: "backwardsCursor"
                    ),
                    nextCursor: nextCursor
                ))
            } catch {
                scheduleHistoryEffects(history.requestFailed(
                    threadID: request.reconciliation.threadID,
                    requestID: request.requestID,
                    message: String(describing: error)
                ))
            }

        case .install(let installation):
            do {
                try installPaginatedHistory(installation)
            } catch {
                failHistoryWaiters(
                    threadID: installation.reconciliation.threadID,
                    connectionEpoch: installation.reconciliation.connectionEpoch,
                    error: CodexSessionError.historyReconciliationFailed(
                        threadID: installation.reconciliation.threadID,
                        message: String(describing: error)
                    )
                )
            }

        case .failed(let failure):
            if case .requestFailed(kind: .resume, message: _) = failure.reason {
                // The temporary lease registry cannot represent an unknown
                // subscription outcome yet. Preserve its existing retry/error
                // behavior for failures before a resume response; page failures
                // must not tear down a subscription already established.
                leases.reconciliationFailed(
                    failure.reconciliation,
                    message: String(describing: failure.reason)
                )
            }
            failHistoryWaiters(
                threadID: failure.reconciliation.threadID,
                connectionEpoch: failure.reconciliation.connectionEpoch,
                error: CodexSessionError.historyReconciliationFailed(
                    threadID: failure.reconciliation.threadID,
                    message: String(describing: failure.reason)
                )
            )

        case .markStale(let transition):
            var state = graph.threads[transition.threadID]?.history ?? .init()
            state.isStaleAfterReconnect = true
            try? commit(.threadHistoryUpdated(
                id: transition.threadID,
                history: state
            ))
        }
    }

    func performHistoryRequest(
        method: CodexAppServerClientMethod,
        params: CodexJSONValue,
        connectionEpoch: UInt64
    ) async throws -> CodexSessionCallResult {
        guard case .ready(let epoch) = lifecycle,
              epoch == connectionEpoch,
              activeConnectionEpoch == connectionEpoch else {
            throw CodexSessionError.notReady(lifecycle)
        }
        return try await beginClientRequest(
            method: method,
            params: params,
            connectionEpoch: connectionEpoch,
            submissionIntent: nil,
            isHandshake: false,
            reducesResponse: false
        )
    }

    func installPaginatedHistory(
        _ installation: PaginatedHistoryInstallation
    ) throws {
        let command = installation.reconciliation
        guard activeConnectionEpoch == command.connectionEpoch else {
            throw CodexSessionError.connectionLost(
                connectionEpoch: command.connectionEpoch,
                message: "History installation belongs to a sealed epoch"
            )
        }
        let threadID = command.threadID
        // Resume and each durable page were already reduced as they arrived.
        // Completion only publishes final coverage/cursor bookkeeping.
        try commit(.threadHistoryReplaced(
            id: threadID,
            history: installation.historyState
        ))
        if installation.crossedConnectionGap {
            for turn in graph.turns.values
            where turn.key.threadID == threadID && turn.status == .inProgress {
                try commit(.turnItemsMarkedUncertain(turn.key))
            }
        }
        resolveTerminalWaitersIfPossible()
        resolveHistoryWaiters(
            threadID: threadID,
            history: graph.threads[threadID]?.history ?? installation.historyState
        )
    }

    func historyObject(
        _ value: CodexJSONValue,
        method: String
    ) throws -> [String: CodexJSONValue] {
        guard case .dictionary(let object) = value else {
            throw CodexSessionError.protocolViolation("\(method) result must be an object")
        }
        return object
    }

    func historyArray(
        _ object: [String: CodexJSONValue],
        key: String
    ) throws -> [CodexJSONValue] {
        guard case .array(let values)? = object[key] else {
            throw CodexSessionError.protocolViolation(
                "History page omitted array field \(key)"
            )
        }
        return values
    }

    func historyCursor(
        _ object: [String: CodexJSONValue],
        key: String
    ) throws -> String? {
        guard let value = object[key] else {
            return nil
        }
        switch value {
        case .null:
            return nil
        case .string(let cursor):
            return cursor
        default:
            throw CodexSessionError.protocolViolation(
                "History cursor \(key) must be string or null"
            )
        }
    }

    func notificationThreadID(
        _ params: [String: CodexJSONValue]
    ) -> ThreadID? {
        if case .string(let threadID)? = params["threadId"] {
            return .init(threadID)
        }
        if case .dictionary(let thread)? = params["thread"],
           case .string(let threadID)? = thread["id"] {
            return .init(threadID)
        }
        return nil
    }
}

// MARK: - Non-reducer session invalidations

private extension CodexSession {
    func publishStateInvalidation(
        _ invalidation: StateInvalidation,
        removedThreadIDs: Set<ThreadID> = [],
        attentionExcludedThreadIDs: Set<ThreadID> = []
    ) {
        precondition(invalidation.revision == graph.revision)
        if !invalidation.fields.intersection(CanonicalThreadIndexSnapshot.attentionFields).isEmpty {
            for threadID in invalidation.threadIDs.subtracting(attentionExcludedThreadIDs) {
                threadAttentionRevisions[threadID] = invalidation.revision
            }
        }
        for threadID in removedThreadIDs {
            threadAttentionRevisions.removeValue(forKey: threadID)
        }
        observations.publish(invalidation)
    }

    func commitSessionInvalidation(
        fields: StateFieldMask,
        threadIDs: Set<ThreadID> = [],
        turnKeys: Set<TurnKey> = [],
        itemKeys: Set<ItemKey> = []
    ) throws {
        guard graph.revision.rawValue < UInt64.max else {
            throw CodexSessionError.stateCommitFailed("State revision space exhausted")
        }
        graph.revision = graph.revision.successor
        publishStateInvalidation(.init(
            revision: graph.revision,
            fields: fields,
            threadIDs: threadIDs,
            turnKeys: turnKeys,
            itemKeys: itemKeys
        ))
    }
}
