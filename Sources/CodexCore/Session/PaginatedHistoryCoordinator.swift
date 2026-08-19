import Foundation

public struct PaginatedHistoryPolicy: Sendable, Equatable {
    public var turnPageLimit: Int
    public var itemPageLimit: Int
    public var maximumConcurrentItemPages: Int
    public var maximumBufferedLiveEvents: Int

    public init(
        turnPageLimit: Int = 50,
        itemPageLimit: Int = 100,
        maximumConcurrentItemPages: Int = 4,
        maximumBufferedLiveEvents: Int = 8_192
    ) {
        precondition(turnPageLimit > 0)
        precondition(itemPageLimit > 0)
        precondition(maximumConcurrentItemPages > 0)
        precondition(maximumBufferedLiveEvents > 0)
        self.turnPageLimit = turnPageLimit
        self.itemPageLimit = itemPageLimit
        self.maximumConcurrentItemPages = maximumConcurrentItemPages
        self.maximumBufferedLiveEvents = maximumBufferedLiveEvents
    }
}

public struct PaginatedHistoryRequestID: RawRepresentable, Sendable, Hashable, Codable, Comparable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum PaginatedHistorySortDirection: String, Sendable, Codable, Equatable {
    case descending = "desc"
}

public enum PaginatedHistoryTurnItemsView: String, Sendable, Codable, Equatable {
    case summary
}

public struct PaginatedHistoryResumeRequest: Sendable, Equatable {
    public let requestID: PaginatedHistoryRequestID
    public let reconciliation: ThreadReconciliationCommand
    public let excludeTurns: Bool

    public init(
        requestID: PaginatedHistoryRequestID,
        reconciliation: ThreadReconciliationCommand,
        excludeTurns: Bool = true
    ) {
        self.requestID = requestID
        self.reconciliation = reconciliation
        self.excludeTurns = excludeTurns
    }
}

public struct PaginatedHistoryTurnsRequest: Sendable, Equatable {
    public let requestID: PaginatedHistoryRequestID
    public let reconciliation: ThreadReconciliationCommand
    public let cursor: String
    public let limit: Int
    public let sortDirection: PaginatedHistorySortDirection
    public let itemsView: PaginatedHistoryTurnItemsView

    public init(
        requestID: PaginatedHistoryRequestID,
        reconciliation: ThreadReconciliationCommand,
        cursor: String,
        limit: Int,
        sortDirection: PaginatedHistorySortDirection = .descending,
        itemsView: PaginatedHistoryTurnItemsView = .summary
    ) {
        self.requestID = requestID
        self.reconciliation = reconciliation
        self.cursor = cursor
        self.limit = limit
        self.sortDirection = sortDirection
        self.itemsView = itemsView
    }
}

public struct PaginatedHistoryItemsRequest: Sendable, Equatable {
    public let requestID: PaginatedHistoryRequestID
    public let reconciliation: ThreadReconciliationCommand
    public let turnID: TurnID
    public let cursor: String
    public let limit: Int
    public let sortDirection: PaginatedHistorySortDirection

    public init(
        requestID: PaginatedHistoryRequestID,
        reconciliation: ThreadReconciliationCommand,
        turnID: TurnID,
        cursor: String,
        limit: Int,
        sortDirection: PaginatedHistorySortDirection = .descending
    ) {
        self.requestID = requestID
        self.reconciliation = reconciliation
        self.turnID = turnID
        self.cursor = cursor
        self.limit = limit
        self.sortDirection = sortDirection
    }
}

/// A typed page record after the generated protocol Adapter has extracted its
/// stable identifier. The complete lossless value is staged for canonical reduction.
public struct PaginatedHistoryTurnRecord: Sendable, Equatable {
    public let turnID: TurnID
    public let value: CodexJSONValue

    public init(turnID: TurnID, value: CodexJSONValue) {
        self.turnID = turnID
        self.value = value
    }
}

/// The optional first descending turn page embedded in `thread/resume`.
/// Its records are already part of the durable resume cut, while `nextCursor`
/// identifies the first page that still needs to be fetched.
public struct PaginatedHistoryInitialTurnsPage: Sendable, Equatable {
    public let data: [PaginatedHistoryTurnRecord]
    public let backwardsCursor: String?
    public let nextCursor: String?

