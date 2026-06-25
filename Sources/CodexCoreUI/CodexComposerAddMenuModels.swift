import Foundation

public enum CodexComposerAddMenuItemID: String, CaseIterable, Equatable, Sendable, Identifiable {
    case filesAndFolders
    case attachWarp
    case goal
    case planMode
    case plugins
    case documents
    case pdf
    case spreadsheets
    case presentations
    case templateCreator
    case browser
    case computer
    case github
    case filesAndChats

    public var id: String { rawValue }
}

public struct CodexComposerAddMenuItem: Identifiable, Equatable, Sendable {
    public var id: CodexComposerAddMenuItemID
    public var title: String
    public var systemImage: String
    public var isEnabled: Bool

    public init(
        id: CodexComposerAddMenuItemID,
        title: String,
        systemImage: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
    }
}

public enum CodexComposerAddMenuHostAction: Equatable, Sendable {
    case attachFilesAndFolders
    case enableGoalPursuit
    case enablePlanMode
    case openPlugins
    case openPluginLauncher(CodexComposerPluginLauncher)
    case openFilesAndChats
}

public struct CodexComposerPluginLauncher: Equatable, Sendable {
    public var itemID: CodexComposerAddMenuItemID
    public var title: String
    public var searchQuery: String
    public var preferredPluginNames: [String]
    public var fallbackDetail: CodexPluginRouteDetail

    public init(
        itemID: CodexComposerAddMenuItemID,
        title: String,
        searchQuery: String,
        preferredPluginNames: [String],
        fallbackDetail: CodexPluginRouteDetail
    ) {
        self.itemID = itemID
        self.title = title
        self.searchQuery = searchQuery
        self.preferredPluginNames = preferredPluginNames
        self.fallbackDetail = fallbackDetail
    }
}

public struct CodexComposerAddMenuRoute: Equatable, Sendable {
    public var itemID: CodexComposerAddMenuItemID
    public var hostActions: [CodexComposerAddMenuHostAction]
    public var activities: [CodexActivity]
    public var isEnabled: Bool

    public init(
        itemID: CodexComposerAddMenuItemID,
        hostActions: [CodexComposerAddMenuHostAction] = [],
        activities: [CodexActivity] = [],
        isEnabled: Bool = true
    ) {
        self.itemID = itemID
        self.hostActions = hostActions
        self.activities = activities
        self.isEnabled = isEnabled
    }
}

public enum CodexComposerChipKind: Equatable, Sendable {
    case goal
    case plan
}

public struct CodexComposerChipModel: Identifiable, Equatable, Sendable {
    public var kind: CodexComposerChipKind
    public var title: String
    public var clearAccessibilityLabel: String

    public var id: CodexComposerChipKind { kind }

    public init(kind: CodexComposerChipKind, title: String, clearAccessibilityLabel: String) {
        self.kind = kind
        self.title = title
        self.clearAccessibilityLabel = clearAccessibilityLabel
    }
}

public enum CodexComposerAddMenuModel {
    public static func observedItems(canUsePlanMode: Bool) -> [CodexComposerAddMenuItem] {
        [
            CodexComposerAddMenuItem(id: .filesAndFolders, title: "Files and folders", systemImage: "folder"),
            CodexComposerAddMenuItem(id: .attachWarp, title: "Attach Warp", systemImage: "terminal"),
            CodexComposerAddMenuItem(id: .goal, title: "Goal", systemImage: "target"),
            CodexComposerAddMenuItem(id: .planMode, title: "Plan mode", systemImage: "list.bullet.clipboard", isEnabled: canUsePlanMode),
            CodexComposerAddMenuItem(id: .plugins, title: "Plugins", systemImage: "shippingbox"),
            CodexComposerAddMenuItem(id: .documents, title: "Documents", systemImage: "doc.text"),
            CodexComposerAddMenuItem(id: .pdf, title: "PDF", systemImage: "doc.richtext"),
            CodexComposerAddMenuItem(id: .spreadsheets, title: "Spreadsheets", systemImage: "tablecells"),
            CodexComposerAddMenuItem(id: .presentations, title: "Presentations", systemImage: "rectangle.on.rectangle"),
            CodexComposerAddMenuItem(id: .templateCreator, title: "Template Creator", systemImage: "wand.and.stars"),
            CodexComposerAddMenuItem(id: .browser, title: "Browser", systemImage: "globe"),
            CodexComposerAddMenuItem(id: .computer, title: "Computer", systemImage: "display"),
            CodexComposerAddMenuItem(id: .github, title: "GitHub", systemImage: "chevron.left.forwardslash.chevron.right"),
            CodexComposerAddMenuItem(id: .filesAndChats, title: "Files and chats", systemImage: "magnifyingglass")
        ]
    }

