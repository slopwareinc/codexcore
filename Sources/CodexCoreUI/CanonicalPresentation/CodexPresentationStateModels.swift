import CodexCore
import Foundation

/// A stateless seam between `CodexSession` and presentation projection.
public struct CodexPresentationStateAdapter: Sendable {
    public typealias Observe = @Sendable (StateObservationScope) async -> StateSnapshotObservation<CodexSessionStateSnapshot>
    public typealias Cancel = @Sendable (StateObservationID) async -> Void
    public typealias CurrentSnapshot = @Sendable (StateObservationScope) async -> CodexSessionStateSnapshot

    private let observeClosure: Observe
    private let cancelClosure: Cancel
    private let currentSnapshotClosure: CurrentSnapshot

    public init(
        observe: @escaping Observe,
        cancel: @escaping Cancel,
        currentSnapshot: @escaping CurrentSnapshot
    ) {
        self.observeClosure = observe
        self.cancelClosure = cancel
        self.currentSnapshotClosure = currentSnapshot
    }

    func observe(scope: StateObservationScope) async -> StateSnapshotObservation<CodexSessionStateSnapshot> {
        await observeClosure(scope)
    }

    func cancel(observationID: StateObservationID) async {
        await cancelClosure(observationID)
    }

    func currentSnapshot(scope: StateObservationScope) async -> CodexSessionStateSnapshot {
        await currentSnapshotClosure(scope)
    }
}

public extension CodexPresentationStateAdapter {
    init<Source: CodexSessionStateObserving>(stateSource: Source) {
        self.init(
            observe: { scope in await stateSource.observeSessionState(scope: scope) },
            cancel: { observationID in await stateSource.cancelObservation(observationID) },
            currentSnapshot: { scope in await stateSource.sessionStateSnapshot(scope: scope) }
        )
    }

    init(session: CodexSession) {
        self.init(stateSource: session)
    }
}

/// The only durable state owned by the presentation layer for one thread.
public struct CodexThreadPresentationLocalState: Sendable, Equatable {
    public var rawScrollOffset: CGFloat
    public var isPinnedToBottom: Bool
    public var expandedWorkTurnIDs: Set<String>
    public var expandedRowIDs: Set<String>
    public var expandedCardIDs: Set<String>
    public var focusedItemID: String?
    public var selectedDiffFileIndexByRowID: [String: Int]
    public var editingMessageID: String?
    public var editingMessageText: String
    public var bookmarkedTurnIDs: Set<String>
    public var outputBadgesByTurnID: [String: String]
    public var firstPresentedAtByTurnID: [String: Date]
    public var lastSeenAttentionRevision: StateRevision

    public init(
        rawScrollOffset: CGFloat = 0,
        isPinnedToBottom: Bool = true,
        expandedWorkTurnIDs: Set<String> = [],
        expandedRowIDs: Set<String> = [],
        expandedCardIDs: Set<String> = [],
        focusedItemID: String? = nil,
        selectedDiffFileIndexByRowID: [String: Int] = [:],
        editingMessageID: String? = nil,
        editingMessageText: String = "",
        bookmarkedTurnIDs: Set<String> = [],
        outputBadgesByTurnID: [String: String] = [:],
        firstPresentedAtByTurnID: [String: Date] = [:],
        lastSeenAttentionRevision: StateRevision = .zero
    ) {
        self.rawScrollOffset = rawScrollOffset
        self.isPinnedToBottom = isPinnedToBottom
        self.expandedWorkTurnIDs = expandedWorkTurnIDs
        self.expandedRowIDs = expandedRowIDs
        self.expandedCardIDs = expandedCardIDs
        self.focusedItemID = focusedItemID
        self.selectedDiffFileIndexByRowID = selectedDiffFileIndexByRowID
        self.editingMessageID = editingMessageID
        self.editingMessageText = editingMessageText
        self.bookmarkedTurnIDs = bookmarkedTurnIDs
        self.outputBadgesByTurnID = outputBadgesByTurnID
        self.firstPresentedAtByTurnID = firstPresentedAtByTurnID
        self.lastSeenAttentionRevision = lastSeenAttentionRevision
    }
}
