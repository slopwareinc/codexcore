import CodexCore
import Foundation

/// Inactive canonical presentations retained for fast thread reselection.
///
/// This value owns both its entries and their aggregate retained-byte estimate,
/// keeping cache mutations and byte accounting atomic from the store's point of
/// view. Entry weights are computed once, so normal reads, inserts, and removals
/// update the aggregate in O(1).
struct CodexWarmPresentationCache {
    struct Entry {
        let canonical: CodexCanonicalTranscriptPresentation
        let renderUpdate: CodexCanonicalTranscriptRenderUpdate
        let pendingRequests: [CodexTranscriptRequestPresentation]
        let approvals: [CodexApprovalPrompt]
        let estimatedRetainedByteCount: Int
        let lifecycleGeneration: UInt64

        init(
            canonical: CodexCanonicalTranscriptPresentation,
            renderUpdate: CodexCanonicalTranscriptRenderUpdate,
            pendingRequests: [CodexTranscriptRequestPresentation],
            approvals: [CodexApprovalPrompt],
            lifecycleGeneration: UInt64
        ) {
            self.canonical = canonical
            self.renderUpdate = renderUpdate
            self.pendingRequests = pendingRequests
            self.approvals = approvals
            self.lifecycleGeneration = lifecycleGeneration
            self.estimatedRetainedByteCount = CodexWarmPresentationRetentionPolicy
                .estimatedRetainedByteCount(
                    canonical: canonical,
                    renderUpdate: renderUpdate,
                    pendingRequests: pendingRequests,
                    approvals: approvals
                )
        }
    }

    private var entriesByThreadID: [ThreadID: Entry] = [:]
    private(set) var retainedByteCount = 0

    func contains(_ threadID: ThreadID) -> Bool {
        entriesByThreadID[threadID] != nil
    }

    mutating func insert(_ entry: Entry, for threadID: ThreadID) {
        let wasSaturated = retainedByteCount == .max
        let previous = entriesByThreadID.updateValue(entry, forKey: threadID)

        if wasSaturated {
            recomputeRetainedByteCount()
            return
        }
        if let previous {
            retainedByteCount = max(
                0,
                retainedByteCount - previous.estimatedRetainedByteCount
            )
        }
        let (sum, overflow) = retainedByteCount.addingReportingOverflow(
            entry.estimatedRetainedByteCount
        )
        retainedByteCount = overflow ? .max : sum
    }

    @discardableResult
    mutating func take(for threadID: ThreadID) -> Entry? {
        guard let removed = entriesByThreadID.removeValue(forKey: threadID) else {
            return nil
        }
        if retainedByteCount == .max {
            recomputeRetainedByteCount()
        } else {
            retainedByteCount = max(
                0,
                retainedByteCount - removed.estimatedRetainedByteCount
            )
        }
        return removed
    }

    mutating func removeAll(keepingCapacity: Bool) {
        entriesByThreadID.removeAll(keepingCapacity: keepingCapacity)
        retainedByteCount = 0
    }

    private mutating func recomputeRetainedByteCount() {
        retainedByteCount = 0
        for entry in entriesByThreadID.values {
            let (sum, overflow) = retainedByteCount.addingReportingOverflow(
                entry.estimatedRetainedByteCount
            )
            if overflow {
                retainedByteCount = .max
                return
            }
            retainedByteCount = sum
        }
    }
}

