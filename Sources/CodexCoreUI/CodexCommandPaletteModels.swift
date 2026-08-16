import Foundation

public enum CodexCommandPaletteAction: Equatable, Sendable {
    case newChat
    case openChat
    case openPlugins
    case openAutomations
    case openSettings
    case openSideChat
    case openReviewPanel
    case openMCPDetails
    case refreshSkills
    case configureModel
    case enableGoalPursuit
    case quitApp
}

public extension CodexCommandPaletteAction {
    /// The keyboard navigation direction used by the command menu.
    enum NavigationDirection: Sendable {
        case up
        case down
    }
}

public enum CodexCommandPaletteRowKind: Equatable, Sendable {
    case command(CodexCommandPaletteAction)
    case chat(CodexThreadSearchResult)
}

public struct CodexCommandPaletteRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var category: String
    public var systemImage: String
    public var shortcutBadge: String?
    public var kind: CodexCommandPaletteRowKind

    public init(
        id: String,
        title: String,
        detail: String,
        category: String,
        systemImage: String,
        shortcutBadge: String? = nil,
        kind: CodexCommandPaletteRowKind
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.category = category
        self.systemImage = systemImage
        self.shortcutBadge = shortcutBadge
        self.kind = kind
    }

    public var accessibilityLabel: String {
        [title, detail, shortcutBadge.map { "Shortcut \($0)" }]
            .compactMap { $0?.nilIfBlank }
            .joined(separator: ", ")
    }
}

/// Pure selection state for the command menu. Keeping this independent from
/// SwiftUI makes wrapping, empty-result behavior, and keyboard navigation easy
/// to verify without a running window.
public struct CodexCommandPaletteNavigationState: Equatable, Sendable {
    public private(set) var selectedRowID: String?

    public init(selectedRowID: String? = nil) {
        self.selectedRowID = selectedRowID
    }

    public var isEmpty: Bool { selectedRowID == nil }

    public mutating func reconcile(rows: [CodexCommandPaletteRow]) {
        guard !rows.isEmpty else {
            selectedRowID = nil
            return
        }
        if let selectedRowID, rows.contains(where: { $0.id == selectedRowID }) {
            return
        }
        selectedRowID = rows.first?.id
    }

    @discardableResult
    public mutating func move(
        _ direction: CodexCommandPaletteAction.NavigationDirection,
        in rows: [CodexCommandPaletteRow]
    ) -> CodexCommandPaletteRow? {
        guard !rows.isEmpty else {
            selectedRowID = nil
            return nil
        }

        let currentIndex = selectedRowID.flatMap { id in rows.firstIndex { $0.id == id } }
        let nextIndex: Int
        switch direction {
        case .down:
            nextIndex = currentIndex.map { ($0 + 1) % rows.count } ?? 0
        case .up:
            nextIndex = currentIndex.map { ($0 - 1 + rows.count) % rows.count } ?? rows.count - 1
        }
        selectedRowID = rows[nextIndex].id
        return rows[nextIndex]
    }

    public func selectedRow(in rows: [CodexCommandPaletteRow]) -> CodexCommandPaletteRow? {
        guard let selectedRowID else { return nil }
        return rows.first { $0.id == selectedRowID }
    }
}

public struct CodexCommandPaletteSection: Identifiable, Equatable, Sendable {
    public var title: String
    public var rows: [CodexCommandPaletteRow]

    public var id: String { title }

    public init(title: String, rows: [CodexCommandPaletteRow]) {
        self.title = title
        self.rows = rows
    }
}

public enum CodexCommandPaletteStatus: Equatable, Sendable {
    case empty
    case loading
    case error(String)
    case noResults(String)
    case results

    public var title: String? {
        switch self {
        case .empty, .results:
            return nil
        case .loading:
            return "Searching..."
        case .error(let message):
            return message
        case .noResults(let query):
            return "No results for \(query)"
        }
    }
}

public struct CodexCommandPaletteModel: Equatable, Sendable {
    public static let emptyCategoryTitles = [
        "Suggested",
        "Chat",
        "Navigation",
        "Panels",
        "Skills",
        "Configure",
        "App",
        "Chats"
    ]

    public var query: String
    public var sections: [CodexCommandPaletteSection]
    public var status: CodexCommandPaletteStatus

    public var rows: [CodexCommandPaletteRow] {
        sections.flatMap(\.rows)
    }

    public init(
        query: String,
        commandRows: [CodexCommandPaletteRow],
        chatResults: [CodexThreadSearchResult],
        isLoading: Bool,
        errorMessage: String?
    ) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmed

        if trimmed.isEmpty {
            let grouped = Dictionary(grouping: commandRows) { $0.category }
            sections = Self.emptyCategoryTitles.map { title in
                CodexCommandPaletteSection(title: title, rows: grouped[title] ?? [])
            }
            status = .empty
            return
        }