    public init(
        data: [PaginatedHistoryTurnRecord],
        backwardsCursor: String?,
        nextCursor: String?
    ) {
        self.data = data
        self.backwardsCursor = backwardsCursor
        self.nextCursor = nextCursor
    }
}

public struct PaginatedHistoryItemRecord: Sendable, Equatable {
    public let turnID: TurnID
    public let itemID: ItemID
    public let value: CodexJSONValue

    public init(turnID: TurnID, itemID: ItemID, value: CodexJSONValue) {
        self.turnID = turnID
        self.itemID = itemID
        self.value = value
    }
}

public struct PaginatedHistoryBufferedLiveEvent: Sendable, Equatable {
    public let cursor: CodexWireCursor
    public let method: String
    public let params: CodexJSONValue

    public init(cursor: CodexWireCursor, method: String, params: CodexJSONValue) {
        self.cursor = cursor
        self.method = method
        self.params = params
    }
}

public struct PaginatedHistoryInstallation: Sendable, Equatable {
    public let reconciliation: ThreadReconciliationCommand
    public let resumeCut: CanonicalResumeCut
    /// Ordered-ingress position of the resume response that established `resumeCut`.
    public let resumeResponseCursor: CodexWireCursor
    /// Complete lossless `thread/resume` result retained for protocol-correct
    /// installation after all durable pages have been staged.
    public let resumeResult: CodexJSONValue
    /// Exact object parameters of the resume request. Override fields remain
    /// available when the staged response is reduced after paging completes.
    public let resumeRequestParams: [String: CodexJSONValue]
    public let resumeThread: CodexJSONValue
    /// Complete durable turn order at the cut, oldest first.
    public let turns: [PaginatedHistoryTurnRecord]
    /// Complete durable items at the cut, grouped in turn order and oldest first.
    public let items: [PaginatedHistoryItemRecord]
    public let bufferedLiveEvents: [PaginatedHistoryBufferedLiveEvent]
    public let historyState: CanonicalHistoryState
    /// A reconnect gap can omit transient deltas for an item that remained active.
    public let crossedConnectionGap: Bool

    public init(
        reconciliation: ThreadReconciliationCommand,
        resumeCut: CanonicalResumeCut,
        resumeResponseCursor: CodexWireCursor,
        resumeThread: CodexJSONValue,
        turns: [PaginatedHistoryTurnRecord],
        items: [PaginatedHistoryItemRecord],
        bufferedLiveEvents: [PaginatedHistoryBufferedLiveEvent],
        historyState: CanonicalHistoryState,
        crossedConnectionGap: Bool,
        resumeResult: CodexJSONValue? = nil,
        resumeRequestParams: [String: CodexJSONValue] = [:]
    ) {
        self.reconciliation = reconciliation
        self.resumeCut = resumeCut
        self.resumeResponseCursor = resumeResponseCursor
        self.resumeResult = resumeResult ?? .dictionary(["thread": resumeThread])
        self.resumeRequestParams = resumeRequestParams
        self.resumeThread = resumeThread
        self.turns = turns
        self.items = items
        self.bufferedLiveEvents = bufferedLiveEvents
        self.historyState = historyState
        self.crossedConnectionGap = crossedConnectionGap
    }
}

public enum PaginatedHistoryRequestKind: Sendable, Equatable {
    case resume
    case turns
    case items(TurnID)
}

public enum PaginatedHistoryFailureReason: Sendable, Equatable {
    case requestFailed(kind: PaginatedHistoryRequestKind, message: String)
    case repeatedCursor(kind: PaginatedHistoryRequestKind, cursor: String)
    case emptyPageWithContinuation(kind: PaginatedHistoryRequestKind)
    case itemReturnedForWrongTurn(expected: TurnID, actual: TurnID)
    case itemsWithoutTurns
    case liveBufferOverflow(limit: Int)
}

public struct PaginatedHistoryFailure: Sendable, Equatable {
    public let reconciliation: ThreadReconciliationCommand
    public let reason: PaginatedHistoryFailureReason

    public init(
        reconciliation: ThreadReconciliationCommand,
        reason: PaginatedHistoryFailureReason
    ) {
        self.reconciliation = reconciliation
        self.reason = reason
    }
}

