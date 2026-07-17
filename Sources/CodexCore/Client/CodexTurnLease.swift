import Foundation

public enum CodexLeaseError: Error, Sendable, Equatable, CustomStringConvertible {
    case closedThread(ThreadID)
    case unknownTurn(TurnKey)
    case requestThreadMismatch(expected: ThreadID, actual: ThreadID)
    case requestTurnMismatch(expected: TurnKey, actual: TurnKey)
    case responseThreadMismatch(expected: ThreadID, actual: ThreadID)
    case responseTurnMismatch(expected: TurnKey, actual: TurnKey)
    case turnTimedOut(TurnKey)

    public var description: String {
        switch self {
        case .closedThread(let id):
            "Thread lease for \(id) is closed"
        case .unknownTurn(let key):
            "Canonical state does not contain turn \(key)"
        case .requestThreadMismatch(let expected, let actual):
            "Request targets thread \(actual), but lease owns \(expected)"
        case .requestTurnMismatch(let expected, let actual):
            "Request targets turn \(actual), but lease owns \(expected)"
        case .responseThreadMismatch(let expected, let actual):
            "App-server returned thread \(actual), expected \(expected)"
        case .responseTurnMismatch(let expected, let actual):
            "App-server returned turn \(actual), expected \(expected)"
        case .turnTimedOut(let key):
            "Turn \(key) did not become terminal before the timeout"
        }
    }
}

/// A retention lease for one app-server thread.
///
/// The session actor owns subscription state and reconciliation. This class owns
/// only the capability token that keeps the thread's canonical detail retained.
/// Call `close()` for deterministic release; deinitialization is a best-effort
/// fallback.
public final class CodexThreadLease: @unchecked Sendable {
    public let id: ThreadID
    public let startRevision: StateRevision
    public let responseRevision: StateRevision

    fileprivate let session: CodexSession
    private let lock = NSLock()
    private var token: ThreadLeaseToken?

    internal init(
        id: ThreadID,
        startRevision: StateRevision,
        responseRevision: StateRevision,
        session: CodexSession,
        token: ThreadLeaseToken
    ) {
        self.id = id
        self.startRevision = startRevision
        self.responseRevision = responseRevision
        self.session = session
        self.token = token
    }

    deinit {
        guard let token = takeToken() else { return }
        let session = session
        Task {
            await session.releaseThreadLease(token)
        }
    }

    public var isClosed: Bool {
        lock.withLock { token == nil }
    }

    public func close() async {
        guard let token = takeToken() else { return }
        await session.releaseThreadLease(token)
    }

    public func snapshot(
        fields: StateFieldMask = .all
    ) async throws -> CanonicalStateSnapshot {
        try requireOpen()
        return await session.canonicalSnapshot(scope: .thread(id, fields: fields))
    }

    public func observe(
        fields: StateFieldMask = .all
    ) async throws -> StateObservation<CanonicalStateSnapshot> {
        try requireOpen()
        return await session.observe(scope: .thread(id, fields: fields))
    }

    public func catchUp(
        _ observation: StateObservation<CanonicalStateSnapshot>,
        after revision: StateRevision
    ) async throws -> StateCatchUp {
        try requireOpen()
        return await session.catchUp(observationID: observation.id, after: revision)
    }

    public func cancel(
        _ observation: StateObservation<CanonicalStateSnapshot>
    ) async {
        await session.cancelObservation(observation.id)
    }

    public func fork(
        _ params: CodexSchemaThreadForkParams
    ) async throws -> CodexThreadLease {
        try requireOpen()
        let actual = ThreadID(params.threadID)
        guard actual == id else {
            throw CodexLeaseError.requestThreadMismatch(expected: id, actual: actual)
        }
        return try await session.forkThread(params)
    }