    public static func route(itemID: CodexComposerAddMenuItemID, canUsePlanMode: Bool) -> CodexComposerAddMenuRoute {
        switch itemID {
        case .filesAndFolders:
            return CodexComposerAddMenuRoute(itemID: itemID, hostActions: [.attachFilesAndFolders])
        case .goal:
            return CodexComposerAddMenuRoute(itemID: itemID, hostActions: [.enableGoalPursuit])
        case .planMode:
            guard canUsePlanMode else {
                return CodexComposerAddMenuRoute(
                    itemID: itemID,
                    activities: [boundaryActivity(title: "Plan mode unavailable", detail: "The current app-server did not advertise Plan mode.")],
                    isEnabled: false
                )
            }
            return CodexComposerAddMenuRoute(itemID: itemID, hostActions: [.enablePlanMode])
        case .plugins:
            return CodexComposerAddMenuRoute(itemID: itemID, hostActions: [.openPlugins])
        case .filesAndChats:
            return CodexComposerAddMenuRoute(itemID: itemID, hostActions: [.openFilesAndChats])
        case .attachWarp:
            return boundaryRoute(itemID, title: "Attach Warp unavailable", detail: "Attach Warp is not wired in the native composer yet.")
        case .documents:
            return CodexComposerAddMenuRoute(itemID: itemID, hostActions: [.openPluginLauncher(.artifact(.documents))])
        case .pdf:
            return CodexComposerAddMenuRoute(itemID: itemID, hostActions: [.openPluginLauncher(.artifact(.pdf))])
        case .spreadsheets:
            return CodexComposerAddMenuRoute(itemID: itemID, hostActions: [.openPluginLauncher(.artifact(.spreadsheets))])
        case .presentations:
            return CodexComposerAddMenuRoute(itemID: itemID, hostActions: [.openPluginLauncher(.artifact(.presentations))])
        case .templateCreator:
            return CodexComposerAddMenuRoute(itemID: itemID, hostActions: [.openPluginLauncher(.artifact(.templateCreator))])
        case .browser:
            return CodexComposerAddMenuRoute(itemID: itemID, hostActions: [.openPluginLauncher(.browser)])
        case .computer:
            return CodexComposerAddMenuRoute(itemID: itemID, hostActions: [.openPluginLauncher(.computerUse)])
        case .github:
            return CodexComposerAddMenuRoute(itemID: itemID, hostActions: [.openPluginLauncher(.github)])
        }
    }

    public static func chips(isGoalPursuitEnabled: Bool, isPlanModeEnabled: Bool) -> [CodexComposerChipModel] {
        var chips: [CodexComposerChipModel] = []
        if isGoalPursuitEnabled {
            chips.append(CodexComposerChipModel(kind: .goal, title: "Goal", clearAccessibilityLabel: "Clear goal"))
        }
        if isPlanModeEnabled {
            chips.append(CodexComposerChipModel(kind: .plan, title: "Plan", clearAccessibilityLabel: "Clear plan"))
        }
        return chips
    }

    private static func boundaryRoute(
        _ itemID: CodexComposerAddMenuItemID,
        title: String,
        detail: String
    ) -> CodexComposerAddMenuRoute {
        CodexComposerAddMenuRoute(itemID: itemID, activities: [boundaryActivity(title: title, detail: detail)])
    }

    private static func boundaryActivity(title: String, detail: String) -> CodexActivity {
        CodexActivity(kind: .notice, title: title, detail: detail)
    }
}

public extension CodexComposerPluginLauncher {
    enum ArtifactKind: Equatable, Sendable {
        case documents
        case pdf
        case spreadsheets
        case presentations
        case templateCreator
    }