public struct PaginatedHistoryStaleTransition: Sendable, Equatable {
    public let threadID: ThreadID
    public let connectionEpoch: UInt64
    public let previousCut: CanonicalResumeCut?

    public init(
        threadID: ThreadID,
        connectionEpoch: UInt64,
        previousCut: CanonicalResumeCut?
    ) {
        self.threadID = threadID
        self.connectionEpoch = connectionEpoch
        self.previousCut = previousCut
    }
}

/// Deterministic work returned to the owning `CodexSession` actor.
public enum PaginatedHistoryEffect: Sendable, Equatable {
    case requestResume(PaginatedHistoryResumeRequest)
    case requestTurns(PaginatedHistoryTurnsRequest)
    case requestItems(PaginatedHistoryItemsRequest)
    case install(PaginatedHistoryInstallation)
    case failed(PaginatedHistoryFailure)
    case markStale(PaginatedHistoryStaleTransition)
}

public enum PaginatedHistoryLiveDisposition: Sendable, Equatable {
    case buffered
    case applyImmediately
    case ignoredDuplicate
    case ignoredStale
    case failed(PaginatedHistoryFailure)
}

public enum PaginatedHistoryPhase: Sendable, Equatable {
    case awaitingResume(connectionEpoch: UInt64, resumeGeneration: UInt64)
    case paging(connectionEpoch: UInt64, resumeGeneration: UInt64)
    case live(CanonicalResumeCut)
    case stale(CanonicalResumeCut?)
    case failed(PaginatedHistoryFailure)
}

public struct PaginatedHistoryScopeSnapshot: Sendable, Equatable {
    public let threadID: ThreadID
    public let phase: PaginatedHistoryPhase
    public let bufferedLiveEventCount: Int

    public init(
        threadID: ThreadID,
        phase: PaginatedHistoryPhase,
        bufferedLiveEventCount: Int
    ) {
        self.threadID = threadID
        self.phase = phase
        self.bufferedLiveEventCount = bufferedLiveEventCount
    }
}

/// Synchronous, actor-embeddable coordinator for alpha.20 paginated history.
///
/// It owns no executor and performs no I/O. The sole `CodexSession` actor feeds
/// responses back into it and executes returned effects. Durable pages are staged
/// until both cursor chains are exhausted, then installed with post-cut live frames
/// in one actor transaction.
public struct PaginatedHistoryCoordinator: Sendable {
    private struct ItemChain: Sendable {
        let turnID: TurnID
        var recordsByID: [ItemID: PaginatedHistoryItemRecord] = [:]
        var newestFirstOrder: [ItemID] = []
        var seenCursors: Set<String>
        var pageState: CanonicalPageCursorState
        var activeRequestID: PaginatedHistoryRequestID?

        init(turnID: TurnID, headCursor: String?) {
            self.turnID = turnID
            self.seenCursors = Set(headCursor.map { [$0] } ?? [])
            self.pageState = CanonicalPageCursorState(
                backwardsCursor: headCursor,
                nextCursor: headCursor,
                isExhausted: headCursor == nil
            )
        }
    }

    private struct PagingState: Sendable {
        let reconciliation: ThreadReconciliationCommand
        let cut: CanonicalResumeCut
        let resumeResponseCursor: CodexWireCursor
        let resumeResult: CodexJSONValue
        let resumeRequestParams: [String: CodexJSONValue]
        let resumeThread: CodexJSONValue
        let previousCut: CanonicalResumeCut?
        var turnRecordsByID: [TurnID: PaginatedHistoryTurnRecord] = [:]
        var newestFirstTurnOrder: [TurnID] = []
        var seenTurnCursors: Set<String>
        var turnsPage: CanonicalPageCursorState
        var activeTurnRequestID: PaginatedHistoryRequestID?
        var itemChains: [TurnID: ItemChain] = [:]
        var pendingItemTurns: [TurnID] = []
        var pendingItemTurnIndex = 0
        var activeItemRequestToTurn: [PaginatedHistoryRequestID: TurnID] = [:]
        var bufferedLiveEvents: [PaginatedHistoryBufferedLiveEvent]
        var bufferedLiveCursors: Set<CodexWireCursor>

