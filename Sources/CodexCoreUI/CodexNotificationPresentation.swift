import Foundation
import CodexCore

enum CodexNotificationPresentation {
    static func itemTypeTitle(_ type: String) -> String {
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
        if snapshot.rateLimitReachedType != nil {
            return reachedMessage(for: snapshot)
        }
        guard let primary = snapshot.primary, primary.usedPercent >= 80 else { return nil }
        return "Rate limit \(primary.usedPercent)% used\(resetSuffix(for: primary))"
    }

    public static func summary(for snapshot: CodexSchemaRateLimitSnapshot) -> String {
        if let reached = snapshot.rateLimitReachedType {
            return reachedMessage(for: snapshot) ?? humanized(reached.rawValue)
        }
        var parts: [String] = []
        if let primary = snapshot.primary {
            parts.append("Primary window \(primary.usedPercent)% used\(resetSuffix(for: primary))")
        }
        if let secondary = snapshot.secondary {
            parts.append("Secondary window \(secondary.usedPercent)% used\(resetSuffix(for: secondary))")
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
        }
    }

    private static func resetSuffix(for window: CodexSchemaRateLimitWindow) -> String {
        guard let duration = window.windowDurationMins else { return "" }
        return " · resets in \(duration)m window"
    }

    private static func humanized(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
