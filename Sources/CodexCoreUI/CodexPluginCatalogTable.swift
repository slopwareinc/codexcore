import SwiftUI

enum CodexPluginLayoutMetrics {
    static let contentWidth: CGFloat = 736
    static let browseContentWidth: CGFloat = 1_080
    static let routeContentWidth: CGFloat = 1_080
    static let rowHeight: CGFloat = 64
    static let rowSpacing: CGFloat = 8
}

enum CodexPluginBrowseLayoutPolicy {
    static let twoColumnMinimumWidth: CGFloat = 680

    static func columnCount(availableWidth: CGFloat) -> Int {
        availableWidth >= twoColumnMinimumWidth ? 2 : 1
    }

    static func columns(availableWidth: CGFloat) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 28),
            count: columnCount(availableWidth: availableWidth)
        )
    }
}

enum CodexPluginStatusPresentation {
    static func label(for plugin: CodexPluginSummary, isPending: Bool) -> String {
        if isPending { return "Updating" }
        if plugin.isAdminDisabled { return "Disabled by admin" }
        if plugin.isInstalledByAdmin { return "Installed by admin" }
        if !plugin.installed, !plugin.canInstall { return "Unavailable in this context" }
        return plugin.statusLabel
    }

    static func appLabel(for app: CodexAppSummary) -> String {
        if app.isInstalled {
            switch app.runtimeEnabled {
            case true: return "Enabled"
            case false: return "Disabled"
            case nil: return "Installed"
            }
        }
        if app.isAccessible == false { return "Unavailable" }
        if app.isEnabled == false { return "Disabled" }
        if app.isAccessible == true { return "Available" }
        return "Status unknown"
    }
}

enum CodexMCPManageStatusPresentation {
    static func configurationLabel(for server: CodexMCPServerStatus) -> String {
        server.enabled ? "Configuration enabled" : "Configuration disabled"
    }

    static func runtimeLabel(for server: CodexMCPServerStatus) -> String {
        if server.error?.nilIfBlank != nil { return "Runtime error" }
        if let status = server.startupStatus?.nilIfBlank { return "Runtime: \(status.capitalized)" }
        return "Runtime status unknown"
    }

    static func authenticationLabel(for server: CodexMCPServerStatus) -> String {
        "Authentication: \(server.authStatusLabel)"
    }
}