        init(
            reconciliation: ThreadReconciliationCommand,
            cut: CanonicalResumeCut,
            resumeResponseCursor: CodexWireCursor,
            resumeResult: CodexJSONValue,
            resumeRequestParams: [String: CodexJSONValue],
            resumeThread: CodexJSONValue,
            previousCut: CanonicalResumeCut?,
            bufferedLiveEvents: [PaginatedHistoryBufferedLiveEvent],
            bufferedLiveCursors: Set<CodexWireCursor>
        ) {
            self.reconciliation = reconciliation
            self.cut = cut
            self.resumeResponseCursor = resumeResponseCursor
            self.resumeResult = resumeResult
            self.resumeRequestParams = resumeRequestParams
            self.resumeThread = resumeThread
            self.previousCut = previousCut
            self.seenTurnCursors = Set(cut.turnsBackwardsCursor.map { [$0] } ?? [])
            self.turnsPage = CanonicalPageCursorState(
                backwardsCursor: cut.turnsBackwardsCursor,
                nextCursor: cut.turnsBackwardsCursor,
                isExhausted: cut.turnsBackwardsCursor == nil
            )
            self.bufferedLiveEvents = bufferedLiveEvents
            self.bufferedLiveCursors = bufferedLiveCursors
        }
    }

    private enum ScopeState: Sendable {
        case awaitingResume(
            reconciliation: ThreadReconciliationCommand,
            requestID: PaginatedHistoryRequestID,
            previousCut: CanonicalResumeCut?,
            bufferedEvents: [PaginatedHistoryBufferedLiveEvent],
            bufferedCursors: Set<CodexWireCursor>
        )
        case paging(PagingState)
        case live(CanonicalResumeCut)
        case stale(previousCut: CanonicalResumeCut?, sealedConnectionEpoch: UInt64)
        case failed(PaginatedHistoryFailure, previousCut: CanonicalResumeCut?)
    }

    public let policy: PaginatedHistoryPolicy
    private var scopes: [ThreadID: ScopeState] = [:]
    private var nextRequestRawValue: UInt64 = 1

    public init(policy: PaginatedHistoryPolicy = .init()) {
        self.policy = policy
    }

    public func snapshot(for threadID: ThreadID) -> PaginatedHistoryScopeSnapshot? {
        guard let state = scopes[threadID] else { return nil }
        switch state {
        case .awaitingResume(let command, _, _, let events, _):
            return .init(
                threadID: threadID,
                phase: .awaitingResume(
                    connectionEpoch: command.connectionEpoch,
                    resumeGeneration: command.operationID.rawValue
                ),
                bufferedLiveEventCount: events.count
            )
        case .paging(let paging):
            return .init(
                threadID: threadID,
                phase: .paging(
                    connectionEpoch: paging.cut.connectionEpoch,
                    resumeGeneration: paging.cut.resumeGeneration
                ),
                bufferedLiveEventCount: paging.bufferedLiveEvents.count
            )
        case .live(let cut):
            return .init(threadID: threadID, phase: .live(cut), bufferedLiveEventCount: 0)
        case .stale(let cut, _):
            return .init(threadID: threadID, phase: .stale(cut), bufferedLiveEventCount: 0)
        case .failed(let failure, _):
            return .init(threadID: threadID, phase: .failed(failure), bufferedLiveEventCount: 0)
        }
    }

    @discardableResult
    public mutating func beginReconciliation(
        _ reconciliation: ThreadReconciliationCommand
    ) -> [PaginatedHistoryEffect] {
        if case .awaitingResume(let current, _, _, _, _)? = scopes[reconciliation.threadID],
           current == reconciliation {
            return []
        }

        let previousCut = cut(from: scopes[reconciliation.threadID])
        let requestID = allocateRequestID()
        scopes[reconciliation.threadID] = .awaitingResume(
            reconciliation: reconciliation,
            requestID: requestID,
            previousCut: previousCut,
            bufferedEvents: [],
            bufferedCursors: []
        )
        return [.requestResume(.init(
            requestID: requestID,
            reconciliation: reconciliation,
            excludeTurns: true
        ))]
    }

