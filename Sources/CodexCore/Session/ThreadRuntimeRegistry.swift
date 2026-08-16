import Foundation

struct ThreadRuntimeRetainer: Sendable, Hashable, Comparable {
    let rawValue: UInt64
    let threadID: ThreadID

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.rawValue, lhs.threadID) < (rhs.rawValue, rhs.threadID)
    }
}

struct ThreadRuntimeCommand: Sendable, Hashable, Equatable {
    let threadID: ThreadID
    let connectionEpoch: UInt64
    let generation: UInt64
}

enum ThreadRuntimeEffect: Sendable, Equatable {
    case resume(ThreadRuntimeCommand)
    case unsubscribe(ThreadRuntimeCommand)
}

enum ThreadRuntimeActualSubscription: Sendable, Equatable {
    case subscribed(connectionEpoch: UInt64)
    case unsubscribed(connectionEpoch: UInt64?)
    case unknown(connectionEpoch: UInt64?)
}

enum ThreadRuntimeSubscriptionPhase: Sendable, Equatable {
    case idle
    case resuming(ThreadRuntimeCommand)
    case unsubscribing(ThreadRuntimeCommand)
}

struct ThreadRuntimeHistoryAnchors: Sendable, Equatable {
    let turnsBackwardsCursor: String?
    let itemsBackwardsCursor: String?
}

enum ThreadRuntimeHydrationPhase: Sendable, Equatable {
    case idle
    case awaitingResume(ThreadRuntimeCommand)
    case paging(ThreadRuntimeCommand)
    case ready(ThreadRuntimeCommand)
    case failed(ThreadRuntimeCommand, message: String)
    case stale(connectionEpoch: UInt64)
}

struct ThreadRuntimeHydrationState: Sendable, Equatable {
    var anchors: ThreadRuntimeHistoryAnchors?
    var turnsPage = CanonicalPageCursorState()
    var itemPagesByTurn: [TurnID: CanonicalPageCursorState] = [:]
    var phase: ThreadRuntimeHydrationPhase = .idle
}

struct ThreadRuntimeSnapshot: Sendable, Equatable {
    let threadID: ThreadID
    let retainerCount: Int
    let actual: ThreadRuntimeActualSubscription
    let phase: ThreadRuntimeSubscriptionPhase
    let generation: UInt64
    let hydration: ThreadRuntimeHydrationState

    var subscriptionDesired: Bool { retainerCount > 0 }
    var subscriptionUsable: Bool {
        guard case .subscribed = actual, phase == .idle else { return false }
        return true
    }
}

struct ThreadRuntimeAcquisition: Sendable, Equatable {
    let retainer: ThreadRuntimeRetainer
    let effects: [ThreadRuntimeEffect]
}

struct ThreadRuntimeRelease: Sendable, Equatable {
    let didRelease: Bool
    let effects: [ThreadRuntimeEffect]
}

/// Synchronous control state embedded in the sole `CodexSession` actor.
///
/// Retainers express desired subscription only. Actual subscription, the
/// in-flight transition, and hydration progress are independent facts. This
/// prevents inverse RPCs from being pipelined while allowing a successful
/// resume to become usable before its history pages finish.
struct ThreadRuntimeRegistry: Sendable {
    private struct Entry: Sendable {
        var retainers: Set<ThreadRuntimeRetainer> = []
        var actual: ThreadRuntimeActualSubscription = .unsubscribed(connectionEpoch: nil)
        var phase: ThreadRuntimeSubscriptionPhase = .idle
        var generation: UInt64 = 0
        var hydration = ThreadRuntimeHydrationState()

        var subscriptionDesired: Bool { !retainers.isEmpty }
    }

    private var entries: [ThreadID: Entry] = [:]
    // Entries remain in the registry after their last retainer is released so
    // stale completions can still be rejected. Cache the stable ordering used
    // by reconnect traversal and invalidate it only when a new thread appears.
    private var sortedThreadIDs: [ThreadID]?
    private var activeConnectionEpoch: UInt64?
    private var nextRetainerRawValue: UInt64 = 1

    var connectionEpoch: UInt64? { activeConnectionEpoch }

    func snapshot(for threadID: ThreadID) -> ThreadRuntimeSnapshot? {
        guard let entry = entries[threadID] else { return nil }
        return .init(
            threadID: threadID,
            retainerCount: entry.retainers.count,
            actual: entry.actual,
            phase: entry.phase,
            generation: entry.generation,
            hydration: entry.hydration
        )
    }

    mutating func retain(_ threadID: ThreadID) -> ThreadRuntimeAcquisition {
        let retainer = allocateRetainer(threadID: threadID)
        if entries[threadID] == nil {
            sortedThreadIDs = nil
        }
        var entry = entries[threadID] ?? Entry()
        entry.retainers.insert(retainer)
        let effects = converge(threadID: threadID, entry: &entry)
        entries[threadID] = entry
        return .init(retainer: retainer, effects: effects)
    }

