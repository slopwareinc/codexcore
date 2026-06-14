import Foundation

public struct CodexActivityLogSession: Equatable, Sendable {
    public private(set) var activities: [CodexActivity]
    public var limit: Int
    public var detailLimit: Int

    public init(
        activities: [CodexActivity] = [],
        limit: Int = 80,
        detailLimit: Int = 160
    ) {
        self.activities = activities
        self.limit = limit
        self.detailLimit = detailLimit
        trimToLimit()
    }

    public mutating func append(_ activity: CodexActivity) {
        activities.insert(activity.clippingDetail(to: detailLimit), at: 0)
        trimToLimit()
    }

    public mutating func append(_ kind: CodexActivity.Kind, title: String, detail: String) {
        append(CodexActivity(kind: kind, title: title, detail: detail))
    }

    public func clippedDetail(_ detail: String) -> String {
        Self.normalizedClippedDetail(detail, limit: detailLimit)
    }

    private mutating func trimToLimit() {
        if activities.count > limit {
            activities.removeLast(activities.count - limit)
        }
    }

    fileprivate static func normalizedClippedDetail(_ detail: String, limit: Int) -> String {
        let normalized = detail.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }
}

private extension CodexActivity {
    func clippingDetail(to limit: Int) -> CodexActivity {
        CodexActivity(
            id: id,
            kind: kind,
            title: title,
            detail: CodexActivityLogSession.normalizedClippedDetail(detail, limit: limit),
            createdAt: createdAt
        )
    }
}
