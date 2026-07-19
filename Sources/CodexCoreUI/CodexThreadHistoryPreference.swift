import Foundation

/// History contract selected for newly created threads.
///
/// Existing threads always retain the mode persisted by app-server; changing
/// this preference never attempts to migrate them.
public enum CodexNewThreadHistoryMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case legacy
    case paginated

    /// Update alongside the pinned app-server/TUI protocol audit.
    public static let defaultForPinnedRelease: Self = .legacy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .legacy: "Legacy"
        case .paginated: "Paginated"
        }
    }

    public var detail: String {
        switch self {
        case .legacy:
            "Inline full history; supports fork and rollback"
        case .paginated:
            "Experimental cursor-backed history; fork and rollback are unavailable"
        }
    }
}
