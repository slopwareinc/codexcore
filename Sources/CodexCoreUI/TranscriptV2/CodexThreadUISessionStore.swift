import CodexCore
import Foundation
import Observation

public struct CodexThreadUIPresentation: Sendable, Equatable {
    public var threadID: String
    public var transcript: CodexTranscriptV2
    public var rawScrollOffset: CGFloat
    public var isPinnedToBottom: Bool
    public var expandedWorkTurnIDs: Set<String>
    public var expandedRowIDs: Set<String>
    public var presentedAtByTurnID: [String: Date]

    public init(
        threadID: String,
        transcript: CodexTranscriptV2,
        rawScrollOffset: CGFloat = 0,
        isPinnedToBottom: Bool = true,
        expandedWorkTurnIDs: Set<String> = [],
        expandedRowIDs: Set<String> = [],
        presentedAtByTurnID: [String: Date] = [:]
    ) {
        self.threadID = threadID
        self.transcript = transcript
        self.rawScrollOffset = rawScrollOffset
        self.isPinnedToBottom = isPinnedToBottom
        self.expandedWorkTurnIDs = expandedWorkTurnIDs
        self.expandedRowIDs = expandedRowIDs
        self.presentedAtByTurnID = presentedAtByTurnID
    }
}

public struct CodexTranscriptPresentationDiagnostics: Sendable, Equatable {
    public fileprivate(set) var reducerApplyCount = 0
    public fileprivate(set) var presentationScheduleCount = 0
    public fileprivate(set) var presentationPublishCount = 0
    public fileprivate(set) var coalescedPureDeltaCount = 0
    public fileprivate(set) var coldHistoryRestoreCount = 0
    public fileprivate(set) var warmActivationCount = 0
    public fileprivate(set) var evictionCount = 0

    public init() {}
}

/// Reducer truth and lightweight UI state for a bounded warm set of threads.
///
/// Reducers mutate synchronously for every wire event. Only the active
/// presentation is copied out on a coalesced tick, so observation does not turn
/// each token into a SwiftUI/AppKit snapshot application.
@MainActor
@Observable
public final class CodexThreadUISessionStore {
    private struct PendingEvent {
        var method: String
        var params: CodexJSONValue
    }

    private struct Session {
        var reducer: CodexTranscriptReducerV2
        var presentedTranscript: CodexTranscriptV2
        var rawScrollOffset: CGFloat = 0
        var isPinnedToBottom = true
        var expandedWorkTurnIDs: Set<String> = []
        var expandedRowIDs: Set<String> = []
        var presentedAtByTurnID: [String: Date] = [:]
        var isHydrated = false
        var pendingEvents: [PendingEvent] = []
    }

    public let capacity: Int
    public private(set) var activeThreadID: String?
    public private(set) var presentationRevision = 0
    public private(set) var diagnostics = CodexTranscriptPresentationDiagnostics()

    @ObservationIgnored private var sessions: [String: Session] = [:]
    @ObservationIgnored private var leastToMostRecent: [String] = []
    @ObservationIgnored private var scheduledPublication: Task<Void, Never>?
    @ObservationIgnored private var scheduledThreadID: String?

    public init(capacity: Int = 12) {
        self.capacity = min(max(capacity, 8), 16)
    }

    public var activePresentation: CodexThreadUIPresentation? {
        _ = presentationRevision
        guard let activeThreadID, let session = sessions[activeThreadID] else { return nil }
        return Self.presentation(threadID: activeThreadID, session: session)
    }

    public var activeTruthTranscript: CodexTranscriptV2 {
        guard let activeThreadID else { return .init() }
        return sessions[activeThreadID]?.reducer.transcript ?? .init()
    }

    public func truthTranscript(for threadID: String) -> CodexTranscriptV2? {
        sessions[threadID]?.reducer.transcript
    }

    public func presentation(for threadID: String) -> CodexThreadUIPresentation? {
        guard let session = sessions[threadID] else { return nil }
        return Self.presentation(threadID: threadID, session: session)
    }

    public func containsWarmSession(for threadID: String) -> Bool {
        sessions[threadID]?.isHydrated == true
    }

    public func activate(threadID: String?) {
        scheduledPublication?.cancel()
        scheduledPublication = nil
        scheduledThreadID = nil
        activeThreadID = threadID
        guard let threadID else {
            presentationRevision &+= 1
            return
        }

        let existed = sessions[threadID] != nil
        ensureSession(threadID)
        touch(threadID)
        publishImmediately(threadID: threadID)
        if existed, sessions[threadID]?.isHydrated == true {
            diagnostics.warmActivationCount &+= 1
        }
    }

