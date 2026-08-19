import Foundation

/// Stable identity for one retention lease. Tokens are allocated by a
/// `ThreadLeaseRegistry`, making tests and emitted effects deterministic.
public struct ThreadLeaseToken: Sendable, Hashable, Codable, Comparable {
    public let rawValue: UInt64
    public let threadID: ThreadID

    public init(rawValue: UInt64, threadID: ThreadID) {
        self.rawValue = rawValue
        self.threadID = threadID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.rawValue, lhs.threadID) < (rhs.rawValue, rhs.threadID)
    }
}

/// Why a thread's canonical detail and app-server subscription must be kept.
///
/// Reasons are deliberately semantic rather than presentation-specific. The
/// registry uses their priority only to order reconnect work; it never infers
/// thread lifecycle from them.
public enum ThreadLeaseReason: Sendable, Hashable, Codable {
    case activeTurn(TurnID)
    case terminalWaiter(String)
    case pendingServerRequest(String)
    case selectedUI
    case sideChat
    case ephemeralOwner(String)
    case subagentObserver(ThreadID)
    case explicitObserver(String)
    case warmAttention

    fileprivate var reconnectPriority: Int {
        switch self {
        case .activeTurn, .terminalWaiter, .pendingServerRequest, .ephemeralOwner:
            0
        case .selectedUI, .sideChat:
            1
        case .subagentObserver, .explicitObserver, .warmAttention:
            2
        }
    }
}

/// Identifies one in-flight subscribe/reconcile or unsubscribe operation.
/// Responses carrying an older operation id are stale and have no effect.
public struct ThreadLeaseOperationID: RawRepresentable, Sendable, Hashable, Codable, Comparable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ThreadReconciliationCommand: Sendable, Equatable {
    public let threadID: ThreadID
    public let connectionEpoch: UInt64
    public let operationID: ThreadLeaseOperationID

    public init(
        threadID: ThreadID,
        connectionEpoch: UInt64,
        operationID: ThreadLeaseOperationID
    ) {
        self.threadID = threadID
        self.connectionEpoch = connectionEpoch
        self.operationID = operationID
    }
}

public struct ThreadUnsubscribeCommand: Sendable, Equatable {
    public let threadID: ThreadID
    public let connectionEpoch: UInt64
    public let operationID: ThreadLeaseOperationID

    public init(
        threadID: ThreadID,
        connectionEpoch: UInt64,
        operationID: ThreadLeaseOperationID
    ) {
        self.threadID = threadID
        self.connectionEpoch = connectionEpoch
        self.operationID = operationID
    }
}

/// Work for the owning `CodexSession` actor. The registry never performs I/O.
public enum ThreadLeaseEffect: Sendable, Equatable {
    case reconcile(ThreadReconciliationCommand)
    case unsubscribe(ThreadUnsubscribeCommand)
    /// The current unsubscribe completed with no replacement lease. Canonical
    /// transcript detail can now be discarded without racing a live frame from
    /// the subscription being torn down.
    case evictDetail(ThreadID)
}

public enum ThreadLeaseSubscriptionState: Sendable, Equatable {
    /// No subscription is desired or known to exist.
    case idle
    /// At least one lease exists, but there is no usable connection.
    case stale
    /// Mode discovery and the corresponding resume reconciliation are in flight.
    case reconciling(connectionEpoch: UInt64, operationID: ThreadLeaseOperationID)
    /// The subscription is usable; paginated backfill may continue independently.
    case live(connectionEpoch: UInt64)
    /// The final lease disappeared while reconciliation was still in flight.
    case releaseAfterReconciliation(connectionEpoch: UInt64, operationID: ThreadLeaseOperationID)
    /// `thread/unsubscribe` is in flight and no lease currently exists.
    case unsubscribing(connectionEpoch: UInt64, operationID: ThreadLeaseOperationID)
    /// A lease returned while unsubscribe was in flight. Resume after its result.
    case reconcileAfterUnsubscribe(connectionEpoch: UInt64, operationID: ThreadLeaseOperationID)
    /// The last explicit reconciliation/unsubscribe attempt failed.
    case failed(connectionEpoch: UInt64?, message: String)
}

public struct ThreadLeaseSnapshot: Sendable, Equatable {
    public let threadID: ThreadID
    public let leases: [(token: ThreadLeaseToken, reason: ThreadLeaseReason)]
    public let subscriptionState: ThreadLeaseSubscriptionState

    public init(
        threadID: ThreadID,
        leases: [(token: ThreadLeaseToken, reason: ThreadLeaseReason)],
        subscriptionState: ThreadLeaseSubscriptionState
    ) {
        self.threadID = threadID
        self.leases = leases
        self.subscriptionState = subscriptionState
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.threadID == rhs.threadID
            && lhs.subscriptionState == rhs.subscriptionState
            && lhs.leases.elementsEqual(rhs.leases) { left, right in
                left.token == right.token && left.reason == right.reason
            }
    }
}