    public func startTurn(
        _ suppliedParams: CodexSchemaTurnStartParams
    ) async throws -> CodexTurnLease {
        try requireOpen()
        let actualThreadID = ThreadID(suppliedParams.threadID)
        guard actualThreadID == id else {
            throw CodexLeaseError.requestThreadMismatch(expected: id, actual: actualThreadID)
        }

        var params = suppliedParams
        let requestedIntentID = params.clientUserMessageID.map { SubmissionIntentID($0) }
        let intent = await session.makeSubmissionIntent(
            threadID: id,
            expectedTurnID: nil,
            input: params.input.map(\.rawValue),
            clientUserMessageID: requestedIntentID
        )
        params.clientUserMessageID = intent.id.rawValue

        let request = CodexRequest.turnStart(params)
        let call = try await session.performCall(
            method: request.method,
            params: try request.encodeParameters(),
            submissionIntent: intent
        )
        let response = try call.value.decode(CodexSchemaTurnStartResponse.self)
        let key = TurnKey(threadID: id, turnID: TurnID(response.turn.id))
        return CodexTurnLease(
            key: key,
            startRevision: call.startRevision,
            responseRevision: call.responseRevision,
            thread: self
        )
    }

    /// Starts a turn and returns the exact atomic canonical terminal result.
    /// No presentation-layer text flattening or polling is involved.
    public func runTurn(
        _ params: CodexSchemaTurnStartParams,
        timeout: Duration? = nil
    ) async throws -> CodexTerminalTurn {
        let turn = try await startTurn(params)
        return try await turn.awaitTerminal(timeout: timeout)
    }

    /// Attaches a truthless turn capability to an existing canonical turn.
    ///
    /// This is used after resuming a thread whose latest turn is still active.
    /// The enclosing thread lease already owns subscription and retention, so
    /// attaching does not create another state owner or protocol request.
    public func attachTurn(_ turnID: TurnID) async throws -> CodexTurnLease {
        try requireOpen()
        let key = TurnKey(threadID: id, turnID: turnID)
        let snapshot = await session.canonicalSnapshot(
            scope: .turn(key, fields: .turnStatus)
        )
        try requireOpen()
        guard snapshot.turns[key] != nil else {
            throw CodexLeaseError.unknownTurn(key)
        }
        return CodexTurnLease(
            key: key,
            startRevision: snapshot.revision,
            responseRevision: snapshot.revision,
            thread: self
        )
    }

    fileprivate func requireOpen() throws {
        guard !isClosed else { throw CodexLeaseError.closedThread(id) }
    }

    private func takeToken() -> ThreadLeaseToken? {
        lock.withLock {
            defer { token = nil }
            return token
        }
    }
}

/// A truthless handle to one composite `(thread, turn)` identity.
///
/// State and waiters live in `CodexSession`; copying this value does not create
/// another subscription, reducer, stream, or retention owner.
public struct CodexTurnLease: Sendable {
    public let key: TurnKey
    public let startRevision: StateRevision
    public let responseRevision: StateRevision

    private let thread: CodexThreadLease

    internal init(
        key: TurnKey,
        startRevision: StateRevision,
        responseRevision: StateRevision,
        thread: CodexThreadLease
    ) {
        self.key = key
        self.startRevision = startRevision
        self.responseRevision = responseRevision
        self.thread = thread
    }

    public func snapshot(
        fields: StateFieldMask = .all
    ) async throws -> CanonicalStateSnapshot {
        try thread.requireOpen()
        return await thread.session.canonicalSnapshot(scope: .turn(key, fields: fields))
    }

    public func observe(
        fields: StateFieldMask = .all
    ) async throws -> StateObservation<CanonicalStateSnapshot> {
        try thread.requireOpen()
        return await thread.session.observe(scope: .turn(key, fields: fields))
    }

    public func catchUp(
        _ observation: StateObservation<CanonicalStateSnapshot>,
        after revision: StateRevision
    ) async throws -> StateCatchUp {
        try thread.requireOpen()
        return await thread.session.catchUp(observationID: observation.id, after: revision)
    }

    public func cancel(
        _ observation: StateObservation<CanonicalStateSnapshot>
    ) async {
        await thread.session.cancelObservation(observation.id)
    }

