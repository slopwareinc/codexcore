import CodexCoreUI
import Foundation

/// Keeps each chat's workspace tool panel (terminals, browsers, open/selection
/// state) alive across chat switches and sidebar close, so switching back to a
/// recent chat restores its live sessions instead of recreating them.
///
/// State is retained for the most-recently-used `capacity` chats. When a chat
/// falls out of that window — or is explicitly closed/deleted — its sessions are
/// torn down. Only the SwiftUI view surface recycles; these session objects (and
/// the PTYs / web views they own) persist here.
@MainActor
final class CodexWorkspacePanelStore {
    private let capacity: Int
    private let defaultPanelWidth: CGFloat

    /// LRU order, least-recently-used first, most-recently-used last.
    private var lruOrder: [String] = []
    private var states: [String: CodexWorkspacePanelState] = [:]

    /// Sentinel key for a not-yet-persisted chat (no thread id assigned yet).
    private static let unassignedKey = "__codex_unassigned_thread__"

    init(capacity: Int = 20, defaultPanelWidth: CGFloat = 400) {
        self.capacity = max(1, capacity)
        self.defaultPanelWidth = defaultPanelWidth
    }

    /// Every alive chat state that currently hosts tools, most-recently-used
    /// last. These are the surfaces kept mounted so switching between recent
    /// chats is a visibility toggle rather than a teardown + rebuild.
    var mountedToolStates: [CodexWorkspacePanelState] {
        lruOrder.compactMap { states[$0] }.filter(\.hasOpenTools)
    }

    /// The panel state for a chat, creating it on first access and marking it as
    /// most-recently-used. Evicts the least-recently-used chat past capacity.
    func state(for threadID: String?) -> CodexWorkspacePanelState {
        let key = Self.key(for: threadID)
        touch(key)
        if let existing = states[key] {
            return existing
        }
        let created = CodexWorkspacePanelState(panelWidth: defaultPanelWidth)
        states[key] = created
        evictIfNeeded()
        return created
    }

    /// Move the not-yet-persisted chat's live state onto its newly assigned
    /// thread id, so opening a terminal/browser in a fresh chat survives the
    /// first message creating the thread.
    func migrateUnassigned(to threadID: String) {
        let newKey = Self.key(for: threadID)
        guard newKey != Self.unassignedKey,
              let unassigned = states[Self.unassignedKey] else { return }

        // If the destination already has state, keep it and drop the scratch one.
        if let existing = states[newKey] {
            if existing !== unassigned { unassigned.purge() }
        } else {
            states[newKey] = unassigned
        }
        states.removeValue(forKey: Self.unassignedKey)
        lruOrder.removeAll { $0 == Self.unassignedKey }
        touch(newKey)
    }

    /// Tear down and forget a chat's sessions (explicit close/delete).
    func purge(threadID: String) {
        let key = Self.key(for: threadID)
        states[key]?.purge()
        states.removeValue(forKey: key)
        lruOrder.removeAll { $0 == key }
    }

    /// Tear down every chat's sessions (disconnect / reset).
    func removeAll() {
        states.values.forEach { $0.purge() }
        states.removeAll()
        lruOrder.removeAll()
    }

    // MARK: - LRU bookkeeping

    private func touch(_ key: String) {
        lruOrder.removeAll { $0 == key }
        lruOrder.append(key)
    }

    private func evictIfNeeded() {
        guard lruOrder.count > capacity else { return }
        // Detach victims synchronously (plain collections, safe during a view
        // update) but defer the session teardown, which mutates @Published state,
        // to the next tick so it never publishes from within a SwiftUI update.
        var victims: [CodexWorkspacePanelState] = []
        while lruOrder.count > capacity {
            let key = lruOrder.removeFirst()
            if let state = states.removeValue(forKey: key) {
                victims.append(state)
            }
        }
        guard !victims.isEmpty else { return }
        Task { @MainActor in victims.forEach { $0.purge() } }
    }

    private static func key(for threadID: String?) -> String {
        let trimmed = threadID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? unassignedKey : trimmed
    }
}