    public func submitLocalUserMessage(text: String, clientID: String, threadID: String) {
        ensureSession(threadID)
        sessions[threadID]?.isHydrated = true
        sessions[threadID]?.reducer.submitLocalUserMessage(text: text, clientID: clientID)
        ensureStableTimestamps(threadID: threadID)
        touch(threadID)
        schedulePresentationIfActive(threadID: threadID, pureDelta: false)
    }

    public func apply(method: String, params: CodexJSONValue, threadID: String) {
        ensureSession(threadID)
        guard var session = sessions[threadID] else { return }
        session.reducer.apply(method: method, params: params)
        if !session.isHydrated {
            session.pendingEvents.append(PendingEvent(method: method, params: params))
        }
        sessions[threadID] = session
        diagnostics.reducerApplyCount &+= 1
        ensureStableTimestamps(threadID: threadID)
        touch(threadID)
        schedulePresentationIfActive(threadID: threadID, pureDelta: Self.isPureDelta(method))
    }

    /// Restores cold history through the V2 reducer once, then replays any live
    /// events that arrived while history was loading. Warm sessions are kept.
    @discardableResult
    public func restoreHistory(
        items: [CodexJSONValue],
        threadID: String,
        force: Bool = false
    ) -> Bool {
        ensureSession(threadID)
        guard var session = sessions[threadID] else { return false }
        guard force || !session.isHydrated else {
            if activeThreadID == threadID { publishImmediately(threadID: threadID) }
            return false
        }

        let pendingEvents = session.pendingEvents
        var reducer = CodexTranscriptReducerV2(threadID: threadID)
        reducer.restoreHistory(items: items)
        for event in pendingEvents {
            reducer.apply(method: event.method, params: event.params)
        }
        session.reducer = reducer
        session.presentedTranscript = reducer.transcript
        session.pendingEvents = []
        session.isHydrated = true
        sessions[threadID] = session
        diagnostics.coldHistoryRestoreCount &+= 1
        ensureStableTimestamps(threadID: threadID)
        touch(threadID)
        if activeThreadID == threadID { publishImmediately(threadID: threadID) }
        return true
    }

    public func updateScrollState(
        threadID: String,
        rawOffset: CGFloat,
        isPinnedToBottom: Bool
    ) {
        guard sessions[threadID] != nil else { return }
        sessions[threadID]?.rawScrollOffset = rawOffset
        sessions[threadID]?.isPinnedToBottom = isPinnedToBottom
        touch(threadID)
    }

    public func setWorkExpanded(_ expanded: Bool, turnID: String, threadID: String) {
        guard sessions[threadID] != nil else { return }
        if expanded {
            sessions[threadID]?.expandedWorkTurnIDs.insert(turnID)
        } else {
            sessions[threadID]?.expandedWorkTurnIDs.remove(turnID)
        }
        if activeThreadID == threadID { presentationRevision &+= 1 }
        touch(threadID)
    }

    public func setRowExpanded(_ expanded: Bool, rowID: String, threadID: String) {
        guard sessions[threadID] != nil else { return }
        if expanded {
            sessions[threadID]?.expandedRowIDs.insert(rowID)
        } else {
            sessions[threadID]?.expandedRowIDs.remove(rowID)
        }
        if activeThreadID == threadID { presentationRevision &+= 1 }
        touch(threadID)
    }

    public func synchronizePresentation() {
        guard let activeThreadID else { return }
        scheduledPublication?.cancel()
        scheduledPublication = nil
        scheduledThreadID = nil
        publishImmediately(threadID: activeThreadID)
    }

    public func remove(threadID: String) {
        sessions.removeValue(forKey: threadID)
        leastToMostRecent.removeAll { $0 == threadID }
        if activeThreadID == threadID { activate(threadID: nil) }
    }

    public func reset() {
        scheduledPublication?.cancel()
        scheduledPublication = nil
        scheduledThreadID = nil
        sessions.removeAll(keepingCapacity: false)
        leastToMostRecent.removeAll(keepingCapacity: false)
        activeThreadID = nil
        diagnostics = CodexTranscriptPresentationDiagnostics()
        presentationRevision &+= 1
    }

    private func ensureSession(_ threadID: String) {
        guard sessions[threadID] == nil else { return }
        let reducer = CodexTranscriptReducerV2(threadID: threadID)
        sessions[threadID] = Session(reducer: reducer, presentedTranscript: reducer.transcript)
        touch(threadID)
        evictIfNeeded()
    }