    static let browser = CodexComposerPluginLauncher(
        itemID: .browser,
        title: "Browser",
        searchQuery: "Browser",
        preferredPluginNames: ["browser"],
        fallbackDetail: CodexPluginRouteDetail.boundary(
            id: "browser",
            title: "Browser",
            detail: "Control the in-app browser with Codex",
            description: "Open and control the in-app browser for local development pages and files. Navigate, inspect, click, type, and take screenshots from chat.",
            statusLabel: "Plugin detail",
            prompt: "Browser\nTest my checkout flow on localhost",
            capabilities: ["Interactive", "Read", "Write"],
            metadata: ["Developer: OpenAI", "Category: Engineering"],
            legalLinks: ["Website", "Privacy Policy", "Terms of Service"]
        )
    )

    static let computerUse = CodexComposerPluginLauncher(
        itemID: .computer,
        title: "Computer Use",
        searchQuery: "Computer Use",
        preferredPluginNames: ["computer-use", "computer use"],
        fallbackDetail: CodexPluginRouteDetail.boundary(
            id: "computer-use",
            title: "Computer Use",
            detail: "Control Mac apps from Codex",
            description: "Computer Use can operate local Mac apps after installation and OS permission approval. Appshot is represented as a packaged capture boundary. This native build shows the install/permission boundary and does not invoke the permission flow.",
            statusLabel: "Install boundary",
            capabilities: ["Mac app control", "Permission required", "Appshot boundary"],
            metadata: ["Package: Computer Use", "Package: Appshot", "Runtime: local helper app"],
            boundaryActionTitle: "Add"
        )
    )

    static let github = CodexComposerPluginLauncher(
        itemID: .github,
        title: "GitHub",
        searchQuery: "GitHub",
        preferredPluginNames: ["github"],
        fallbackDetail: CodexPluginRouteDetail.boundary(
            id: "github",
            title: "GitHub",
            detail: "Work with pull requests and issues",
            description: "GitHub opens through the Plugins route when available. Installation and authentication stay bounded by the plugin provider.",
            statusLabel: "Plugin boundary",
            capabilities: ["Code review", "Issues", "Pull requests"]
        )
    )

    static func artifact(_ kind: ArtifactKind) -> CodexComposerPluginLauncher {
        switch kind {
        case .documents:
            return artifactLauncher(itemID: .documents, title: "Documents", searchQuery: "Documents", detail: "Create and edit document artifacts", capability: "Document artifacts")
        case .pdf:
            return artifactLauncher(itemID: .pdf, title: "PDF", searchQuery: "PDF", detail: "Read, create, and inspect PDF artifacts", capability: "PDF artifacts")
        case .spreadsheets:
            return artifactLauncher(itemID: .spreadsheets, title: "Spreadsheets", searchQuery: "Spreadsheets", detail: "Create and analyze spreadsheet artifacts", capability: "Spreadsheet artifacts")
        case .presentations:
            return artifactLauncher(itemID: .presentations, title: "Presentations", searchQuery: "Presentations", detail: "Create and edit presentation artifacts", capability: "Presentation artifacts")
        case .templateCreator:
            return artifactLauncher(itemID: .templateCreator, title: "Template Creator", searchQuery: "Template Creator", detail: "Create reusable artifact templates", capability: "Template artifacts")
        }
    }

    private static func artifactLauncher(
        itemID: CodexComposerAddMenuItemID,
        title: String,
        searchQuery: String,
        detail: String,
        capability: String
    ) -> CodexComposerPluginLauncher {
        CodexComposerPluginLauncher(
            itemID: itemID,
            title: title,
            searchQuery: searchQuery,
            preferredPluginNames: [searchQuery.lowercased().replacingOccurrences(of: " ", with: "-"), searchQuery.lowercased()],
            fallbackDetail: CodexPluginRouteDetail.boundary(
                id: itemID.rawValue,
                title: title,
                detail: detail,
                description: "\(title) support is represented as a plugin boundary. This build does not invoke artifact generation from the add menu until the plugin is installed and selected.",
                statusLabel: "Artifact boundary",
                capabilities: [capability],
                metadata: ["Source: Plugins route"]
            )
        )
    }
}