        let matchingCommands = Self.matchingCommands(commandRows, query: trimmed)
        let needle = trimmed.localizedLowercase
        let chatRows = Self.matchingChatRows(chatResults, needle: needle)
        var typedSections: [CodexCommandPaletteSection] = []
        if !matchingCommands.isEmpty {
            typedSections.append(CodexCommandPaletteSection(title: "Commands", rows: matchingCommands))
        }
        if !chatRows.isEmpty {
            typedSections.append(CodexCommandPaletteSection(title: "Chats", rows: chatRows))
        }
        sections = typedSections

        if isLoading {
            status = .loading
        } else if let errorMessage = errorMessage?.nilIfBlank {
            status = .error(errorMessage)
        } else if typedSections.allSatisfy(\.rows.isEmpty) {
            status = .noResults(trimmed)
        } else {
            status = .results
        }
    }

    public static var defaultCommandRows: [CodexCommandPaletteRow] {
        [
            command("new-chat", "New chat", "Start a new chat in the current project", "Suggested", "square.and.pencil", "⌘N", .newChat),
            command("chat-new", "New chat", "Clear the current thread and focus the composer", "Chat", "bubble.left.and.text.bubble.right", "⌘N", .newChat),
            command("chat-open", "Open chat", "Return to the active conversation", "Chat", "bubble.left", nil, .openChat),
            command("nav-plugins", "Plugins", "Open plugin and integration controls", "Navigation", "puzzlepiece.extension", nil, .openPlugins),
            command("nav-automations", "Automations", "Create and manage scheduled Codex tasks", "Navigation", "clock.arrow.circlepath", nil, .openAutomations),
            command("panel-side-chat", "Open side chat", "Use the side conversation panel for focused follow-up", "Panels", "sidebar.right", nil, .openSideChat),
            command("panel-review", "Open Review", "Inspect the latest turn changes when available", "Panels", "checklist", nil, .openReviewPanel),
            command("panel-mcp", "MCP details", "Inspect connected MCP servers and tools", "Panels", "server.rack", nil, .openMCPDetails),
            command("skills-refresh", "Refresh skills", "Reload slash commands and skill entries", "Skills", "arrow.clockwise", nil, .refreshSkills),
            command("configure-model", "Configure model", "Use composer model and reasoning controls", "Configure", "slider.horizontal.3", nil, .configureModel),
            command("configure-goal", "Goal", "Set a goal to keep pursuing", "Configure", "target", nil, .enableGoalPursuit),
            command("app-settings", "Settings", "Open About and app settings", "App", "gearshape", "⌘,", .openSettings),
            command("app-quit", "Quit", "Quit CodexCore", "App", "power", "⌘Q", .quitApp)
        ]
    }

    public static func chatRow(_ result: CodexThreadSearchResult, index: Int) -> CodexCommandPaletteRow {
        let snippet = result.snippet.nilIfBlank ?? result.thread.detail
        let projectSnippet = result.thread.workspacePath?.nilIfBlank ?? result.thread.id
        return CodexCommandPaletteRow(
            id: "chat-\(result.id)",
            title: result.thread.title,
            detail: [snippet, projectSnippet].compactMap(\.nilIfBlank).joined(separator: " - "),
            category: "Chats",
            systemImage: "bubble.left",
            shortcutBadge: "⌘\(index + 1)",
            kind: .chat(result)
        )
    }

    private static func command(
        _ id: String,
        _ title: String,
        _ detail: String,
        _ category: String,
        _ systemImage: String,
        _ shortcutBadge: String?,
        _ action: CodexCommandPaletteAction
    ) -> CodexCommandPaletteRow {
        CodexCommandPaletteRow(
            id: id,
            title: title,
            detail: detail,
            category: category,
            systemImage: systemImage,
            shortcutBadge: shortcutBadge,
            kind: .command(action)
        )
    }

    private static func matchingCommands(
        _ commandRows: [CodexCommandPaletteRow],
        query: String
    ) -> [CodexCommandPaletteRow] {
        let needle = query.lowercased()
        return commandRows.filter { row in
            row.title.lowercased().contains(needle) ||
                row.detail.lowercased().contains(needle) ||
                row.category.lowercased().contains(needle)
        }
    }

    private static func matchingChatRows(
        _ chatResults: [CodexThreadSearchResult],
        needle: String
    ) -> [CodexCommandPaletteRow] {
        var rows: [CodexCommandPaletteRow] = []
        rows.reserveCapacity(chatResults.count)

        for result in chatResults {
            let searchable = [
                result.thread.title,
                result.thread.detail,
                result.thread.workspacePath,
                result.snippet
            ]
            .compactMap { $0?.localizedLowercase }
            .joined(separator: " ")
            guard searchable.contains(needle) else { continue }

            rows.append(Self.chatRow(result, index: rows.count))
        }
        return rows
    }
}
