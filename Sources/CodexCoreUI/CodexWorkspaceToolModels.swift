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
    public static let browserID = "browser"
    public static let filesID = "files"

    public static let manualBrowserTitle = "Manual Browser"
    public static let manualBrowserDetail = "Browse docs and local previews manually"
    public static let manualBrowserAccessibilityLabel = "Manual Browser"
    public static let manualBrowserAddressAccessibilityLabel = "Manual Browser address"

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
                id: browserID,
                title: manualBrowserTitle,
                detail: manualBrowserDetail,
                systemImage: "globe",
                isEnabled: true
            ),
            CodexWorkspaceToolOption(
                id: filesID,
                title: "Files",
                detail: "Browse this workspace",
                systemImage: "folder",
                isEnabled: true
            ),
        ]
    }
}
