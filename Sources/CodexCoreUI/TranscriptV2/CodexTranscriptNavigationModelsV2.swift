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

/// Presentation-only focus anchor used while menus, dialogs, or inline edits
/// temporarily leave the transcript. The anchor is intentionally stable by
/// semantic item ID rather than an AppKit index path.
public struct CodexTranscriptFocusAnchorV2: Sendable, Equatable {
    public let itemID: String
    public let characterOffset: Int?

    public init(itemID: String, characterOffset: Int? = nil) {
        self.itemID = itemID
        self.characterOffset = characterOffset.map { max(0, $0) }
    }
}

public struct CodexTranscriptBookmarkNavigator: Sendable, Equatable {
    public private(set) var currentTurnID: String?

    public init(currentTurnID: String? = nil) {
        self.currentTurnID = currentTurnID
    }

    @discardableResult
    public mutating func move(
        in presentation: CodexThreadUIPresentation,
        backwards: Bool = false
    ) -> CodexTranscriptBookmarkV2? {
        let bookmark = CodexTranscriptNavigationProjection.adjacentBookmark(
            in: presentation,
            from: currentTurnID,
            backwards: backwards
        )
        if let bookmark { currentTurnID = bookmark.turnID }
        return bookmark
    }

    public mutating func reset() {
        currentTurnID = nil
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

    public static func adjacentBookmark(
        in presentation: CodexThreadUIPresentation,
        from turnID: String?,
        backwards: Bool = false
    ) -> CodexTranscriptBookmarkV2? {
        let values = bookmarks(for: presentation)
        guard !values.isEmpty else { return nil }
        guard let turnID, let index = values.firstIndex(where: { $0.turnID == turnID }) else {
            return backwards ? values.last : values.first
        }
        let offset = backwards ? -1 : 1
        let next = index + offset
        guard values.indices.contains(next) else { return nil }
        return values[next]
    }

    public static func focusTarget(
        in presentation: CodexThreadUIPresentation,
        turnID: String,
        itemID: String? = nil
    ) -> String {
        if let itemID, !itemID.isEmpty { return "\(turnID):\(itemID)" }
        return "\(presentation.threadID):turn:\(turnID)"
    }
}
