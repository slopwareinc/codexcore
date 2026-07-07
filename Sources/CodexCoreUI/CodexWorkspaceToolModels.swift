public struct CodexWorkspaceToolOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var systemImage: String
    public var isEnabled: Bool

    public init(
        id: String,
        title: String,
        detail: String,
        systemImage: String,
        isEnabled: Bool
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.isEnabled = isEnabled
    }
}

public enum CodexWorkspaceToolCatalog {
    public static let terminalID = "terminal"
    public static let subagentsID = "subagents"
    public static let browserID = "browser"
    public static let filesID = "files"
    public static let gitID = "git"

    public static var launcherOptions: [CodexWorkspaceToolOption] {
        [
            CodexWorkspaceToolOption(
                id: terminalID,
                title: "Terminal",
                detail: "Run shell commands in this workspace",
                systemImage: "terminal",
                isEnabled: true
            ),
            CodexWorkspaceToolOption(
                id: subagentsID,
                title: "Sub-agents",
                detail: "Not available in CodexCore yet",
                systemImage: "person.2.wave.2",
                isEnabled: false
            ),
            CodexWorkspaceToolOption(
                id: browserID,
                title: "Browser",
                detail: "Not available in CodexCore yet",
                systemImage: "globe",
                isEnabled: false
            ),
            CodexWorkspaceToolOption(
                id: filesID,
                title: "Files",
                detail: "Not available in CodexCore yet",
                systemImage: "folder",
                isEnabled: false
            ),
            CodexWorkspaceToolOption(
                id: gitID,
                title: "Git",
                detail: "Not available in CodexCore yet",
                systemImage: "arrow.triangle.branch",
                isEnabled: false
            ),
        ]
    }
}
