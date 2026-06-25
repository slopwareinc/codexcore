import Foundation

public enum CodexComposerAccessibility {
    public static let stopButtonLabel = "Stop response"
    public static let stopButtonHelp = "Stop"

    public static func sendButtonLabel(isEnabled: Bool) -> String {
        isEnabled ? "Send message" : "Send message unavailable"
    }

    public static func sendButtonHelp(isEnabled: Bool) -> String {
        isEnabled ? "Send message (Command-Return)" : "Enter a message to send"
    }
}

public enum CodexSidebarAccessibility {
    public static func commandRowLabel(title: String, shortcut: String? = nil) -> String {
        guard let shortcut, !shortcut.isEmpty else {
            return title
        }
        return "\(title), shortcut \(shortcut)"
    }

    public static func collapseToggleLabel(isCollapsed: Bool) -> String {
        isCollapsed ? "Expand sidebar" : "Collapse sidebar"
    }

    public static func projectDisclosureLabel(projectTitle: String, isExpanded: Bool) -> String {
        "\(isExpanded ? "Collapse" : "Expand") project \(projectTitle)"
    }

    public static func projectNewChatLabel(projectTitle: String) -> String {
        "New chat in \(projectTitle)"
    }

    public static func projectActionsLabel(projectTitle: String) -> String {
        "Project actions for \(projectTitle)"
    }

    public static func chatPinLabel(isPinned: Bool, title: String) -> String {
        "\(isPinned ? "Unpin" : "Pin") chat \(title)"
    }

    public static func chatArchiveLabel(title: String) -> String {
        "Archive chat \(title)"
    }
}
