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
    case openFilesAndChats
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
            return boundaryRoute(itemID, title: "Documents unavailable", detail: "Document attachment plugins are not wired in the native composer yet.")
        case .pdf:
            return boundaryRoute(itemID, title: "PDF unavailable", detail: "PDF attachment plugins are not wired in the native composer yet.")
        case .spreadsheets:
            return boundaryRoute(itemID, title: "Spreadsheets unavailable", detail: "Spreadsheet attachment plugins are not wired in the native composer yet.")
        case .presentations:
            return boundaryRoute(itemID, title: "Presentations unavailable", detail: "Presentation attachment plugins are not wired in the native composer yet.")
        case .templateCreator:
            return boundaryRoute(itemID, title: "Template Creator unavailable", detail: "Template Creator is not wired in the native composer yet.")
        case .browser:
            return boundaryRoute(itemID, title: "Browser unavailable", detail: "Browser plugin launching is not wired in the native composer yet.")
        case .computer:
            return boundaryRoute(itemID, title: "Computer unavailable", detail: "Computer Use permission flow is not wired in the native composer yet.")
        case .github:
            return boundaryRoute(itemID, title: "GitHub unavailable", detail: "GitHub plugin launching is not wired in the native composer yet.")
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
