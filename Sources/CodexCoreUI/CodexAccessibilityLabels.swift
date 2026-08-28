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

public enum CodexTranscriptAccessibility {
    public static func assistantMessageLabel(prefix: String) -> String {
        "Assistant message: \(prefix)"
    }

    public static func userMessageLabel(prefix: String) -> String {
        "Your message: \(prefix)"
    }

    public static func toolCallLabel(name: String) -> String {
        "Tool call: \(name)"
    }

    public static func fileChangeLabel(path: String, lines: String) -> String {
        "File change: \(path), \(lines)"
    }

    public static func planUpdateLabel(detail: String) -> String {
        "Plan update: \(detail)"
    }

    public static let thinkingIndicatorLabel = "Codex is thinking"
    public static let threadLoadingLabel = "Loading chat"
    public static let emptyTranscriptLabel = "No messages yet. Type a prompt to start."
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

    public static func chatStatusValue(
        status: CodexThreadLiveStatus,
        hasUnreadUpdates: Bool,
        recencyLabel: String
    ) -> String {
        var values: [String] = []
        if hasUnreadUpdates {
            values.append("Unread updates")
        }
        switch status {
        case .running:
            values.append("Running")
        case .failed:
            values.append("Failed")
        case .idle:
            if !recencyLabel.isEmpty {
                values.append(recencyLabel)
            }
        }
        return values.joined(separator: ", ")
    }
}

public enum CodexWorkspaceTabAccessibility {
    public static func panelLabel(_ placement: CodexWorkspaceTabPlacement) -> String {
        placement == .right ? "Workspace right panel" : "Workspace bottom panel"
    }

    public static func moveLabel(
        title: String,
        to placement: CodexWorkspaceTabPlacement
    ) -> String {
        "Move \(title) to \(placement == .right ? "right" : "bottom") panel"
    }

    public static func closeLabel(title: String) -> String {
        "Close \(title)"
    }
}

public enum CodexButtonAccessibility {
    public static func accessLevelLabel(level: String) -> String {
        "Approval level: \(level). Change with arrow keys."
    }

    public static func modelLabel(model: String) -> String {
        "Model: \(model). Change with arrow keys."
    }

    public static let addMenuLabel = "Add attachment or command"
    public static let composerLabel = "Ask Codex anything about this workspace"
}
