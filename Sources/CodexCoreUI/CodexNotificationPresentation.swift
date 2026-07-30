import Foundation
import CodexCore

public enum CodexNotificationPresentation {
    public static func itemTypeTitle(_ type: String) -> String {
        switch type {
        case "agentMessage", "assistantMessage": return "Codex message"
        case "commandExecution": return "Command"
        case "fileChange", "patch": return "File change"
        case "reasoning": return "Reasoning"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func methodTitle(_ method: String) -> String {
        method
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: ".", with: " ")
            .capitalized ?? method
    }

    static func tokenUsageSummary(_ usage: ThreadTokenUsage) -> String {
        if case .int(let used)? = usage.raw["used"], case .int(let limit)? = usage.raw["limit"] {
            return "\(used) / \(limit) tokens"
        }
        return "Updated"
    }
}

public enum CodexRateLimitPresentation {
    public static func bannerMessage(for snapshot: CodexSchemaRateLimitSnapshot) -> String? {
        bannerMessage(for: snapshot, now: .now)
    }

    static func bannerMessage(
        for snapshot: CodexSchemaRateLimitSnapshot,
        now: Date
    ) -> String? {
        if snapshot.rateLimitReachedType != nil {
            return reachedMessage(for: snapshot)
        }
        guard let primary = snapshot.primary, primary.usedPercent >= 80 else { return nil }
        return "Rate limit \(primary.usedPercent)% used\(resetSuffix(for: primary, now: now))"
    }

    public static func summary(for snapshot: CodexSchemaRateLimitSnapshot) -> String {
        if let reached = snapshot.rateLimitReachedType {
            return reachedMessage(for: snapshot) ?? humanized(reached.rawValue)
        }
        var parts: [String] = []
        if let primary = snapshot.primary {
            parts.append("Primary window \(primary.usedPercent)% used\(resetSuffix(for: primary, now: .now))")
        }
        if let secondary = snapshot.secondary {
            parts.append("Secondary window \(secondary.usedPercent)% used\(resetSuffix(for: secondary, now: .now))")
        }
        if let limitName = snapshot.limitName?.trimmingCharacters(in: .whitespacesAndNewlines), !limitName.isEmpty {
            parts.append(limitName)
        }
        return parts.isEmpty ? "No rate-limit details" : parts.joined(separator: " · ")
    }

    private static func reachedMessage(for snapshot: CodexSchemaRateLimitSnapshot) -> String? {
        guard let reached = snapshot.rateLimitReachedType else { return nil }
        switch reached {
        case .rateLimitReached:
            return "Rate limit reached. Usage resets soon."
        case .workspaceOwnerCreditsDepleted:
            return "Workspace owner credits depleted."
        case .workspaceMemberCreditsDepleted:
            return "Workspace member credits depleted."
        case .workspaceOwnerUsageLimitReached:
            return "Workspace owner usage limit reached."
        case .workspaceMemberUsageLimitReached:
            return "Workspace member usage limit reached."
        case .unrecognized(let value):
            return "\(humanized(value))."
        }
    }

    private static func resetSuffix(
        for window: CodexSchemaRateLimitWindow,
        now: Date
    ) -> String {
        guard let description = CodexRateLimitWindowText.description(for: window, now: now) else {
            return ""
        }
        return " · \(description)"
    }

    private static func humanized(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

enum CodexRateLimitWindowText {
    static func description(
        for window: CodexSchemaRateLimitWindow,
        now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        if let resetsAt = window.resetsAt, resetsAt > 0 {
            let resetDate = Date(timeIntervalSince1970: TimeInterval(resetsAt))
            let interval = resetDate.timeIntervalSince(now)

            if interval <= 0 {
                return "resets soon"
            }

            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone

            if interval < 24 * 60 * 60 {
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return "resets at \(formatter.string(from: resetDate))"
            }

            formatter.setLocalizedDateFormatFromTemplate("MMM d")
            return "resets \(formatter.string(from: resetDate))"
        }

        return window.windowDurationMins.map(durationLabel(minutes:))
    }

    static func durationLabel(minutes: Int) -> String {
        if minutes > 0, minutes.isMultiple(of: 24 * 60) {
            return unitLabel(minutes / (24 * 60), unit: "day")
        }
        if minutes > 0, minutes.isMultiple(of: 60) {
            return unitLabel(minutes / 60, unit: "hour")
        }
        return unitLabel(minutes, unit: "minute")
    }

    private static func unitLabel(_ value: Int, unit: String) -> String {
        "\(value)-\(unit) window"
    }
}