    /// Installs the alpha.20 resume cut. Both nullable cursor fields must already
    /// have been presence-validated by the protocol Adapter.
    public mutating func receiveResumeCut(
        threadID: ThreadID,
        requestID: PaginatedHistoryRequestID,
        turnsBackwardsCursor: String?,
        itemsBackwardsCursor: String?,
        responseCursor: CodexWireCursor,
        resumeThread: CodexJSONValue,
        resumeResult: CodexJSONValue? = nil,
        resumeRequestParams: [String: CodexJSONValue] = [:],
        initialTurnsPage: PaginatedHistoryInitialTurnsPage? = nil
    ) -> [PaginatedHistoryEffect] {
        guard case .awaitingResume(
            let reconciliation,
            let expectedRequestID,
            let previousCut,
            _,
            _
        )? = scopes[threadID],
        expectedRequestID == requestID,
        responseCursor.connectionEpoch == reconciliation.connectionEpoch else { return [] }

        let cut = CanonicalResumeCut(
            connectionEpoch: reconciliation.connectionEpoch,
            resumeGeneration: reconciliation.operationID.rawValue,
            turnsBackwardsCursor: turnsBackwardsCursor,
            itemsBackwardsCursor: itemsBackwardsCursor
        )
        var paging = PagingState(
            reconciliation: reconciliation,
            cut: cut,
            resumeResponseCursor: responseCursor,
            resumeResult: resumeResult ?? .dictionary(["thread": resumeThread]),
            resumeRequestParams: resumeRequestParams,
            resumeThread: resumeThread,
            previousCut: previousCut,
            bufferedLiveEvents: [],
            bufferedLiveCursors: []
        )

        let initialPageHasTurns = initialTurnsPage.map {
            !$0.data.isEmpty || $0.nextCursor != nil
        } ?? false
        if turnsBackwardsCursor == nil,
           !initialPageHasTurns,
           itemsBackwardsCursor != nil {
            return fail(
                threadID: threadID,
                paging: paging,
                reason: .itemsWithoutTurns
            )
        }

        if let initialTurnsPage {
            for record in initialTurnsPage.data
            where paging.turnRecordsByID[record.turnID] == nil {
                paging.turnRecordsByID[record.turnID] = record
                paging.newestFirstTurnOrder.append(record.turnID)
            }
            if initialTurnsPage.data.isEmpty, initialTurnsPage.nextCursor != nil {
                return fail(
                    threadID: threadID,
                    paging: paging,
                    reason: .emptyPageWithContinuation(kind: .turns)
                )
            }
            paging.turnsPage = .init(
                backwardsCursor: initialTurnsPage.backwardsCursor,
                nextCursor: initialTurnsPage.nextCursor,
                isExhausted: initialTurnsPage.nextCursor == nil
            )
            if let nextCursor = initialTurnsPage.nextCursor {
                guard paging.seenTurnCursors.insert(nextCursor).inserted else {
                    return fail(
                        threadID: threadID,
                        paging: paging,
                        reason: .repeatedCursor(kind: .turns, cursor: nextCursor)
                    )
                }
                let effect = makeTurnsRequest(cursor: nextCursor, paging: &paging)
                scopes[threadID] = .paging(paging)
                return [effect]
            }

            return finishTurnPaging(threadID: threadID, paging: paging)
        }

        if let cursor = turnsBackwardsCursor {
            let effect = makeTurnsRequest(cursor: cursor, paging: &paging)
            scopes[threadID] = .paging(paging)
            return [effect]
        }

        scopes[threadID] = .paging(paging)
        return finishIfReady(threadID: threadID)
    }

    public mutating func receiveTurnsPage(
        threadID: ThreadID,
        requestID: PaginatedHistoryRequestID,
        data: [PaginatedHistoryTurnRecord],
        backwardsCursor: String?,
        nextCursor: String?
    ) -> [PaginatedHistoryEffect] {
        guard case .paging(var paging)? = scopes[threadID],
              paging.activeTurnRequestID == requestID else { return [] }

        paging.activeTurnRequestID = nil
        for record in data where paging.turnRecordsByID[record.turnID] == nil {
            paging.turnRecordsByID[record.turnID] = record
            paging.newestFirstTurnOrder.append(record.turnID)
        }

        if data.isEmpty, nextCursor != nil {
            return fail(
                threadID: threadID,
                paging: paging,
                reason: .emptyPageWithContinuation(kind: .turns)
            )
        }

        paging.turnsPage.backwardsCursor = paging.turnsPage.backwardsCursor ?? backwardsCursor
        paging.turnsPage.nextCursor = nextCursor
        if let nextCursor {
            guard paging.seenTurnCursors.insert(nextCursor).inserted else {
                return fail(
                    threadID: threadID,
                    paging: paging,
                    reason: .repeatedCursor(kind: .turns, cursor: nextCursor)
                )
            }
            let effect = makeTurnsRequest(cursor: nextCursor, paging: &paging)
            scopes[threadID] = .paging(paging)
            return [effect]
        }

        return finishTurnPaging(threadID: threadID, paging: paging)
    }

