public struct CodexChatActionHandlers {
    public var pinChat: (() -> Void)?
    public var renameChat: (() -> Void)?
    public var archiveChat: (() -> Void)?
    public var deleteChat: (() -> Void)?
    public var openSideChat: (() -> Void)?
    public var copyChat: (() -> Void)?
    public var forkChat: (() -> Void)?
    public var addAutomation: (() -> Void)?

    public init(
        pinChat: (() -> Void)? = nil,
        renameChat: (() -> Void)? = nil,
        archiveChat: (() -> Void)? = nil,
        deleteChat: (() -> Void)? = nil,
        openSideChat: (() -> Void)? = nil,
        copyChat: (() -> Void)? = nil,
        forkChat: (() -> Void)? = nil,
        addAutomation: (() -> Void)? = nil
    ) {
        self.pinChat = pinChat; self.renameChat = renameChat; self.archiveChat = archiveChat
        self.deleteChat = deleteChat
        self.openSideChat = openSideChat; self.copyChat = copyChat; self.forkChat = forkChat
        self.addAutomation = addAutomation
    }

    public var menuItems: [CodexChatActionMenuItem] {
        CodexChatActionID.allCases.map { .init(id: $0, title: $0.title, shortcut: $0.shortcut, isEnabled: handler(for: $0) != nil) }
    }

    public func perform(_ id: CodexChatActionID) { handler(for: id)?() }

    public func handler(for id: CodexChatActionID) -> (() -> Void)? {
        switch id {
        case .pinChat: pinChat
        case .renameChat: renameChat
        case .archiveChat: archiveChat
        case .deleteChat: deleteChat
        case .openSideChat: openSideChat
        case .copy: copyChat
        case .fork: forkChat
        case .addAutomation: addAutomation
        }
    }
}

public enum CodexChatActionID: String, CaseIterable, Equatable, Sendable {
    case pinChat, renameChat, archiveChat, deleteChat, openSideChat, copy, fork, addAutomation

    public var title: String {
        switch self {
        case .pinChat: "Pin chat"
        case .renameChat: "Rename chat"
        case .archiveChat: "Archive chat"
        case .deleteChat: "Delete chat"
        case .openSideChat: "Open side chat"
        case .copy: "Copy"
        case .fork: "Fork"
        case .addAutomation: "Add automation…"
        }
    }

    public var shortcut: String? {
        switch self {
        case .pinChat: "⌥⌘P"
        case .renameChat: "⌥⌘R"
        case .archiveChat: "⇧⌘A"
        case .deleteChat: nil
        case .openSideChat: "⌥⌘S"
        default: nil
        }
    }
}

public struct CodexChatActionMenuItem: Equatable, Sendable {
    public var id: CodexChatActionID
    public var title: String
    public var shortcut: String?
    public var isEnabled: Bool

    public init(id: CodexChatActionID, title: String, shortcut: String? = nil, isEnabled: Bool) {
        self.id = id; self.title = title; self.shortcut = shortcut; self.isEnabled = isEnabled
    }

    public var displayTitle: String { shortcut.map { "\(title) \($0)" } ?? title }
}