    public func awaitTerminal(
        timeout: Duration? = nil
    ) async throws -> CodexTerminalTurn {
        try thread.requireOpen()
        guard let timeout else {
            return try await thread.session.awaitTerminalTurn(key)
        }

        return try await withThrowingTaskGroup(of: CodexTerminalTurn.self) { group in
            group.addTask {
                try await thread.session.awaitTerminalTurn(key)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CodexLeaseError.turnTimedOut(key)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    public func interrupt() async throws {
        try thread.requireOpen()
        _ = try await thread.session.perform(CodexRequest.turnInterrupt(
            .init(threadID: key.threadID.rawValue, turnID: key.turnID.rawValue)
        ))
    }

    @discardableResult
    public func steer(
        _ suppliedParams: CodexSchemaTurnSteerParams
    ) async throws -> CodexSchemaTurnSteerResponse {
        try thread.requireOpen()
        let actualKey = TurnKey(
            threadID: ThreadID(suppliedParams.threadID),
            turnID: TurnID(suppliedParams.expectedTurnID)
        )
        guard actualKey == key else {
            throw CodexLeaseError.requestTurnMismatch(expected: key, actual: actualKey)
        }

        var params = suppliedParams
        let requestedIntentID = params.clientUserMessageID.map { SubmissionIntentID($0) }
        let intent = await thread.session.makeSubmissionIntent(
            threadID: key.threadID,
            expectedTurnID: key.turnID,
            input: params.input.map(\.rawValue),
            clientUserMessageID: requestedIntentID
        )
        params.clientUserMessageID = intent.id.rawValue

        let request = CodexRequest.turnSteer(params)
        let call = try await thread.session.performCall(
            method: request.method,
            params: try request.encodeParameters(),
            submissionIntent: intent
        )
        let response = try call.value.decode(CodexSchemaTurnSteerResponse.self)
        let responseKey = TurnKey(
            threadID: key.threadID,
            turnID: TurnID(response.turnID)
        )
        guard responseKey == key else {
            throw CodexLeaseError.responseTurnMismatch(expected: key, actual: responseKey)
        }
        return response
    }
}

public extension CodexSession {
    func startThread(
        _ params: CodexSchemaThreadStartParams = .init()
    ) async throws -> CodexThreadLease {
        let request = CodexRequest.threadStart(params)
        let call = try await performCall(
            method: request.method,
            params: try request.encodeParameters(),
            submissionIntent: nil
        )
        let response = try call.value.decode(CodexSchemaThreadStartResponse.self)
        let id = ThreadID(response.thread.id)
        let token = try adoptThreadSubscription(
            threadID: id,
            reason: .explicitObserver("CodexThreadLease")
        )
        return CodexThreadLease(
            id: id,
            startRevision: call.startRevision,
            responseRevision: call.responseRevision,
            session: self,
            token: token
        )
    }

    func resumeThread(
        _ params: CodexSchemaThreadResumeParams
    ) async throws -> CodexThreadLease {
        let request = CodexRequest.threadResume(params)
        let encodedParams = try request.encodeParameters()
        guard case .dictionary? = encodedParams else {
            throw CodexSessionError.protocolViolation(
                "thread/resume parameters must be an object"
            )
        }
        let call = try await performCall(
            method: request.method,
            params: encodedParams,
            submissionIntent: nil,
            resumeHistoryReason: .explicitObserver("CodexThreadLease")
        )
        let response = try call.value.decode(CodexSchemaThreadResumeResponse.self)
        let expected = ThreadID(params.threadID)
        let actual = ThreadID(response.thread.id)
        guard actual == expected else {
            throw CodexLeaseError.responseThreadMismatch(expected: expected, actual: actual)
        }
        guard let token = call.threadLeaseToken else {
            throw CodexSessionError.historyReconciliationFailed(
                threadID: actual,
                message: "thread/resume returned without an adopted history lease"
            )
        }
        do {
            _ = try await awaitThreadHistory(actual)
        } catch {
            releaseThreadLease(token)
            throw error
        }
        return CodexThreadLease(
            id: actual,
            startRevision: call.startRevision,
            responseRevision: call.responseRevision,
            session: self,
            token: token
        )
    }

    func forkThread(
        _ params: CodexSchemaThreadForkParams
    ) async throws -> CodexThreadLease {
        let request = CodexRequest.threadFork(params)
        let call = try await performCall(
            method: request.method,
            params: try request.encodeParameters(),
            submissionIntent: nil
        )
        let response = try call.value.decode(CodexSchemaThreadForkResponse.self)
        let id = ThreadID(response.thread.id)
        let token = try adoptThreadSubscription(
            threadID: id,
            reason: .explicitObserver("CodexThreadLease")
        )
        return CodexThreadLease(
            id: id,
            startRevision: call.startRevision,
            responseRevision: call.responseRevision,
            session: self,
            token: token
        )
    }
}