    mutating func release(_ retainer: ThreadRuntimeRetainer) -> ThreadRuntimeRelease {
        guard var entry = entries[retainer.threadID],
              entry.retainers.remove(retainer) != nil
        else {
            return .init(didRelease: false, effects: [])
        }
        let effects = converge(threadID: retainer.threadID, entry: &entry)
        entries[retainer.threadID] = entry
        return .init(didRelease: true, effects: effects)
    }

    /// Retries convergence after the caller's backoff policy permits another RPC.
    mutating func reconcile(_ threadID: ThreadID) -> [ThreadRuntimeEffect] {
        guard var entry = entries[threadID] else { return [] }
        let effects = converge(threadID: threadID, entry: &entry)
        entries[threadID] = entry
        return effects
    }

    mutating func connectionReady(_ connectionEpoch: UInt64) -> [ThreadRuntimeEffect] {
        activeConnectionEpoch = connectionEpoch
        var effects: [ThreadRuntimeEffect] = []
        for threadID in orderedThreadIDs() {
            guard var entry = entries[threadID] else { continue }
            invalidateTransition(entry: &entry)
            entry.actual = .unsubscribed(connectionEpoch: connectionEpoch)
            effects.append(contentsOf: converge(threadID: threadID, entry: &entry))
            entries[threadID] = entry
        }
        return effects
    }

    mutating func connectionLost(_ connectionEpoch: UInt64) {
        guard activeConnectionEpoch == connectionEpoch else { return }
        activeConnectionEpoch = nil
        for threadID in orderedThreadIDs() {
            guard var entry = entries[threadID] else { continue }
            invalidateTransition(entry: &entry)
            entry.actual = .unknown(connectionEpoch: connectionEpoch)
            entry.hydration.phase = .stale(connectionEpoch: connectionEpoch)
            entries[threadID] = entry
        }
    }

    mutating func resumeSucceeded(
        _ command: ThreadRuntimeCommand,
        anchors: ThreadRuntimeHistoryAnchors
    ) -> [ThreadRuntimeEffect] {
        guard var entry = entries[command.threadID],
              activeConnectionEpoch == command.connectionEpoch,
              entry.phase == .resuming(command)
        else { return [] }

        entry.actual = .subscribed(connectionEpoch: command.connectionEpoch)
        entry.phase = .idle
        entry.hydration.anchors = anchors
        entry.hydration.turnsPage = .init(
            backwardsCursor: anchors.turnsBackwardsCursor,
            nextCursor: anchors.turnsBackwardsCursor,
            isExhausted: anchors.turnsBackwardsCursor == nil
        )
        entry.hydration.itemPagesByTurn.removeAll(keepingCapacity: true)
        entry.hydration.phase = anchors.turnsBackwardsCursor == nil
            && anchors.itemsBackwardsCursor == nil
            ? .ready(command)
            : .paging(command)

        let effects = converge(threadID: command.threadID, entry: &entry)
        entries[command.threadID] = entry
        return effects
    }

    mutating func resumeFailed(
        _ command: ThreadRuntimeCommand,
        message: String
    ) -> [ThreadRuntimeEffect] {
        guard var entry = entries[command.threadID],
              activeConnectionEpoch == command.connectionEpoch,
              entry.phase == .resuming(command)
        else { return [] }

        entry.actual = .unknown(connectionEpoch: command.connectionEpoch)
        entry.phase = .idle
        entry.hydration.phase = .failed(command, message: message)
        // Do not hot-loop the same failed RPC. If desire changed while resume
        // was in flight, the inverse cleanup can proceed immediately.
        let effects = entry.subscriptionDesired
            ? []
            : converge(threadID: command.threadID, entry: &entry)
        entries[command.threadID] = entry
        return effects
    }

    mutating func unsubscribeSucceeded(
        _ command: ThreadRuntimeCommand
    ) -> [ThreadRuntimeEffect] {
        guard var entry = entries[command.threadID],
              activeConnectionEpoch == command.connectionEpoch,
              entry.phase == .unsubscribing(command)
        else { return [] }

        entry.actual = .unsubscribed(connectionEpoch: command.connectionEpoch)
        entry.phase = .idle
        let effects = converge(threadID: command.threadID, entry: &entry)
        entries[command.threadID] = entry
        return effects
    }

    mutating func unsubscribeFailed(
        _ command: ThreadRuntimeCommand
    ) -> [ThreadRuntimeEffect] {
        guard var entry = entries[command.threadID],
              activeConnectionEpoch == command.connectionEpoch,
              entry.phase == .unsubscribing(command)
        else { return [] }

        entry.actual = .unknown(connectionEpoch: command.connectionEpoch)
        entry.phase = .idle
        // Reacquisition during unsubscribe can resume immediately. Retrying
        // the same failed unsubscribe is driven through `reconcile` after
        // caller-controlled backoff.
        let effects = entry.subscriptionDesired
            ? converge(threadID: command.threadID, entry: &entry)
            : []
        entries[command.threadID] = entry
        return effects
    }

