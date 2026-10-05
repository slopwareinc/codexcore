import Foundation
import SwiftUI

/// A single navigation intent for a loaded transcript turn or protocol item.
/// Use a new instance to revisit the same occurrence. Unloaded targets stay pending
/// until the host supplies their history page; requests never navigate another thread.
public struct CodexTranscriptFocusRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let threadID: String
    public let turnID: String
    public let itemID: String?

    public init(id: UUID = UUID(), threadID: String, turnID: String, itemID: String? = nil) {
        self.id = id; self.threadID = threadID; self.turnID = turnID; self.itemID = itemID
    }
}

private struct CodexTranscriptFocusRequestKey: EnvironmentKey {
    static let defaultValue: CodexTranscriptFocusRequest? = nil
}

extension EnvironmentValues {
    var codexTranscriptFocusRequest: CodexTranscriptFocusRequest? {
        get { self[CodexTranscriptFocusRequestKey.self] }
        set { self[CodexTranscriptFocusRequestKey.self] = newValue }
    }
}

extension View {
    public func codexTranscriptFocus(_ request: CodexTranscriptFocusRequest?) -> some View {
        environment(\.codexTranscriptFocusRequest, request)
    }
}

enum CodexTranscriptFocusProjection {
    struct Expansion: Equatable {
        var workExpanded: Bool
        var rowIDs: [String]
    }

    static func expansion(_ request: CodexTranscriptFocusRequest, presentation: CodexThreadUIPresentation) -> Expansion? {
        guard request.threadID == presentation.threadID,
              let turn = presentation.transcript.turns.first(where: { $0.id == request.turnID }) else { return nil }
        guard let itemID = request.itemID else { return .init(workExpanded: false, rowIDs: []) }
        if turn.userMessage?.id == itemID || turn.finalAnswer?.id == itemID
            || turn.generatedImages.contains(where: { $0.id == itemID })
            || turn.imageGenerationFailures.contains(where: { $0.id == itemID }) {
            return .init(workExpanded: false, rowIDs: [])
        }
        for segment in turn.conversationSegments {
            if segment.steeredMessage?.id == itemID { return .init(workExpanded: true, rowIDs: []) }
            for entry in segment.narrative {
                if case .workGroup(let group) = entry,
                   group.rows.contains(where: { $0.id == itemID }) {
                    return .init(workExpanded: true, rowIDs: [group.id, itemID])
                }
                if entry.id == itemID {
                    return .init(workExpanded: true, rowIDs: [.inlineActivity, .workGroup].contains(entry.focusKind) ? [itemID] : [])
                }
            }
        }
        return nil
    }

    static func itemID(_ request: CodexTranscriptFocusRequest, snapshot: CodexTranscriptRenderSnapshot) -> CodexTranscriptRenderItemID? {
        guard request.threadID == snapshot.threadID else { return nil }
        let candidates = snapshot.orderedItemIDs.compactMap { snapshot.itemsByID[$0] }.filter {
            $0.turnID == request.turnID && (request.itemID == nil || $0.sourceItemID == request.itemID)
        }
        return (candidates.first { [.user, .commentary, .finalAnswer, .expandedOutput].contains($0.textRole) }
                ?? candidates.first)?.id
    }
}

private extension CodexNarrativeEntry {
    enum FocusKind { case inlineActivity, workGroup, other }
    var focusKind: FocusKind {
        switch self { case .inlineActivity: .inlineActivity; case .workGroup: .workGroup; default: .other }
    }
}