private enum CodexWarmPresentationRetentionPolicy {
    static func estimatedRetainedByteCount(
        canonical: CodexCanonicalTranscriptPresentation,
        renderUpdate: CodexCanonicalTranscriptRenderUpdate,
        pendingRequests: [CodexTranscriptRequestPresentation],
        approvals: [CodexApprovalPrompt]
    ) -> Int {
        var estimate = CodexPresentationRetentionEstimate(
            CodexWarmPresentationCache.Entry.self
        )
        estimate.add(canonical.estimatedRetainedByteCount)

        // These roots share copy-on-write payloads with the canonical
        // projection. Charge their collection storage without recounting every
        // transcript string.
        estimate.add(MemoryLayout<CodexCanonicalTranscriptRenderUpdate>.stride)
        estimate.addString(renderUpdate.threadID.rawValue)
        if let turnOrder = renderUpdate.turnOrder {
            estimate.addStringValues(turnOrder.lazy.map(\.rawValue))
        }
        estimate.addCollectionAllocation(count: renderUpdate.upsertedTurns.count)
        estimate.addProduct(
            renderUpdate.upsertedTurns.count,
            MemoryLayout<CodexTurnV2>.stride
        )
        estimate.addStringValues(renderUpdate.removedTurnIDs.lazy.map(\.rawValue))
        estimate.addStringValues(renderUpdate.dirtyTurnIDs.lazy.map(\.rawValue))
        estimate.addCollectionAllocation(count: renderUpdate.pendingRequests.count)
        estimate.addProduct(
            renderUpdate.pendingRequests.count,
            MemoryLayout<CodexTranscriptRequestPresentation>.stride
        )

        estimate.addCollectionAllocation(count: pendingRequests.count)
        estimate.addProduct(
            pendingRequests.count,
            MemoryLayout<CodexTranscriptRequestPresentation>.stride
        )

        estimate.addCollectionAllocation(count: approvals.count)
        for approval in approvals {
            estimate.add(estimatedRetainedByteCount(approval))
        }
        return estimate.total
    }

    private static func estimatedRetainedByteCount(
        _ approval: CodexApprovalPrompt
    ) -> Int {
        var estimate = CodexPresentationRetentionEstimate(CodexApprovalPrompt.self)
        if case .string(let requestID) = approval.id.requestID {
            estimate.addString(requestID)
        }
        estimate.addString(approval.method)
        estimate.addString(approval.title)
        estimate.addString(approval.detail)
        estimate.addString(approval.primaryValue)
        estimate.addString(approval.secondaryValue)
        estimate.addString(approval.cwd)
        estimate.addString(approval.reason)
        estimate.addString(approval.threadId)
        estimate.addString(approval.turnId)
        estimate.addString(approval.itemId)
        estimate.addString(approval.approvalId)
        estimate.addString(approval.environmentId)

        if let decisions = approval.availableDecisions {
            estimate.addCollectionAllocation(count: decisions.count)
            for decision in decisions {
                estimate.add(MemoryLayout<CodexCommandApprovalDecision>.stride)
                switch decision {
                case .acceptWithExecpolicyAmendment(let amendment):
                    estimate.addStringValues(amendment)
                case .applyNetworkPolicyAmendment(let amendment):
                    estimate.addString(amendment.host)
                case .accept, .acceptForSession, .decline, .cancel:
                    break
                }
            }
        }

        estimate.addCollectionAllocation(count: approval.commandActions.count)
        for action in approval.commandActions {
            estimate.add(MemoryLayout<CodexCommandAction>.stride)
            estimate.addString(action.type)
            estimate.addString(action.command)
            estimate.addString(action.name)
            estimate.addString(action.path)
            estimate.addString(action.query)
        }

        estimate.add(approval.additionalPermissions?.estimatedRetainedByteCount ?? 0)
        if let context = approval.networkApprovalContext {
            estimate.add(MemoryLayout<CodexNetworkApprovalContext>.stride)
            estimate.addString(context.host)
            estimate.addString(context.`protocol`)
        }
        if let amendment = approval.proposedExecpolicyAmendment {
            estimate.addStringValues(amendment)
        }
        estimate.addCollectionAllocation(
            count: approval.proposedNetworkPolicyAmendments.count
        )
        for amendment in approval.proposedNetworkPolicyAmendments {
            estimate.add(MemoryLayout<CodexNetworkPolicyAmendment>.stride)
            estimate.addString(amendment.host)
        }
        return estimate.total
    }
}
