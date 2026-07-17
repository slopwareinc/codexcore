import Foundation
import CodexCore

public struct CodexPromptStateActivity: Equatable, Sendable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

/// Disposable MainActor-facing projection of the pending interaction inbox.
///
/// This module owns presentation timestamps and request-card derivation only.
/// Request lifecycle, response capability, and terminal arbitration remain in
/// `CodexSession`.
public struct CodexPromptStateSession: Equatable, Sendable {
    public private(set) var approvalPrompts: [CodexApprovalPrompt] = []
    public private(set) var interactivePrompts: [CodexInteractivePrompt] = []
    public private(set) var revision: StateRevision?

    private var presentedAtByKey: [CodexServerRequestKey: Date] = [:]
    private var announcedKeys: Set<CodexServerRequestKey> = []

    public init() {}

    /// Atomically replaces the projection from one revisioned inbox snapshot.
    /// Lower-revision snapshots are ignored so reconnect/catch-up races cannot
    /// resurrect a request that has already become terminal.
    @discardableResult
    public mutating func sync(
        _ snapshot: CodexServerRequestInboxSnapshot,
        presentedAt now: Date = Date()
    ) -> [CodexPromptStateActivity] {
        if let revision, snapshot.revision < revision { return [] }

        let entries = snapshot.requests.sorted {
            $0.snapshot.arrivalOrdinal < $1.snapshot.arrivalOrdinal
        }
        let currentKeys = Set(entries.map(\.key))
        presentedAtByKey = presentedAtByKey.filter { currentKeys.contains($0.key) }

        var approvals: [CodexApprovalPrompt] = []
        var interactive: [CodexInteractivePrompt] = []
        var activities: [CodexPromptStateActivity] = []

        for entry in entries {
            let presentedAt = presentedAtByKey[entry.key] ?? now
            presentedAtByKey[entry.key] = presentedAt

            if let prompt = CodexApprovalPrompt(
                inboxEntry: entry,
                createdAt: presentedAt
            ) {
                approvals.append(prompt)
                if !announcedKeys.contains(entry.key) {
                    activities.append(.init(
                        title: "Approval requested",
                        detail: prompt.primaryValue ?? prompt.kind.displayName
                    ))
                }
            } else if let prompt = CodexInteractivePrompt(
                inboxEntry: entry,
                createdAt: presentedAt
            ) {
                interactive.append(prompt)
                if !announcedKeys.contains(entry.key) {
                    activities.append(.init(
                        title: "Input requested",
                        detail: prompt.detail
                    ))
                }
            }
        }

        approvalPrompts = approvals
        interactivePrompts = interactive
        revision = snapshot.revision
        announcedKeys = currentKeys
        return activities
    }

    public func approvalPrompt(
        for key: CodexServerRequestKey
    ) -> CodexApprovalPrompt? {
        approvalPrompts.first { $0.id == key }
    }

    public func interactivePrompt(
        for key: CodexServerRequestKey
    ) -> CodexInteractivePrompt? {
        interactivePrompts.first { $0.id == key }
    }

    public func contains(_ key: CodexServerRequestKey) -> Bool {
        approvalPrompt(for: key) != nil || interactivePrompt(for: key) != nil
    }

    public func resolutionActivity(
        for key: CodexServerRequestKey
    ) -> CodexPromptStateActivity? {
        if approvalPrompt(for: key) != nil {
            return .init(title: "Approval resolved", detail: key.presentationID)
        }
        if interactivePrompt(for: key) != nil {
            return .init(title: "Input resolved", detail: key.presentationID)
        }
        return nil
    }

    public mutating func reset() {
        approvalPrompts.removeAll(keepingCapacity: false)
        interactivePrompts.removeAll(keepingCapacity: false)
        presentedAtByKey.removeAll(keepingCapacity: false)
        announcedKeys.removeAll(keepingCapacity: false)
        revision = nil
    }
}