public struct ThreadLeaseAcquisition: Sendable, Equatable {
    public let token: ThreadLeaseToken
    public let effects: [ThreadLeaseEffect]

    public init(token: ThreadLeaseToken, effects: [ThreadLeaseEffect]) {
        self.token = token
        self.effects = effects
    }
}

/// A lease plus reconciliation identity for a `thread/resume` request whose
/// response has already established the current subscription and history cut.
public struct ThreadLeaseSeededReconciliation: Sendable, Equatable {
    public let token: ThreadLeaseToken
    public let reconciliation: ThreadReconciliationCommand

    public init(
        token: ThreadLeaseToken,
        reconciliation: ThreadReconciliationCommand
    ) {
        self.token = token
        self.reconciliation = reconciliation
    }
}

public struct ThreadLeaseRelease: Sendable, Equatable {
    public let didRelease: Bool
    public let effects: [ThreadLeaseEffect]

    public init(didRelease: Bool, effects: [ThreadLeaseEffect]) {
        self.didRelease = didRelease
        self.effects = effects
    }
}

/// Synchronous subscription-intent state owned by the sole `CodexSession` actor.
///
/// It handles release/reacquire races without assuming JSON-RPC response order.
/// Every emitted operation carries an id; late completions become deterministic
/// no-ops instead of changing the desired subscription state.
public struct ThreadLeaseRegistry: Sendable {
    private struct Entry: Sendable {
        var leases: [ThreadLeaseToken: ThreadLeaseReason] = [:]
        var state: ThreadLeaseSubscriptionState = .idle

        var reconnectPriority: Int {
            leases.values.map(\.reconnectPriority).min() ?? Int.max
        }
    }

    private var entries: [ThreadID: Entry] = [:]
    private var activeConnectionEpoch: UInt64?
    private var nextTokenRawValue: UInt64 = 1
    private var nextOperationRawValue: UInt64 = 1

    public init() {}

    public var connectionEpoch: UInt64? {
        activeConnectionEpoch
    }

    public var leasedThreadIDs: [ThreadID] {
        entries
            .filter { !$0.value.leases.isEmpty }
            .map(\.key)
            .sorted()
    }

    public func snapshot(for threadID: ThreadID) -> ThreadLeaseSnapshot? {
        guard let entry = entries[threadID] else { return nil }
        return Self.snapshot(threadID: threadID, entry: entry)
    }

    public func snapshots() -> [ThreadLeaseSnapshot] {
        entries
            .sorted { $0.key < $1.key }
            .map { Self.snapshot(threadID: $0.key, entry: $0.value) }
    }

    /// Acquires a lease. The first lease reconciles immediately when a ready
    /// connection exists; otherwise it remains stale until `connectionReady`.
    public mutating func acquire(
        threadID: ThreadID,
        reason: ThreadLeaseReason
    ) -> ThreadLeaseAcquisition {
        let token = allocateToken(threadID: threadID)
        var entry = entries[threadID] ?? Entry()
        let wasEmpty = entry.leases.isEmpty
        entry.leases[token] = reason

        var effects: [ThreadLeaseEffect] = []
        if wasEmpty {
            switch entry.state {
            case .unsubscribing(let epoch, let operationID):
                entry.state = .reconcileAfterUnsubscribe(
                    connectionEpoch: epoch,
                    operationID: operationID
                )
            case .releaseAfterReconciliation(let epoch, let operationID):
                entry.state = .reconciling(
                    connectionEpoch: epoch,
                    operationID: operationID
                )
            case .reconciling, .live, .reconcileAfterUnsubscribe:
                break
            case .idle, .stale, .failed:
                if let epoch = activeConnectionEpoch {
                    effects = [beginReconciliation(threadID: threadID, epoch: epoch, entry: &entry)]
                } else {
                    entry.state = .stale
                }
            }
        }

        entries[threadID] = entry
        return ThreadLeaseAcquisition(token: token, effects: effects)
    }

    /// Acquires the first lease for a thread that `thread/start` or
    /// `thread/fork` already subscribed on the current connection.
    public mutating func acquireAdoptingLiveSubscription(
        threadID: ThreadID,
        reason: ThreadLeaseReason,
        connectionEpoch: UInt64
    ) -> ThreadLeaseAcquisition {
        let token = allocateToken(threadID: threadID)
        var entry = entries[threadID] ?? Entry()
        precondition(entry.leases.isEmpty, "A live subscription can only be adopted for the first lease")
        precondition(
            activeConnectionEpoch == connectionEpoch,
            "Cannot adopt a subscription from a non-current connection"
        )
        entry.leases[token] = reason
        entry.state = .live(connectionEpoch: connectionEpoch)
        entries[threadID] = entry
        return ThreadLeaseAcquisition(token: token, effects: [])
    }

