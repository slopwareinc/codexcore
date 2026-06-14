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
