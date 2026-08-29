import Foundation

public struct CodexTranscriptAccessibilityAnnouncement: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case started
        case progress
        case completed
        case failed
    }

    public var turnID: String
    public var kind: Kind
    public var message: String

    public init(turnID: String, kind: Kind, message: String) {
        self.turnID = turnID
        self.kind = kind
        self.message = message
    }
}

/// Pure VoiceOver lifecycle generator. It is presentation-side state and can
/// be fed to AppKit's accessibility notification API by a host.
public struct CodexTranscriptVoiceOverLifecycle: Sendable {
    private var lastStatusByTurnID: [String: CodexTurnStatusV2] = [:]
    private var lastTailByTurnID: [String: String] = [:]

    public init() {}

    public mutating func update(
        previous: CodexTranscriptV2? = nil,
        current: CodexTranscriptV2
    ) -> [CodexTranscriptAccessibilityAnnouncement] {
        var announcements: [CodexTranscriptAccessibilityAnnouncement] = []
        let previousTurns = Dictionary(uniqueKeysWithValues: (previous?.turns ?? []).map { ($0.id, $0) })
        for turn in current.turns {
            let priorStatus = lastStatusByTurnID[turn.id] ?? previousTurns[turn.id]?.status
            switch (priorStatus, turn.status) {
            case (_, .working) where priorStatus == nil || !isWorking(priorStatus):
                announcements.append(.init(
                    turnID: turn.id,
                    kind: .started,
                    message: "Turn started"
                ))
            case (.working?, .working):
                if let tail = turn.liveTail?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !tail.isEmpty,
                   tail != lastTailByTurnID[turn.id] {
                    announcements.append(.init(turnID: turn.id, kind: .progress, message: tail))
                }
            case (.working?, .done):
                announcements.append(.init(turnID: turn.id, kind: .completed, message: "Turn completed"))
            case (.working?, .failed(let message)):
                announcements.append(.init(turnID: turn.id, kind: .failed, message: message.isEmpty ? "Turn failed" : message))
            case (nil, .done):
                announcements.append(.init(turnID: turn.id, kind: .completed, message: "Turn completed"))
            case (nil, .failed(let message)):
                announcements.append(.init(turnID: turn.id, kind: .failed, message: message.isEmpty ? "Turn failed" : message))
            default:
                break
            }
            lastStatusByTurnID[turn.id] = turn.status
            lastTailByTurnID[turn.id] = turn.liveTail ?? ""
        }
        let currentIDs = Set(current.turns.map(\.id))
        lastStatusByTurnID = lastStatusByTurnID.filter { currentIDs.contains($0.key) }
        lastTailByTurnID = lastTailByTurnID.filter { currentIDs.contains($0.key) }
        return announcements
    }

    private func isWorking(_ status: CodexTurnStatusV2?) -> Bool {
        guard let status else { return false }
        if case .working = status { return true }
        return false
    }
}

public protocol CodexTranscriptAccessibilityAnnouncer: Sendable {
    func announce(_ announcement: CodexTranscriptAccessibilityAnnouncement)
}

public struct CodexTranscriptAnnouncementSink: CodexTranscriptAccessibilityAnnouncer {
    private let body: @Sendable (CodexTranscriptAccessibilityAnnouncement) -> Void

    public init(body: @escaping @Sendable (CodexTranscriptAccessibilityAnnouncement) -> Void) {
        self.body = body
    }

    public func announce(_ announcement: CodexTranscriptAccessibilityAnnouncement) {
        body(announcement)
    }
}