    /// Adopts a successful explicit `thread/resume` without emitting another
    /// resume effect. The owning session completes legacy history immediately or
    /// seeds paginated history from that same response.
    public mutating func acquireAdoptingResumeReconciliation(
        threadID: ThreadID,
        reason: ThreadLeaseReason,
        connectionEpoch: UInt64
    ) -> ThreadLeaseSeededReconciliation {
        precondition(
            activeConnectionEpoch == connectionEpoch,
            "Cannot adopt a resume from a non-current connection"
        )
        let token = allocateToken(threadID: threadID)
        let operationID = allocateOperationID()
        var entry = entries[threadID] ?? Entry()
        entry.leases[token] = reason
        entry.state = .reconciling(
            connectionEpoch: connectionEpoch,
            operationID: operationID
        )
        entries[threadID] = entry
        return .init(
            token: token,
            reconciliation: .init(
                threadID: threadID,
                connectionEpoch: connectionEpoch,
                operationID: operationID
            )
        )
    }

    @discardableResult
    public mutating func release(_ token: ThreadLeaseToken) -> ThreadLeaseRelease {
        guard var entry = entries[token.threadID], entry.leases.removeValue(forKey: token) != nil else {
            return ThreadLeaseRelease(didRelease: false, effects: [])
        }

        guard entry.leases.isEmpty else {
            entries[token.threadID] = entry
            return ThreadLeaseRelease(didRelease: true, effects: [])
        }

        var effects: [ThreadLeaseEffect] = []
        switch entry.state {
        case .live(let epoch):
            effects = [beginUnsubscribe(threadID: token.threadID, epoch: epoch, entry: &entry)]
        case .reconciling(let epoch, let operationID):
            entry.state = .releaseAfterReconciliation(
                connectionEpoch: epoch,
                operationID: operationID
            )
        case .reconcileAfterUnsubscribe(let epoch, let operationID):
            entry.state = .unsubscribing(connectionEpoch: epoch, operationID: operationID)
        case .unsubscribing, .releaseAfterReconciliation:
            break
        case .idle, .stale, .failed:
            entries.removeValue(forKey: token.threadID)
            return ThreadLeaseRelease(didRelease: true, effects: [])
        }

        entries[token.threadID] = entry
        return ThreadLeaseRelease(didRelease: true, effects: effects)
    }

    /// Promotes a physical connection to ready and emits deterministic
    /// reconciliation work: active/waiter scopes, selected scopes, then background.
    public mutating func connectionReady(_ connectionEpoch: UInt64) -> [ThreadLeaseEffect] {
        activeConnectionEpoch = connectionEpoch

        let orderedThreadIDs = entries
            .filter { !$0.value.leases.isEmpty }
            .map { (threadID: $0.key, reconnectPriority: $0.value.reconnectPriority) }
            .sorted { lhs, rhs in
                (lhs.reconnectPriority, lhs.threadID) < (rhs.reconnectPriority, rhs.threadID)
            }
            .map(\.threadID)

        var effects: [ThreadLeaseEffect] = []
        for threadID in orderedThreadIDs {
            guard var entry = entries[threadID] else { continue }
            effects.append(beginReconciliation(threadID: threadID, epoch: connectionEpoch, entry: &entry))
            entries[threadID] = entry
        }
        return effects
    }

    /// Seals one connection epoch. Old operation completions are ignored after
    /// this transition, and leased scopes remain explicitly stale.
    public mutating func connectionLost(_ connectionEpoch: UInt64) {
        guard activeConnectionEpoch == connectionEpoch else { return }
        activeConnectionEpoch = nil

        for threadID in Array(entries.keys) {
            guard var entry = entries[threadID] else { continue }
            if entry.leases.isEmpty {
                entries.removeValue(forKey: threadID)
            } else {
                entry.state = .stale
                entries[threadID] = entry
            }
        }
    }

    /// Marks resume usable after inline legacy history or paginated anchors were
    /// installed. If the last lease disappeared meanwhile, unsubscribe is emitted.
    public mutating func reconciliationSucceeded(
        _ command: ThreadReconciliationCommand
    ) -> [ThreadLeaseEffect] {
        guard var entry = entries[command.threadID] else { return [] }

        switch entry.state {
        case .reconciling(command.connectionEpoch, command.operationID):
            guard !entry.leases.isEmpty else { return [] }
            entry.state = .live(connectionEpoch: command.connectionEpoch)
            entries[command.threadID] = entry
            return []
        case .releaseAfterReconciliation(command.connectionEpoch, command.operationID):
            guard entry.leases.isEmpty else { return [] }
            let effect = beginUnsubscribe(
                threadID: command.threadID,
                epoch: command.connectionEpoch,
                entry: &entry
            )
            entries[command.threadID] = entry
            return [effect]
        default:
            return []
        }
    }

