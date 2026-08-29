import Foundation

/// Presentation-only bookmark for one stable turn. It can be persisted by a
/// host without becoming part of canonical protocol state.
public struct CodexTranscriptBookmarkV2: Identifiable, Sendable, Equatable {
    public let id: String
    public let turnID: String
    public var label: String

    public init(turnID: String, label: String = "Bookmark") {
        self.id = turnID
        self.turnID = turnID
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Bookmark" : label
    }
}

/// Optional local badge shown beside a completed output. The value is bounded
/// before it enters presentation state so model text cannot grow the cache.
public struct CodexTranscriptOutputBadgeV2: Identifiable, Sendable, Equatable {
    public let id: String
    public let turnID: String
    public var text: String

    public init(turnID: String, text: String) {
        self.id = turnID
        self.turnID = turnID
        self.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }
}

public enum CodexTranscriptNavigationProjection {
    public static func bookmarks(for presentation: CodexThreadUIPresentation) -> [CodexTranscriptBookmarkV2] {
        presentation.transcript.turns.compactMap { turn in
            guard presentation.bookmarkedTurnIDs.contains(turn.id) else { return nil }
            let label = turn.userMessage?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexTranscriptBookmarkV2(
                turnID: turn.id,
                label: label?.isEmpty == false ? String(label!.prefix(80)) : "Bookmark"
            )
        }
    }

    public static func outputBadges(for presentation: CodexThreadUIPresentation) -> [CodexTranscriptOutputBadgeV2] {
        presentation.outputBadgesByTurnID.keys.sorted().compactMap { turnID in
            guard let value = presentation.outputBadgesByTurnID[turnID] else { return nil }
            return CodexTranscriptOutputBadgeV2(turnID: turnID, text: value)
        }
    }
}
