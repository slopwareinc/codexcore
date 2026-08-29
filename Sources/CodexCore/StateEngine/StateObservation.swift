import Foundation

/// Coarse fields that changed in one canonical-state transaction.
///
/// The mask is invalidation metadata, not a second copy of canonical state.
public struct StateFieldMask: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let connection = Self(rawValue: 1 << 0)
    public static let account = Self(rawValue: 1 << 1)
    public static let threadMetadata = Self(rawValue: 1 << 2)
    public static let threadStatus = Self(rawValue: 1 << 3)
    public static let threadRelationships = Self(rawValue: 1 << 4)
    public static let threadHistory = Self(rawValue: 1 << 5)
    public static let turnMetadata = Self(rawValue: 1 << 6)
    public static let turnStatus = Self(rawValue: 1 << 7)
    public static let itemStructure = Self(rawValue: 1 << 8)
    public static let itemLifecycle = Self(rawValue: 1 << 9)
    public static let itemContent = Self(rawValue: 1 << 10)
    public static let plan = Self(rawValue: 1 << 11)
    public static let diff = Self(rawValue: 1 << 12)
    public static let usage = Self(rawValue: 1 << 13)
    public static let requests = Self(rawValue: 1 << 14)
    public static let submissionIntents = Self(rawValue: 1 << 15)
    public static let diagnostics = Self(rawValue: 1 << 17)
    public static let turnStructure = Self(rawValue: 1 << 18)
    public static let threadGoal = Self(rawValue: 1 << 19)
    public static let threadSettings = Self(rawValue: 1 << 20)
    public static let moderation = Self(rawValue: 1 << 21)
    public static let extensions = Self(rawValue: 1 << 22)
    public static let mcpServerStartup = Self(rawValue: 1 << 23)
    public static let backgroundTerminals = Self(rawValue: 1 << 24)

    public static let thread: Self = [
        .threadMetadata, .threadStatus, .threadRelationships, .threadHistory,
        .threadGoal, .threadSettings, .backgroundTerminals,
    ]

    public static let turn: Self = [
        .turnMetadata, .turnStatus, .turnStructure, .itemStructure, .plan, .diff, .usage,
    ]

    public static let item: Self = [.itemStructure, .itemLifecycle, .itemContent]

    public static let all: Self = [
        .connection, .account, .thread, .turn, .item, .requests,
        .submissionIntents, .diagnostics, .moderation,
        .extensions, .mcpServerStartup, .backgroundTerminals,
    ]
}

/// Entity selection for a canonical-state observation.
/// Thread and turn observations include their descendants.
public enum StateEntityScope: Sendable, Hashable {
    case all
    case global
    case threads(Set<ThreadID>)
    case turns(Set<TurnKey>)
    case items(Set<ItemKey>)

    public static func thread(_ id: ThreadID) -> Self { .threads([id]) }
    public static func turn(_ key: TurnKey) -> Self { .turns([key]) }
    public static func item(_ key: ItemKey) -> Self { .items([key]) }
}

/// A field-and-entity filter used by projections and other state consumers.
public struct StateObservationScope: Sendable, Hashable {
    public let entities: StateEntityScope
    public let fields: StateFieldMask

    public init(entities: StateEntityScope = .all, fields: StateFieldMask = .all) {
        self.entities = entities
        self.fields = fields
    }

    public static let all = Self()

    public static func global(fields: StateFieldMask = .all) -> Self {
        Self(entities: .global, fields: fields)
    }

    public static func thread(_ id: ThreadID, fields: StateFieldMask = .all) -> Self {
        Self(entities: .thread(id), fields: fields)
    }

    public static func turn(_ key: TurnKey, fields: StateFieldMask = .all) -> Self {
        Self(entities: .turn(key), fields: fields)
    }

    public static func item(_ key: ItemKey, fields: StateFieldMask = .all) -> Self {
        Self(entities: .item(key), fields: fields)
    }
}

/// Compact, ephemeral invalidation for one committed canonical transaction.
/// It is published to matching observers and is never retained for replay.
struct StateInvalidation: Sendable, Hashable {
    let revision: StateRevision
    let fields: StateFieldMask
    let threadIDs: Set<ThreadID>
    let turnKeys: Set<TurnKey>
    let itemKeys: Set<ItemKey>