    public mutating func reconciliationFailed(
        _ command: ThreadReconciliationCommand,
        message: String
    ) {
        guard var entry = entries[command.threadID] else { return }

        switch entry.state {
        case .reconciling(command.connectionEpoch, command.operationID):
            if entry.leases.isEmpty {
                entries.removeValue(forKey: command.threadID)
            } else {
                entry.state = .failed(connectionEpoch: command.connectionEpoch, message: message)
                entries[command.threadID] = entry
            }
        case .releaseAfterReconciliation(command.connectionEpoch, command.operationID):
            entries.removeValue(forKey: command.threadID)
        default:
            break
        }
    }

    public mutating func retryReconciliation(threadID: ThreadID) -> [ThreadLeaseEffect] {
        guard let epoch = activeConnectionEpoch,
              var entry = entries[threadID],
              !entry.leases.isEmpty else { return [] }

        guard case .failed = entry.state else { return [] }
        let effect = beginReconciliation(threadID: threadID, epoch: epoch, entry: &entry)
        entries[threadID] = entry
        return [effect]
    }

    /// Completes an unsubscribe. A lease acquired while it was in flight causes
    /// a new reconciliation; a stale completion otherwise changes nothing.
    public mutating func unsubscribeSucceeded(
        _ command: ThreadUnsubscribeCommand
    ) -> [ThreadLeaseEffect] {
        completeUnsubscribe(command, failureMessage: nil)
    }

    public mutating func unsubscribeFailed(
        _ command: ThreadUnsubscribeCommand,
        message: String
    ) -> [ThreadLeaseEffect] {
        completeUnsubscribe(command, failureMessage: message)
    }

    private mutating func completeUnsubscribe(
        _ command: ThreadUnsubscribeCommand,
        failureMessage: String?
    ) -> [ThreadLeaseEffect] {
        guard var entry = entries[command.threadID] else { return [] }

        switch entry.state {
        case .unsubscribing(command.connectionEpoch, command.operationID):
            guard entry.leases.isEmpty else { return [] }
            if let failureMessage {
                entry.state = .failed(
                    connectionEpoch: command.connectionEpoch,
                    message: failureMessage
                )
                entries[command.threadID] = entry
            } else {
                entries.removeValue(forKey: command.threadID)
                return [.evictDetail(command.threadID)]
            }
            return []
        case .reconcileAfterUnsubscribe(command.connectionEpoch, command.operationID):
            guard !entry.leases.isEmpty,
                  activeConnectionEpoch == command.connectionEpoch else {
                return []
            }
            let effect = beginReconciliation(
                threadID: command.threadID,
                epoch: command.connectionEpoch,
                entry: &entry
            )
            entries[command.threadID] = entry
            return [effect]
        default:
            return []
        }
    }

    private mutating func allocateToken(threadID: ThreadID) -> ThreadLeaseToken {
        precondition(nextTokenRawValue < UInt64.max, "Thread lease token space exhausted")
        defer { nextTokenRawValue += 1 }
        return ThreadLeaseToken(rawValue: nextTokenRawValue, threadID: threadID)
    }

    private mutating func allocateOperationID() -> ThreadLeaseOperationID {
        precondition(nextOperationRawValue < UInt64.max, "Thread lease operation space exhausted")
        defer { nextOperationRawValue += 1 }
        return ThreadLeaseOperationID(rawValue: nextOperationRawValue)
    }

    private mutating func beginReconciliation(
        threadID: ThreadID,
        epoch: UInt64,
        entry: inout Entry
    ) -> ThreadLeaseEffect {
        let operationID = allocateOperationID()
        entry.state = .reconciling(connectionEpoch: epoch, operationID: operationID)
        return .reconcile(.init(
            threadID: threadID,
            connectionEpoch: epoch,
            operationID: operationID
        ))
    }

    private mutating func beginUnsubscribe(
        threadID: ThreadID,
        epoch: UInt64,
        entry: inout Entry
    ) -> ThreadLeaseEffect {
        let operationID = allocateOperationID()
        entry.state = .unsubscribing(connectionEpoch: epoch, operationID: operationID)
        return .unsubscribe(.init(
            threadID: threadID,
            connectionEpoch: epoch,
            operationID: operationID
        ))
    }

    private static func snapshot(threadID: ThreadID, entry: Entry) -> ThreadLeaseSnapshot {
        ThreadLeaseSnapshot(
            threadID: threadID,
            leases: entry.leases
                .map { (token: $0.key, reason: $0.value) }
                .sorted { $0.token < $1.token },
            subscriptionState: entry.state
        )
    }
}