    public mutating func receiveItemsPage(
        threadID: ThreadID,
        turnID: TurnID,
        requestID: PaginatedHistoryRequestID,
        data: [PaginatedHistoryItemRecord],
        backwardsCursor: String?,
        nextCursor: String?
    ) -> [PaginatedHistoryEffect] {
        guard case .paging(var paging)? = scopes[threadID],
              paging.activeItemRequestToTurn[requestID] == turnID,
              var chain = paging.itemChains[turnID],
              chain.activeRequestID == requestID else { return [] }

        paging.activeItemRequestToTurn.removeValue(forKey: requestID)
        chain.activeRequestID = nil

        for record in data {
            guard record.turnID == turnID else {
                return fail(
                    threadID: threadID,
                    paging: paging,
                    reason: .itemReturnedForWrongTurn(expected: turnID, actual: record.turnID)
                )
            }
            if chain.recordsByID[record.itemID] == nil {
                chain.recordsByID[record.itemID] = record
                chain.newestFirstOrder.append(record.itemID)
            }
        }

        if data.isEmpty, nextCursor != nil {
            return fail(
                threadID: threadID,
                paging: paging,
                reason: .emptyPageWithContinuation(kind: .items(turnID))
            )
        }

        chain.pageState.backwardsCursor = chain.pageState.backwardsCursor ?? backwardsCursor
        chain.pageState.nextCursor = nextCursor
        if let nextCursor {
            guard chain.seenCursors.insert(nextCursor).inserted else {
                return fail(
                    threadID: threadID,
                    paging: paging,
                    reason: .repeatedCursor(kind: .items(turnID), cursor: nextCursor)
                )
            }
            paging.itemChains[turnID] = chain
            let effect = makeItemsRequest(turnID: turnID, cursor: nextCursor, paging: &paging)
            scopes[threadID] = .paging(paging)
            return [effect]
        }

        chain.pageState.nextCursor = nil
        chain.pageState.isExhausted = true
        paging.itemChains[turnID] = chain
        scopes[threadID] = .paging(paging)
        return pumpItemRequestsOrFinish(threadID: threadID)
    }

    public mutating func requestFailed(
        threadID: ThreadID,
        requestID: PaginatedHistoryRequestID,
        message: String
    ) -> [PaginatedHistoryEffect] {
        guard let state = scopes[threadID] else { return [] }
        switch state {
        case .awaitingResume(
            let reconciliation,
            let expectedRequestID,
            let previousCut,
            _,
            _
        ) where expectedRequestID == requestID:
            let failure = PaginatedHistoryFailure(
                reconciliation: reconciliation,
                reason: .requestFailed(kind: .resume, message: message)
            )
            scopes[threadID] = .failed(failure, previousCut: previousCut)
            return [.failed(failure)]
        case .awaitingResume:
            return []
        case .paging(let paging):
            if paging.activeTurnRequestID == requestID {
                return fail(
                    threadID: threadID,
                    paging: paging,
                    reason: .requestFailed(kind: .turns, message: message)
                )
            }
            if let turnID = paging.activeItemRequestToTurn[requestID] {
                return fail(
                    threadID: threadID,
                    paging: paging,
                    reason: .requestFailed(kind: .items(turnID), message: message)
                )
            }
            return []
        case .live, .stale, .failed:
            return []
        }
    }