    @discardableResult
    mutating func updateTurnsPage(
        _ command: ThreadRuntimeCommand,
        backwardsCursor: String?,
        nextCursor: String?
    ) -> Bool {
        guard var entry = entries[command.threadID],
              hydrationAccepts(command, entry: entry)
        else { return false }
        entry.hydration.turnsPage = .init(
            backwardsCursor: entry.hydration.turnsPage.backwardsCursor ?? backwardsCursor,
            nextCursor: nextCursor,
            isExhausted: nextCursor == nil
        )
        entries[command.threadID] = entry
        return true
    }

    @discardableResult
    mutating func updateItemsPage(
        _ command: ThreadRuntimeCommand,
        turnID: TurnID,
        backwardsCursor: String?,
        nextCursor: String?
    ) -> Bool {
        guard var entry = entries[command.threadID],
              hydrationAccepts(command, entry: entry)
        else { return false }
        let previous = entry.hydration.itemPagesByTurn[turnID] ?? .init()
        entry.hydration.itemPagesByTurn[turnID] = .init(
            backwardsCursor: previous.backwardsCursor ?? backwardsCursor,
            nextCursor: nextCursor,
            isExhausted: nextCursor == nil
        )
        entries[command.threadID] = entry
        return true
    }

    @discardableResult
    mutating func hydrationSucceeded(_ command: ThreadRuntimeCommand) -> Bool {
        guard var entry = entries[command.threadID],
              hydrationAccepts(command, entry: entry)
        else { return false }
        entry.hydration.phase = .ready(command)
        entries[command.threadID] = entry
        return true
    }

    @discardableResult
    mutating func hydrationFailed(
        _ command: ThreadRuntimeCommand,
        message: String
    ) -> Bool {
        guard var entry = entries[command.threadID],
              hydrationAccepts(command, entry: entry)
        else { return false }
        entry.hydration.phase = .failed(command, message: message)
        entries[command.threadID] = entry
        return true
    }

    private mutating func converge(
        threadID: ThreadID,
        entry: inout Entry
    ) -> [ThreadRuntimeEffect] {
        guard entry.phase == .idle, let epoch = activeConnectionEpoch else { return [] }

        if entry.subscriptionDesired {
            if entry.actual == .subscribed(connectionEpoch: epoch) { return [] }
            let command = beginCommand(threadID: threadID, epoch: epoch, entry: &entry)
            entry.phase = .resuming(command)
            entry.hydration = .init(phase: .awaitingResume(command))
            return [.resume(command)]
        }

        if entry.actual == .unsubscribed(connectionEpoch: epoch) {
            return []
        }
        if entry.actual == .subscribed(connectionEpoch: epoch)
            || entry.actual == .unknown(connectionEpoch: epoch)
        {
            let command = beginCommand(threadID: threadID, epoch: epoch, entry: &entry)
            entry.phase = .unsubscribing(command)
            return [.unsubscribe(command)]
        }
        entry.actual = .unsubscribed(connectionEpoch: epoch)
        return []
    }

    private mutating func orderedThreadIDs() -> [ThreadID] {
        if let sortedThreadIDs {
            return sortedThreadIDs
        }
        let sortedThreadIDs = entries.keys.sorted()
        self.sortedThreadIDs = sortedThreadIDs
        return sortedThreadIDs
    }

    private func hydrationAccepts(
        _ command: ThreadRuntimeCommand,
        entry: Entry
    ) -> Bool {
        guard activeConnectionEpoch == command.connectionEpoch,
              entry.generation == command.generation
        else { return false }
        switch entry.hydration.phase {
        case .paging(let current), .ready(let current):
            return current == command
        case .idle, .awaitingResume, .failed, .stale:
            return false
        }
    }

    private mutating func allocateRetainer(threadID: ThreadID) -> ThreadRuntimeRetainer {
        precondition(nextRetainerRawValue < UInt64.max, "Thread retainer space exhausted")
        defer { nextRetainerRawValue += 1 }
        return .init(rawValue: nextRetainerRawValue, threadID: threadID)
    }

    private func beginCommand(
        threadID: ThreadID,
        epoch: UInt64,
        entry: inout Entry
    ) -> ThreadRuntimeCommand {
        precondition(entry.generation < UInt64.max, "Thread runtime generation exhausted")
        entry.generation += 1
        return .init(
            threadID: threadID,
            connectionEpoch: epoch,
            generation: entry.generation
        )
    }

    private func invalidateTransition(entry: inout Entry) {
        precondition(entry.generation < UInt64.max, "Thread runtime generation exhausted")
        entry.generation += 1
        entry.phase = .idle
    }
}
