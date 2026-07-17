import Foundation

/// Stable app-server thread identity. Identity wrappers prevent accidentally routing
/// a turn or item by a bare string from a different protocol scope.
public struct ThreadID: RawRepresentable, Codable, Sendable, Hashable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct TurnID: RawRepresentable, Codable, Sendable, Hashable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ItemID: RawRepresentable, Codable, Sendable, Hashable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct SubmissionIntentID: RawRepresentable, Codable, Sendable, Hashable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Turn IDs are only unique within a thread. Always use this key in normalized state.
public struct TurnKey: Codable, Sendable, Hashable, Comparable {
    public let threadID: ThreadID
    public let turnID: TurnID

    public init(threadID: ThreadID, turnID: TurnID) {
        self.threadID = threadID
        self.turnID = turnID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.threadID, lhs.turnID) < (rhs.threadID, rhs.turnID)
    }
}

/// Item IDs are scoped to a turn. The full key prevents cross-thread event leakage.
public struct ItemKey: Codable, Sendable, Hashable, Comparable {
    public let threadID: ThreadID
    public let turnID: TurnID
    public let itemID: ItemID

    public init(threadID: ThreadID, turnID: TurnID, itemID: ItemID) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
    }

    public var turnKey: TurnKey {
        TurnKey(threadID: threadID, turnID: turnID)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.threadID, lhs.turnID, lhs.itemID) < (rhs.threadID, rhs.turnID, rhs.itemID)
    }
}

/// Monotonic local materialized-view revision. It is not a server replay cursor.
public struct StateRevision: RawRepresentable, Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { String(rawValue) }

    public static let zero = StateRevision(0)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    internal var successor: Self {
        precondition(rawValue < UInt64.max, "Canonical state revision exhausted")
        return StateRevision(rawValue + 1)
    }
}

/// App-server thread and turn timestamps are Unix seconds.
public struct ProtocolSeconds: RawRepresentable, Codable, Sendable, Hashable, Comparable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// App-server item lifecycle timestamps are Unix milliseconds.
public struct ProtocolMilliseconds: RawRepresentable, Codable, Sendable, Hashable, Comparable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A duration is intentionally distinct from an absolute millisecond timestamp.
public struct DurationMilliseconds: RawRepresentable, Codable, Sendable, Hashable, Comparable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Coverage is a lattice: information may move upward, never downward.
public enum StateCoverage: Int, Codable, Sendable, Hashable, Comparable, CaseIterable {
    case notLoaded
    case summary
    case full

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func merged(with other: Self) -> Self {
        max(self, other)
    }
}

/// Distinguishes an omitted field from an explicit protocol `null`/clear.
public enum CanonicalFieldUpdate<Value: Sendable & Equatable>: Sendable, Equatable {
    case unchanged
    case set(Value)
    case clear
}