    /// Live wire facts are always reduced immediately. Resume cursors are
    /// persistence anchors, not an event-sequence cut, so neither pre-response
    /// nor paging-time notifications may be hidden or discarded here.
    public mutating func receiveLiveEvent(
        threadID: ThreadID,
        event: PaginatedHistoryBufferedLiveEvent
    ) -> PaginatedHistoryLiveDisposition {
        guard let state = scopes[threadID] else { return .ignoredStale }
        switch state {
        case .awaitingResume(let reconciliation, _, _, _, _):
            guard event.cursor.connectionEpoch == reconciliation.connectionEpoch else {
                return .ignoredStale
            }
            return .applyImmediately
        case .paging(let paging):
            guard event.cursor.connectionEpoch == paging.cut.connectionEpoch else {
                return .ignoredStale
            }
            return .applyImmediately
        case .live(let cut):
            return event.cursor.connectionEpoch == cut.connectionEpoch
                ? .applyImmediately
                : .ignoredStale
        case .stale(_, let sealedConnectionEpoch):
            // The sealed epoch is obsolete. A notification from a newer epoch
            // is still live state even if durable history has not reconciled.
            return event.cursor.connectionEpoch > sealedConnectionEpoch
                ? .applyImmediately
                : .ignoredStale
        case .failed(let failure, _):
            // Paging failure reduces durable coverage; it must not turn the
            // currently subscribed live ingress into a permanent black hole.
            return event.cursor.connectionEpoch == failure.reconciliation.connectionEpoch
                ? .applyImmediately
                : .ignoredStale
        }
    }

    /// Marks every matching scope stale and discards unfinished staging from the
    /// sealed epoch. Already-installed durable state remains represented by its cut.
    public mutating func connectionLost(_ connectionEpoch: UInt64) -> [PaginatedHistoryEffect] {
        var effects: [PaginatedHistoryEffect] = []
        for threadID in scopes.keys.sorted() {
            guard let state = scopes[threadID], epoch(from: state) == connectionEpoch else { continue }
            let previousCut = cut(from: state)
            scopes[threadID] = .stale(
                previousCut: previousCut,
                sealedConnectionEpoch: connectionEpoch
            )
            effects.append(.markStale(.init(
                threadID: threadID,
                connectionEpoch: connectionEpoch,
                previousCut: previousCut
            )))
        }
        return effects
    }

    private mutating func pumpItemRequestsOrFinish(
        threadID: ThreadID
    ) -> [PaginatedHistoryEffect] {
        guard case .paging(var paging)? = scopes[threadID] else { return [] }
        var effects: [PaginatedHistoryEffect] = []

        while paging.activeItemRequestToTurn.count < policy.maximumConcurrentItemPages,
              paging.pendingItemTurnIndex < paging.pendingItemTurns.count {
            let turnID = paging.pendingItemTurns[paging.pendingItemTurnIndex]
            paging.pendingItemTurnIndex += 1
            guard let chain = paging.itemChains[turnID] else { continue }
            guard !chain.pageState.isExhausted, let cursor = chain.pageState.nextCursor else {
                paging.itemChains[turnID] = chain
                continue
            }
            let effect = makeItemsRequest(turnID: turnID, cursor: cursor, paging: &paging)
            effects.append(effect)
        }
        scopes[threadID] = .paging(paging)

        if effects.isEmpty {
            return finishIfReady(threadID: threadID)
        }
        return effects
    }

    private mutating func finishTurnPaging(
        threadID: ThreadID,
        paging initialPaging: PagingState
    ) -> [PaginatedHistoryEffect] {
        var paging = initialPaging
        paging.turnsPage.isExhausted = true
        paging.turnsPage.nextCursor = nil
        let itemHead = paging.cut.itemsBackwardsCursor
        paging.pendingItemTurns = paging.newestFirstTurnOrder
        paging.pendingItemTurnIndex = 0
        for turnID in paging.newestFirstTurnOrder {
            paging.itemChains[turnID] = ItemChain(turnID: turnID, headCursor: itemHead)
        }
        scopes[threadID] = .paging(paging)
        return pumpItemRequestsOrFinish(threadID: threadID)
    }