    init(
        revision: StateRevision,
        fields: StateFieldMask,
        threadIDs: Set<ThreadID> = [],
        turnKeys: Set<TurnKey> = [],
        itemKeys: Set<ItemKey> = []
    ) {
        // Normalize descendant indexes once so scope matching can stay at set
        // intersection speed. Callers may provide only item or turn keys while
        // thread and turn observers still need to include their descendants.
        var normalizedThreadIDs = threadIDs
        normalizedThreadIDs.formUnion(turnKeys.lazy.map(\.threadID))
        normalizedThreadIDs.formUnion(itemKeys.lazy.map(\.threadID))

        var normalizedTurnKeys = turnKeys
        normalizedTurnKeys.formUnion(itemKeys.lazy.map(\.turnKey))

        self.revision = revision
        self.fields = fields
        self.threadIDs = normalizedThreadIDs
        self.turnKeys = normalizedTurnKeys
        self.itemKeys = itemKeys
    }

    init(_ batch: CanonicalStateChangeBatch) {
        // Derive all invalidation indexes in one walk. This is on the committed
        // transaction hot path, and the three batch accessors otherwise each
        // allocate and scan the same change list independently.
        var fields = StateFieldMask()
        var threadIDs: Set<ThreadID> = []
        var turnKeys: Set<TurnKey> = []
        var itemKeys: Set<ItemKey> = []
        for change in batch.changes {
            fields.formUnion(change.observationFields)
            if let threadID = change.threadID {
                threadIDs.insert(threadID)
            }
            if let turnKey = change.turnKey {
                turnKeys.insert(turnKey)
            }
            if let itemKey = change.itemKey {
                itemKeys.insert(itemKey)
            }
        }
        // The change-to-entity mapping above inserts each descendant's thread
        // and turn key in the same walk, so the indexes are already normalized.
        // Assign directly to avoid scanning the resulting sets a second time.
        self.revision = batch.revision
        self.fields = fields
        self.threadIDs = threadIDs
        self.turnKeys = turnKeys
        self.itemKeys = itemKeys
    }

    func affects(_ scope: StateObservationScope) -> Bool {
        guard !fields.intersection(scope.fields).isEmpty else { return false }

        switch scope.entities {
        case .all:
            return true
        case .global:
            return threadIDs.isEmpty && turnKeys.isEmpty && itemKeys.isEmpty
        case .threads(let observed):
            guard !observed.isEmpty else { return false }
            return !threadIDs.isDisjoint(with: observed)
        case .turns(let observed):
            guard !observed.isEmpty else { return false }
            return !turnKeys.isDisjoint(with: observed)
        case .items(let observed):
            return !observed.isEmpty && !itemKeys.isDisjoint(with: observed)
        }
    }
}

private extension CanonicalStateChange {
    var observationFields: StateFieldMask {
        switch self {
        case .accountUpdated:
            .account
        case .mcpServerStartupStatusUpdated:
            .mcpServerStartup
        case .backgroundTerminalsUpdated:
            .backgroundTerminals
        case .threadInserted, .threadUpdated, .threadRemoved:
            .thread
        case .threadLifecycleUpdated:
            .threadStatus
        case .threadEnvironmentUpdated, .threadNameReplaced:
            .threadMetadata
        case .threadGoalReplaced:
            .threadGoal
        case .threadSettingsReplaced:
            .threadSettings
        case .threadHistoryUpdated:
            .threadHistory
        case .threadDetailEvicted:
            [.threadStatus, .threadHistory, .turnStructure, .itemStructure]
        case .threadTurnsReplaced:
            .turnStructure
        case .turnInserted, .turnUpdated, .turnRemoved:
            .turn
        case .turnStarted, .turnCompleted:
            .turnStatus
        case .itemInserted, .itemUpdated:
            .item
        case .itemStarted:
            [.itemStructure, .itemLifecycle]
        case .itemDeltaAppended:
            .itemContent
        case .itemCompleted:
            [.itemLifecycle, .itemContent]
        case .itemRemoved:
            .itemStructure
        case .planReplaced:
            .plan
        case .diffReplaced:
            .diff
        case .turnErrorUpdated:
            [.turnMetadata, .diagnostics]
        case .tokenUsageReplaced:
            .usage
        case .moderationMetadataReplaced:
            .moderation
        case .turnExtensionReplaced:
            .extensions
        case .itemLiveFieldReplaced:
            .itemContent
        case .turnItemsMarkedUncertain:
            [.itemStructure, .diagnostics]
        case .submissionIntentInserted, .submissionIntentUpdated, .submissionIntentRemoved:
            .submissionIntents
        case .orphanDeltaBuffered, .orphanDeltaDropped:
            [.itemContent, .diagnostics]
        }
    }
}

/// Identifier for one registered observation. It is local to one hub.
public struct StateObservationID: RawRepresentable, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// A coalescible wake-up carrying the newest relevant canonical revision.
public struct StateRevisionSignal: Sendable, Hashable {
    public let latestRevision: StateRevision

    public init(latestRevision: StateRevision) {
        self.latestRevision = latestRevision
    }
}
