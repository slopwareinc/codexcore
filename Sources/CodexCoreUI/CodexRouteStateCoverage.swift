import Foundation

public enum CodexRouteStateKind: String, CaseIterable, Sendable, Equatable {
    case empty
    case loading
    case error

    public var title: String {
        switch self {
        case .empty: return "Empty"
        case .loading: return "Loading"
        case .error: return "Error"
        }
    }
}

public struct CodexRouteStateEntry: Equatable, Sendable {
    public var kind: CodexRouteStateKind
    public var title: String
    public var detail: String

    public init(kind: CodexRouteStateKind, title: String, detail: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

public struct CodexRouteStateCoverage: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var route: CodexAppRoute?
    public var entries: [CodexRouteStateEntry]
    public var notes: String

    public init(
        id: String,
        title: String,
        route: CodexAppRoute? = nil,
        entries: [CodexRouteStateEntry],
        notes: String
    ) {
        self.id = id
        self.title = title
        self.route = route
        self.entries = entries
        self.notes = notes
    }

    public func entry(for kind: CodexRouteStateKind) -> CodexRouteStateEntry? {
        entries.first { $0.kind == kind }
    }

    public var coversAllKinds: Bool {
        CodexRouteStateKind.allCases.allSatisfy { entry(for: $0) != nil }
    }
}

public enum CodexRouteStateCoverageCatalog {
    public static let all: [CodexRouteStateCoverage] = [
        CodexRouteStateCoverage(
            id: "chat",
            title: CodexAppRoute.chat.title,
            route: .chat,
            entries: [
                CodexRouteStateEntry(kind: .empty, title: "Ask Codex anything about this workspace", detail: "Blank chats render the observed prompt suggestions and an enabled composer."),
                CodexRouteStateEntry(kind: .loading, title: "Codex is working", detail: "Active turns use live status rows, stop affordances, and streaming transcript updates."),
                CodexRouteStateEntry(kind: .error, title: "Turn or connection notice", detail: "Turn, resume, interrupt, and connection failures are surfaced as transcript/system notices and activity rows.")
            ],
            notes: "Primary chat route owns the composer, live transcript, structured notices, and empty transcript prompt suggestions."
        ),
        CodexRouteStateCoverage(
            id: "search",
            title: CodexAppRoute.search.title,
            route: .search,
            entries: [
                CodexRouteStateEntry(kind: .empty, title: "Suggested, Chat, Navigation, Panels, Skills, Configure, App, Chats", detail: "Empty command menu shows the captured category groups."),
                CodexRouteStateEntry(kind: .loading, title: "Searching...", detail: "Typed search uses the command palette loading status while chat search is in flight."),
                CodexRouteStateEntry(kind: .error, title: "Search failed", detail: "Search errors render through the command palette status row and keep the overlay dismissible.")
            ],
            notes: "Search is an overlay route; dismissing it restores the prior content route."
        ),
        CodexRouteStateCoverage(
            id: "plugins",
            title: CodexAppRoute.plugins.title,
            route: .plugins,
            entries: [
                CodexRouteStateEntry(kind: .empty, title: "No plugins / No skills", detail: "Marketplace, Manage, and Skills tabs render route-local empty rows for empty filtered lists."),
                CodexRouteStateEntry(kind: .loading, title: "Refresh plugins", detail: "The route exposes refresh progress while plugin and skill catalog data reload."),
                CodexRouteStateEntry(kind: .error, title: "Plugin or skill catalog warning", detail: "Plugin, skill, and marketplace load errors render as status rows without hiding bounded detail panels.")
            ],
            notes: "Plugin actions remain mockable/bounded; hidden More/Create/Page action contents are not invented."
        ),
        CodexRouteStateCoverage(
            id: "automations",
            title: CodexAppRoute.automations.title,
            route: .automations,
            entries: [
                CodexRouteStateEntry(kind: .empty, title: CodexAutomationRouteState().emptyTitle, detail: "The route starts in the captured empty automation state with View templates and Create via chat actions."),
                CodexRouteStateEntry(kind: .loading, title: "No route-level loading", detail: "Template and Create via chat actions prepare unsent drafts synchronously and do not schedule work."),
                CodexRouteStateEntry(kind: .error, title: "Bounded automation notice", detail: "Unknown templates and unsupported menu contents stay disabled or route to visible bounded notices.")
            ],
            notes: "Automations does not persist or schedule local TOML data in the current slice."
        ),
        CodexRouteStateCoverage(
            id: "codex-mobile",
            title: CodexAppRoute.codexMobile.title,
            route: .codexMobile,
            entries: [
                CodexRouteStateEntry(kind: .empty, title: "No paired devices", detail: "The Mobile route shows landing copy, phone mock, warning, permission gate, and an empty client list."),
                CodexRouteStateEntry(kind: .loading, title: "Refresh status", detail: "Status refresh reads the generated remote-control status method when an app-server connection exists."),
                CodexRouteStateEntry(kind: .error, title: "Remote control unavailable", detail: "Unsupported or failed remote-control calls produce an explicit unavailable notice without silently enabling control.")
            ],
            notes: "Allow remains behind an explicit permission gate and the example host uses the unsupported provider for live enablement."
        ),
        CodexRouteStateCoverage(
            id: "settings-about",
            title: CodexAppRoute.settingsAbout.title,
            route: .settingsAbout,
            entries: [
                CodexRouteStateEntry(kind: .empty, title: "About Codex", detail: "Settings is intentionally limited to the About surface because detailed settings tabs were not evidenced."),
                CodexRouteStateEntry(kind: .loading, title: "Metadata from app bundle", detail: "Version/build/release metadata is read synchronously from app metadata when available."),
                CodexRouteStateEntry(kind: .error, title: "Version unavailable", detail: "Missing metadata falls back to explicit unavailable version and release-date text.")
            ],
            notes: "No detailed Settings tabs are invented from unavailable Oracle evidence."
        ),
        CodexRouteStateCoverage(
            id: "review-panel",
            title: "Review panel",
            entries: [
                CodexRouteStateEntry(kind: .empty, title: "No changes", detail: "Review file lists show clean or mismatch empty states instead of blank panels."),
                CodexRouteStateEntry(kind: .loading, title: "No git mutation in this build", detail: "Commit, push, branch checkout, and PR controls remain bounded/disabled while backend mutation is unavailable."),
                CodexRouteStateEntry(kind: .error, title: "Review file-list mismatch", detail: "Dirty worktree mismatch renders a warning empty state with explanatory detail.")
            ],
            notes: "Review remains paired with Side chat in the right panel and keeps git mutation bounded."
        ),
        CodexRouteStateCoverage(
            id: "side-chat-panel",
            title: "Side chat panel",
            entries: [
                CodexRouteStateEntry(kind: .empty, title: "Side chat", detail: "Opening Side chat creates an isolated empty transcript and independent composer without sending."),
                CodexRouteStateEntry(kind: .loading, title: "Side chat is sending", detail: "Side-chat sends use their own sending/interrupt state and ephemeral fork thread boundary."),
                CodexRouteStateEntry(kind: .error, title: "Side chat notice", detail: "Side-chat send and interrupt failures surface as activity notices without mutating the main transcript.")
            ],
            notes: "Side chat preserves parent/main transcript isolation."
        )
    ]

    public static var firstClassRoutes: [CodexRouteStateCoverage] {
        all.filter { $0.route != nil }
    }

    public static var panelSurfaces: [CodexRouteStateCoverage] {
        all.filter { $0.route == nil }
    }

    public static func coverage(for route: CodexAppRoute) -> CodexRouteStateCoverage? {
        firstClassRoutes.first { $0.route == route }
    }
}