    private mutating func finishIfReady(threadID: ThreadID) -> [PaginatedHistoryEffect] {
        guard case .paging(let paging)? = scopes[threadID],
              paging.turnsPage.isExhausted,
              paging.pendingItemTurnIndex >= paging.pendingItemTurns.count,
              paging.activeItemRequestToTurn.isEmpty,
              paging.itemChains.values.allSatisfy({ $0.pageState.isExhausted }) else {
            return []
        }

        let oldestFirstTurnIDs = Array(paging.newestFirstTurnOrder.reversed())
        let turns = oldestFirstTurnIDs.compactMap { paging.turnRecordsByID[$0] }
        let items = oldestFirstTurnIDs.flatMap { turnID -> [PaginatedHistoryItemRecord] in
            guard let chain = paging.itemChains[turnID] else { return [] }
            return chain.newestFirstOrder.reversed().compactMap { chain.recordsByID[$0] }
        }
        let itemPages = Dictionary(uniqueKeysWithValues: paging.itemChains.map {
            ($0.key, $0.value.pageState)
        })
        let historyState = CanonicalHistoryState(
            mode: .paginated,
            turnsCoverage: .full,
            resumeCut: paging.cut,
            turnsPage: paging.turnsPage,
            itemPagesByTurn: itemPages,
            isStaleAfterReconnect: false
        )
        let installation = PaginatedHistoryInstallation(
            reconciliation: paging.reconciliation,
            resumeCut: paging.cut,
            resumeResponseCursor: paging.resumeResponseCursor,
            resumeThread: paging.resumeThread,
            turns: turns,
            items: items,
            bufferedLiveEvents: paging.bufferedLiveEvents.sorted { $0.cursor < $1.cursor },
            historyState: historyState,
            crossedConnectionGap: paging.previousCut.map {
                $0.connectionEpoch != paging.cut.connectionEpoch
            } ?? false,
            resumeResult: paging.resumeResult,
            resumeRequestParams: paging.resumeRequestParams
        )
        scopes[threadID] = .live(paging.cut)
        return [.install(installation)]
    }

    private mutating func makeTurnsRequest(
        cursor: String,
        paging: inout PagingState
    ) -> PaginatedHistoryEffect {
        let requestID = allocateRequestID()
        paging.activeTurnRequestID = requestID
        return .requestTurns(.init(
            requestID: requestID,
            reconciliation: paging.reconciliation,
            cursor: cursor,
            limit: policy.turnPageLimit
        ))
    }

    private mutating func makeItemsRequest(
        turnID: TurnID,
        cursor: String,
        paging: inout PagingState
    ) -> PaginatedHistoryEffect {
        let requestID = allocateRequestID()
        paging.activeItemRequestToTurn[requestID] = turnID
        var chain = paging.itemChains[turnID] ?? ItemChain(
            turnID: turnID,
            headCursor: paging.cut.itemsBackwardsCursor
        )
        chain.activeRequestID = requestID
        paging.itemChains[turnID] = chain
        return .requestItems(.init(
            requestID: requestID,
            reconciliation: paging.reconciliation,
            turnID: turnID,
            cursor: cursor,
            limit: policy.itemPageLimit
        ))
    }

    private mutating func fail(
        threadID: ThreadID,
        paging: PagingState,
        reason: PaginatedHistoryFailureReason
    ) -> [PaginatedHistoryEffect] {
        let failure = PaginatedHistoryFailure(
            reconciliation: paging.reconciliation,
            reason: reason
        )
        scopes[threadID] = .failed(failure, previousCut: paging.previousCut)
        return [.failed(failure)]
    }

    private mutating func allocateRequestID() -> PaginatedHistoryRequestID {
        precondition(nextRequestRawValue < UInt64.max, "History request identity space exhausted")
        defer { nextRequestRawValue += 1 }
        return PaginatedHistoryRequestID(rawValue: nextRequestRawValue)
    }

    private func cut(from state: ScopeState?) -> CanonicalResumeCut? {
        guard let state else { return nil }
        switch state {
        case .awaitingResume(_, _, let previousCut, _, _): return previousCut
        case .paging(let paging): return paging.previousCut ?? paging.cut
        case .live(let cut): return cut
        case .stale(let cut, _): return cut
        case .failed(_, let previousCut): return previousCut
        }
    }

    private func epoch(from state: ScopeState) -> UInt64? {
        switch state {
        case .awaitingResume(let reconciliation, _, _, _, _): reconciliation.connectionEpoch
        case .paging(let paging): paging.cut.connectionEpoch
        case .live(let cut): cut.connectionEpoch
        case .stale(_, let sealedConnectionEpoch): sealedConnectionEpoch
        case .failed(let failure, _): failure.reconciliation.connectionEpoch
        }
    }
}