    private func ensureStableTimestamps(threadID: String, now: Date = Date()) {
        guard var session = sessions[threadID] else { return }
        for turn in session.reducer.transcript.turns where session.presentedAtByTurnID[turn.id] == nil {
            session.presentedAtByTurnID[turn.id] = now
        }
        sessions[threadID] = session
    }

    private func schedulePresentationIfActive(threadID: String, pureDelta: Bool) {
        guard activeThreadID == threadID else { return }
        if scheduledPublication != nil {
            if pureDelta { diagnostics.coalescedPureDeltaCount &+= 1 }
            return
        }

        diagnostics.presentationScheduleCount &+= 1
        scheduledThreadID = threadID
        scheduledPublication = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(17))
            guard !Task.isCancelled, let self else { return }
            self.scheduledPublication = nil
            let scheduledThreadID = self.scheduledThreadID
            self.scheduledThreadID = nil
            guard scheduledThreadID == self.activeThreadID,
                  let scheduledThreadID else { return }
            self.publishImmediately(threadID: scheduledThreadID)
        }
    }

    private func publishImmediately(threadID: String) {
        guard activeThreadID == threadID, var session = sessions[threadID] else { return }
        ensureStableTimestamps(threadID: threadID)
        session = sessions[threadID] ?? session
        session.presentedTranscript = session.reducer.transcript
        sessions[threadID] = session
        diagnostics.presentationPublishCount &+= 1
        presentationRevision &+= 1
    }

    private func touch(_ threadID: String) {
        leastToMostRecent.removeAll { $0 == threadID }
        leastToMostRecent.append(threadID)
    }

    private func evictIfNeeded() {
        while sessions.count > capacity {
            guard let candidate = leastToMostRecent.first(where: { $0 != activeThreadID }) else { return }
            sessions.removeValue(forKey: candidate)
            leastToMostRecent.removeAll { $0 == candidate }
            diagnostics.evictionCount &+= 1
        }
    }

    private static func presentation(threadID: String, session: Session) -> CodexThreadUIPresentation {
        CodexThreadUIPresentation(
            threadID: threadID,
            transcript: session.presentedTranscript,
            rawScrollOffset: session.rawScrollOffset,
            isPinnedToBottom: session.isPinnedToBottom,
            expandedWorkTurnIDs: session.expandedWorkTurnIDs,
            expandedRowIDs: session.expandedRowIDs,
            presentedAtByTurnID: session.presentedAtByTurnID
        )
    }

    private static func isPureDelta(_ method: String) -> Bool {
        method.hasSuffix("/delta") || method.hasSuffix("Delta")
    }
}

public enum CodexThreadLiveStatus: String, Sendable, Equatable {
    case idle
    case running
    case failed
}

public struct CodexThreadStatusEntry: Sendable, Equatable {
    public var status: CodexThreadLiveStatus
    public var hasUnreadWhileInactive: Bool
    public var lastEventAt: Date

    public init(
        status: CodexThreadLiveStatus = .idle,
        hasUnreadWhileInactive: Bool = false,
        lastEventAt: Date = Date()
    ) {
        self.status = status
        self.hasUnreadWhileInactive = hasUnreadWhileInactive
        self.lastEventAt = lastEventAt
    }
}

@MainActor
@Observable
public final class CodexThreadStatusStore {
    public private(set) var entries: [String: CodexThreadStatusEntry] = [:]
    public private(set) var selectedThreadID: String?

    public init() {}

    public func select(threadID: String?) {
        selectedThreadID = threadID
        guard let threadID, var entry = entries[threadID] else { return }
        entry.hasUnreadWhileInactive = false
        entries[threadID] = entry
    }

    public func apply(method: String, threadID: String, at date: Date = Date()) {
        var entry = entries[threadID] ?? CodexThreadStatusEntry(lastEventAt: date)
        entry.lastEventAt = date
        switch method {
        case "turn/started":
            entry.status = .running
        case "turn/completed":
            entry.status = .idle
            if selectedThreadID != threadID { entry.hasUnreadWhileInactive = true }
        case "turn/failed", "error":
            entry.status = .failed
            if selectedThreadID != threadID { entry.hasUnreadWhileInactive = true }
        default:
            break
        }
        entries[threadID] = entry
    }

    public func remove(threadID: String) {
        entries.removeValue(forKey: threadID)
        if selectedThreadID == threadID { selectedThreadID = nil }
    }

    public func reset() {
        entries.removeAll(keepingCapacity: false)
        selectedThreadID = nil
    }
}
