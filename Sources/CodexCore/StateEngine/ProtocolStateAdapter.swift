import Foundation

/// Why an app-server frame does or does not produce canonical state mutations.
/// Every generated notification method has one explicit disposition.
public enum ProtocolStateDisposition: String, Codable, Sendable, Equatable {
    case state
    case requestResolution
    case operation
    case diagnostic
    case ignored
    case unknownMethod
}

/// Schema-validated warning content emitted by app-server.
///
/// Values are decoded losslessly at the protocol boundary, then bounded before
/// they enter the session diagnostic ring. Keeping the cases typed prevents UI
/// projections from reparsing raw notification dictionaries or method strings.
public enum CodexProtocolDiagnosticContent: Sendable, Equatable {
    case warning(message: String)
    case guardianWarning(message: String)
    case deprecationNotice(summary: String, details: String?)
    case configWarning(summary: String, details: String?, path: String?)
    case windowsWorldWritableWarning(
        extraCount: Int,
        failedScan: Bool,
        samplePaths: [String]
    )
}

/// One typed warning-class fact before session-level size bounding.
public struct CodexProtocolDiagnostic: Sendable, Equatable {
    public let method: CodexAppServerNotificationMethod
    public let threadID: String?
    public let content: CodexProtocolDiagnosticContent

    public init(
        method: CodexAppServerNotificationMethod,
        threadID: String? = nil,
        content: CodexProtocolDiagnosticContent
    ) {
        self.method = method
        self.threadID = threadID
        self.content = content
    }
}

public struct ProtocolStateAdaptation: Sendable, Equatable {
    public let disposition: ProtocolStateDisposition
    public let mutations: [CanonicalStateMutation]
    public let diagnostic: String?
    public let protocolDiagnostic: CodexProtocolDiagnostic?

    public init(
        disposition: ProtocolStateDisposition,
        mutations: [CanonicalStateMutation] = [],
        diagnostic: String? = nil,
        protocolDiagnostic: CodexProtocolDiagnostic? = nil
    ) {
        self.disposition = disposition
        self.mutations = mutations
        self.diagnostic = diagnostic
        self.protocolDiagnostic = protocolDiagnostic
    }

    public static func state(_ mutations: [CanonicalStateMutation]) -> Self {
        Self(disposition: .state, mutations: mutations)
    }

    public static func diagnostic(_ diagnostic: CodexProtocolDiagnostic) -> Self {
        Self(disposition: .diagnostic, protocolDiagnostic: diagnostic)
    }
}

/// Original request facts needed to interpret a correlated JSON-RPC response.
/// Responses are adapted and reduced at their receive position before the request
/// continuation is resumed.
public struct ProtocolResponseContext: Sendable, Equatable {
    public let method: CodexAppServerClientMethod
    public let requestParams: [String: CodexJSONValue]
    public let connectionEpoch: UInt64
    public let resumeGeneration: UInt64
    public let itemCollectionPolicy: CanonicalItemCollectionMergePolicy
    public let assertedItemsCoverage: StateCoverage?

    public init(
        method: CodexAppServerClientMethod,
        requestParams: [String: CodexJSONValue] = [:],
        connectionEpoch: UInt64,
        resumeGeneration: UInt64 = 0,
        itemCollectionPolicy: CanonicalItemCollectionMergePolicy = .mergePreservingExistingOrder,
        assertedItemsCoverage: StateCoverage? = nil
    ) {
        self.method = method
        self.requestParams = requestParams
        self.connectionEpoch = connectionEpoch
        self.resumeGeneration = resumeGeneration
        self.itemCollectionPolicy = itemCollectionPolicy
        self.assertedItemsCoverage = assertedItemsCoverage
    }
}

public enum ProtocolStateAdapterError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformedNotification(method: String, message: String)
    case malformedResponse(method: String, message: String)
    case missingRequestContext(method: String, field: String)
    case missingItemIdentity(method: String, type: String)

    public var description: String {
        switch self {
        case .malformedNotification(let method, let message):
            "Malformed \(method) notification: \(message)"
        case .malformedResponse(let method, let message):
            "Malformed \(method) response: \(message)"
        case .missingRequestContext(let method, let field):
            "Response for \(method) requires original request field \(field)"
        case .missingItemIdentity(let method, let type):
            "\(method) item of type \(type) has no stable id"
        }
    }
}

/// Generated app-server protocol Adapter. It is synchronous and has no state;
/// the sole session actor immediately feeds returned mutations to its reducer.
public struct ProtocolStateAdapter: Sendable {
    public init() {}

    public func adaptNotification(
        method: String,
        params: [String: CodexJSONValue]
    ) throws -> ProtocolStateAdaptation {
        guard let known = CodexAppServerNotificationMethod(rawValue: method) else {
            return ProtocolStateAdaptation(
                disposition: .unknownMethod,
                diagnostic: "Unknown app-server notification: \(method)"
            )
        }
        return try adaptNotification(method: known, params: params)
    }

    public func adaptNotification(
        method: CodexAppServerNotificationMethod,
        params: [String: CodexJSONValue]
    ) throws -> ProtocolStateAdaptation {
        try adaptKnownNotification(method: method, params: params)
    }

    public func adaptResponse(
        _ context: ProtocolResponseContext,
        result: CodexJSONValue
    ) throws -> ProtocolStateAdaptation {
        try adaptKnownResponse(context, result: result)
    }
}

// MARK: - Typed turn-error overlay

/// The generated `CodexErrorInfo` is intentionally an opaque JSON value
/// because the upstream schema uses an open union. This additive overlay
/// recognizes the currently documented variants while retaining unknown data.
public enum CodexTurnErrorInfo: Sendable, Equatable {
    case contextWindowExceeded
    case usageLimitExceeded
    case sessionBudgetExceeded
    case serverOverloaded
    case cyberPolicy
    case internalServerError
    case unauthorized
    case badRequest
    case threadRollbackFailed
    case sandboxError
    case other
    case httpConnectionFailed(httpStatusCode: Int?)
    case responseStreamConnectionFailed(httpStatusCode: Int?)
    case responseStreamDisconnected(httpStatusCode: Int?)
    case responseTooManyFailedAttempts(httpStatusCode: Int?)
    case activeTurnNotSteerable(httpStatusCode: Int?)
    case unknown(type: String?, raw: CodexJSONValue)

    public var type: String {
        switch self {
        case .contextWindowExceeded: "contextWindowExceeded"
        case .usageLimitExceeded: "usageLimitExceeded"
        case .sessionBudgetExceeded: "sessionBudgetExceeded"
        case .serverOverloaded: "serverOverloaded"
        case .cyberPolicy: "cyberPolicy"
        case .internalServerError: "internalServerError"
        case .unauthorized: "unauthorized"
        case .badRequest: "badRequest"
        case .threadRollbackFailed: "threadRollbackFailed"
        case .sandboxError: "sandboxError"
        case .other: "other"
        case .httpConnectionFailed: "httpConnectionFailed"
        case .responseStreamConnectionFailed: "responseStreamConnectionFailed"
        case .responseStreamDisconnected: "responseStreamDisconnected"
        case .responseTooManyFailedAttempts: "responseTooManyFailedAttempts"
        case .activeTurnNotSteerable: "activeTurnNotSteerable"
        case .unknown(let type, _): type ?? "unknown"
        }
    }

    public var httpStatusCode: Int? {
        switch self {
        case .httpConnectionFailed(let statusCode),
             .responseStreamConnectionFailed(let statusCode),
             .responseStreamDisconnected(let statusCode),
             .responseTooManyFailedAttempts(let statusCode),
             .activeTurnNotSteerable(let statusCode):
            statusCode
        default:
            nil
        }
    }

    init(rawValue: CodexJSONValue) {
        guard let object = rawValue.objectValue,
              let rawType = object.string(at: "type") else {
            self = .unknown(type: nil, raw: rawValue)
            return
        }
        let statusCode = object.int(at: "httpStatusCode")
            ?? object.int(at: "http_status_code")
            ?? object.int(at: "statusCode")
        switch rawType {
        case "contextWindowExceeded", "context_window_exceeded": self = .contextWindowExceeded
        case "usageLimitExceeded", "usage_limit_exceeded": self = .usageLimitExceeded
        case "sessionBudgetExceeded", "session_budget_exceeded": self = .sessionBudgetExceeded
        case "serverOverloaded", "server_overloaded": self = .serverOverloaded
        case "cyberPolicy", "cyber_policy": self = .cyberPolicy
        case "internalServerError", "internal_server_error": self = .internalServerError
        case "unauthorized": self = .unauthorized
        case "badRequest", "bad_request": self = .badRequest
        case "threadRollbackFailed", "thread_rollback_failed": self = .threadRollbackFailed
        case "sandboxError", "sandbox_error": self = .sandboxError
        case "other": self = .other
        case "httpConnectionFailed", "http_connection_failed":
            self = .httpConnectionFailed(httpStatusCode: statusCode)
        case "responseStreamConnectionFailed", "response_stream_connection_failed":
            self = .responseStreamConnectionFailed(httpStatusCode: statusCode)
        case "responseStreamDisconnected", "response_stream_disconnected":
            self = .responseStreamDisconnected(httpStatusCode: statusCode)
        case "responseTooManyFailedAttempts", "response_too_many_failed_attempts":
            self = .responseTooManyFailedAttempts(httpStatusCode: statusCode)
        case "activeTurnNotSteerable", "active_turn_not_steerable":
            self = .activeTurnNotSteerable(httpStatusCode: statusCode)
        default:
            self = .unknown(type: rawType, raw: rawValue)
        }
    }
}

public typealias CodexErrorInfo = CodexTurnErrorInfo

public extension CanonicalTurnError {
    /// Typed interpretation of `codexErrorInfo`; the original raw value stays
    /// available through `codexErrorInfo` for forward-compatible consumers.
    var typedCodexErrorInfo: CodexTurnErrorInfo? {
        codexErrorInfo.map(CodexTurnErrorInfo.init(rawValue:))
    }

    /// Alias suitable for callers that prefer the shorter error-info name.
    var codexErrorInfoKind: CodexTurnErrorInfo? { typedCodexErrorInfo }

    /// HTTP status carried by connection/stream error variants, when present.
    var httpStatusCode: Int? { typedCodexErrorInfo?.httpStatusCode }
}

// MARK: - Exhaustive notification disposition

private extension ProtocolStateAdapter {
    func adaptKnownNotification(
        method: CodexAppServerNotificationMethod,
        params: [String: CodexJSONValue]
    ) throws -> ProtocolStateAdaptation {
        switch method {
        case .error:
            let value: CodexSchemaErrorNotification = try decodeNotification(method, params)
            return .state([.turnErrorReported(
                turn: TurnKey(threadID: .init(value.threadID), turnID: .init(value.turnID)),
                error: canonicalError(value.error),
                willRetry: value.willRetry
            )])

        case .threadStarted:
            let value: CodexSchemaThreadStartedNotification = try decodeNotification(method, params)
            return .state(try threadMutations(
                value.thread,
                rawThread: params.object(at: "thread"),
                isLoaded: true,
                itemPolicy: .mergePreservingExistingOrder
            ))

        case .threadStatusChanged:
            let value: CodexSchemaThreadStatusChangedNotification = try decodeNotification(method, params)
            return .state([.threadUpsert(CanonicalThread(
                id: .init(value.threadID),
                status: canonicalStatus(value.status),
                consistency: .partial
            ))])

        case .threadArchived:
            let value: CodexSchemaThreadArchivedNotification = try decodeNotification(method, params)
            return .state([.threadLifecycleUpdated(
                id: .init(value.threadID),
                isArchived: .set(true),
                isLoaded: .unchanged
            )])

        case .threadDeleted:
            let value: CodexSchemaThreadDeletedNotification = try decodeNotification(method, params)
            return .state([.threadRemoved(.init(value.threadID))])

        case .threadUnarchived:
            let value: CodexSchemaThreadUnarchivedNotification = try decodeNotification(method, params)
            return .state([.threadLifecycleUpdated(
                id: .init(value.threadID),
                isArchived: .set(false),
                isLoaded: .unchanged
            )])

        case .threadClosed:
            let value: CodexSchemaThreadClosedNotification = try decodeNotification(method, params)
            return .state([
                .threadLifecycleUpdated(
                    id: .init(value.threadID),
                    isArchived: .unchanged,
                    isLoaded: .set(false)
                ),
                .threadUpsert(CanonicalThread(
                    id: .init(value.threadID),
                    status: .notLoaded,
                    consistency: .partial
                )),
            ])

        case .skillsChanged:
            return operation(method)

        case .threadNameUpdated:
            let value: CodexSchemaThreadNameUpdatedNotification = try decodeNotification(method, params)
            return .state([.threadNameReplaced(id: .init(value.threadID), name: value.threadName)])

        case .threadGoalUpdated:
            guard let threadID = params.string(at: "threadId"),
                  let rawGoal = params.object(at: "goal") else {
                throw malformed(method, "threadId and goal are required")
            }
            let goal = try canonicalGoal(raw: rawGoal, method: method.rawValue)
            guard goal.threadID == ThreadID(threadID) else {
                throw malformed(method, "goal.threadId must match threadId")
            }
            return .state([.threadGoalReplaced(
                id: .init(threadID),
                goal: goal
            )])

        case .threadGoalCleared:
            let value: CodexSchemaThreadGoalClearedNotification = try decodeNotification(method, params)
            return .state([.threadGoalReplaced(id: .init(value.threadID), goal: nil)])

        case .threadEnvironmentConnected, .threadEnvironmentDisconnected:
            let value: CodexSchemaEnvironmentConnectionNotification = try decodeNotification(method, params)
            return .state([.threadEnvironmentConnection(
                id: .init(value.threadID),
                environmentID: value.environmentID,
                connected: method == .threadEnvironmentConnected
            )])

        case .threadSettingsUpdated:
            let value: CodexSchemaThreadSettingsUpdatedNotification = try decodeNotification(method, params)
            guard let settings = params.object(at: "threadSettings") else {
                throw ProtocolStateAdapterError.malformedNotification(
                    method: method.rawValue,
                    message: "threadSettings must be an object"
                )
            }
            return .state([.threadSettingsReplaced(id: .init(value.threadID), settings: settings)])

        case .threadTokenUsageUpdated:
            let value: CodexSchemaThreadTokenUsageUpdatedNotification = try decodeNotification(method, params)
            return .state([.tokenUsageReplaced(
                turn: TurnKey(threadID: .init(value.threadID), turnID: .init(value.turnID)),
                usage: canonicalUsage(value.tokenUsage)
            )])

        case .turnStarted:
            let value: CodexSchemaTurnStartedNotification = try decodeNotification(method, params)
            let converted = try canonicalTurn(
                value.turn,
                threadID: .init(value.threadID),
                rawTurn: params.object(at: "turn")
            )
            return .state([.turnStarted(converted.turn, items: converted.items)])

        case .hookStarted:
            let value: CodexSchemaHookStartedNotification = try decodeNotification(method, params)
            guard let turnID = value.turnID else { return operation(method) }
            return .state([.turnExtensionReplaced(
                turn: TurnKey(threadID: .init(value.threadID), turnID: .init(turnID)),
                key: "hook:\(value.run.id)",
                value: .dictionary(params)
            )])

        case .hookCompleted:
            let value: CodexSchemaHookCompletedNotification = try decodeNotification(method, params)
            guard let turnID = value.turnID else { return operation(method) }
            return .state([.turnExtensionReplaced(
                turn: TurnKey(threadID: .init(value.threadID), turnID: .init(turnID)),
                key: "hook:\(value.run.id)",
                value: .dictionary(params)
            )])

        case .turnCompleted:
            let value: CodexSchemaTurnCompletedNotification = try decodeNotification(method, params)
            let converted = try canonicalTurn(
                value.turn,
                threadID: .init(value.threadID),
                rawTurn: params.object(at: "turn")
            )
            let policy: CanonicalItemCollectionMergePolicy = converted.turn.itemsCoverage == .full
                ? .authoritativeReplacement
                : .mergePreservingExistingOrder
            return .state([.turnCompleted(converted.turn, items: converted.items, itemPolicy: policy)])

        case .turnDiffUpdated:
            let value: CodexSchemaTurnDiffUpdatedNotification = try decodeNotification(method, params)
            return .state([.diffReplaced(
                turn: TurnKey(threadID: .init(value.threadID), turnID: .init(value.turnID)),
                diff: value.diff
            )])

        case .turnPlanUpdated:
            let coordinates = try requiredCoordinates(method: method, params: params)
            guard let rawPlan = params.array(at: "plan") else {
                throw malformed(method, "plan must be an array")
            }
            let explanation: String?
            switch params["explanation"] {
            case nil, .some(.null): explanation = nil
            case .some(.string(let value)): explanation = value
            default: throw malformed(method, "explanation must be a string or null")
            }
            return .state([.planReplaced(
                turn: coordinates.turnKey,
                steps: try rawPlan.map { try canonicalPlanStep(raw: $0, method: method.rawValue) },
                explanation: explanation
            )])

        case .itemStarted:
            let value: CodexSchemaItemStartedNotification = try decodeNotification(method, params)
            return .state([.itemStarted(try canonicalItem(
                value.item,
                threadID: .init(value.threadID),
                turnID: .init(value.turnID),
                authority: .started,
                startedAt: .init(Int64(value.startedAtMs)),
                rawOverride: params.object(at: "item")
            ))])

        case .itemAutoApprovalReviewStarted:
            let value: CodexSchemaItemGuardianApprovalReviewStartedNotification =
                try decodeNotification(method, params)
            return .state([.turnExtensionReplaced(
                turn: TurnKey(threadID: .init(value.threadID), turnID: .init(value.turnID)),
                key: "autoApprovalReview:\(value.reviewID)",
                value: .dictionary(params)
            )])

        case .itemAutoApprovalReviewCompleted:
            let value: CodexSchemaItemGuardianApprovalReviewCompletedNotification =
                try decodeNotification(method, params)
            return .state([.turnExtensionReplaced(
                turn: TurnKey(threadID: .init(value.threadID), turnID: .init(value.turnID)),
                key: "autoApprovalReview:\(value.reviewID)",
                value: .dictionary(params)
            )])

        case .itemCompleted:
            let value: CodexSchemaItemCompletedNotification = try decodeNotification(method, params)
            return .state([.itemCompleted(try canonicalItem(
                value.item,
                threadID: .init(value.threadID),
                turnID: .init(value.turnID),
                authority: .completed,
                completedAt: .init(Int64(value.completedAtMs)),
                rawOverride: params.object(at: "item")
            ))])

        case .itemAgentMessageDelta:
            let value: CodexSchemaAgentMessageDeltaNotification = try decodeNotification(method, params)
            return .state([.itemDelta(
                key: ItemKey(threadID: .init(value.threadID), turnID: .init(value.turnID), itemID: .init(value.itemID)),
                delta: .agentMessage(value.delta)
            )])

        case .itemPlanDelta:
            let value: CodexSchemaPlanDeltaNotification = try decodeNotification(method, params)
            return .state([.itemDelta(
                key: ItemKey(threadID: .init(value.threadID), turnID: .init(value.turnID), itemID: .init(value.itemID)),
                delta: .plan(value.delta)
            )])

        case .commandExecOutputDelta, .processOutputDelta, .processExited:
            return operation(method)

        case .itemCommandExecutionOutputDelta:
            let value: CodexSchemaCommandExecutionOutputDeltaNotification = try decodeNotification(method, params)
            return .state([.itemDelta(
                key: ItemKey(threadID: .init(value.threadID), turnID: .init(value.turnID), itemID: .init(value.itemID)),
                delta: .commandOutput(value.delta)
            )])

        case .itemCommandExecutionTerminalInteraction:
            let value: CodexSchemaTerminalInteractionNotification = try decodeNotification(method, params)
            return .state([.itemDelta(
                key: ItemKey(threadID: .init(value.threadID), turnID: .init(value.turnID), itemID: .init(value.itemID)),
                delta: .terminalInteraction(processID: value.processID, stdin: value.stdin)
            )])

        case .itemFileChangeOutputDelta:
            let value: CodexSchemaFileChangeOutputDeltaNotification = try decodeNotification(method, params)
            return .state([.itemDelta(
                key: ItemKey(threadID: .init(value.threadID), turnID: .init(value.turnID), itemID: .init(value.itemID)),
                delta: .fileChangeOutput(value.delta)
            )])

        case .itemFileChangePatchUpdated:
            let coordinates = try requiredCoordinates(method: method, params: params)
            guard let itemID = params.string(at: "itemId") else {
                throw malformed(method, "itemId must be a string")
            }
            guard let changes = params["changes"], case .array = changes else {
                throw malformed(method, "changes must be an array")
            }
            return .state([.itemLiveFieldReplaced(
                item: ItemKey(
                    threadID: coordinates.threadID,
                    turnID: coordinates.turnID,
                    itemID: .init(itemID)
                ),
                key: "fileChanges",
                value: changes
            )])

        case .serverRequestResolved:
            return ProtocolStateAdaptation(disposition: .requestResolution)

        case .itemMCPToolCallProgress:
            let value: CodexSchemaMCPToolCallProgressNotification = try decodeNotification(method, params)
            return .state([.itemDelta(
                key: ItemKey(threadID: .init(value.threadID), turnID: .init(value.turnID), itemID: .init(value.itemID)),
                delta: .mcpProgress(value.message)
            )])

        case .mcpServerOAuthLoginCompleted:
            return operation(method)

        case .mcpServerStartupStatusUpdated:
            let value: CodexSchemaMCPServerStatusUpdatedNotification =
                try decodeNotification(method, params)
            return .state([.mcpServerStartupStatusUpdated(
                key: CanonicalMCPServerStartupKey(
                    threadID: value.threadID.map { ThreadID($0) },
                    serverName: value.name
                ),
                status: CanonicalMCPServerStartupStatus(
                    status: value.status,
                    error: value.error,
                    failureReason: value.failureReason
                )
            )])

        case .accountUpdated:
            let authMode = try nullableStringField(method, params: params, key: "authMode")
            let planType = try nullableStringField(method, params: params, key: "planType")
            return .state([.accountPatched(CanonicalAccountPatch(
                authMode: authMode,
                planType: planType,
                extensions: params.filterKeys(excluding: ["authMode", "planType"])
            ))])

        case .accountRateLimitsUpdated:
            let value: CodexSchemaAccountRateLimitsUpdatedNotification =
                try decodeNotification(method, params)
            _ = value
            guard let rateLimits = params.object(at: "rateLimits") else {
                throw malformed(method, "rateLimits must be an object")
            }
            return .state([.accountPatched(CanonicalAccountPatch(
                rateLimits: .set(rateLimits),
                rateLimitsAreSparse: true
            ))])

        case .appListUpdated, .remoteControlStatusChanged,
             .externalAgentConfigImportProgress, .externalAgentConfigImportCompleted,
             .fsChanged:
            return operation(method)

        case .itemReasoningSummaryTextDelta:
            let value: CodexSchemaReasoningSummaryTextDeltaNotification = try decodeNotification(method, params)
            return .state([.itemDelta(
                key: ItemKey(threadID: .init(value.threadID), turnID: .init(value.turnID), itemID: .init(value.itemID)),
                delta: .reasoningSummary(index: value.summaryIndex, delta: value.delta)
            )])

        case .itemReasoningSummaryPartAdded:
            let value: CodexSchemaReasoningSummaryPartAddedNotification = try decodeNotification(method, params)
            return .state([.itemLiveFieldReplaced(
                item: ItemKey(threadID: .init(value.threadID), turnID: .init(value.turnID), itemID: .init(value.itemID)),
                key: "reasoningSummaryPart:\(value.summaryIndex)",
                value: .bool(true)
            )])

        case .itemReasoningTextDelta:
            let value: CodexSchemaReasoningTextDeltaNotification = try decodeNotification(method, params)
            return .state([.itemDelta(
                key: ItemKey(threadID: .init(value.threadID), turnID: .init(value.turnID), itemID: .init(value.itemID)),
                delta: .reasoningContent(index: value.contentIndex, delta: value.delta)
            )])

        case .threadCompacted:
            let value: CodexSchemaContextCompactedNotification = try decodeNotification(method, params)
            return .state([.turnExtensionReplaced(
                turn: TurnKey(threadID: .init(value.threadID), turnID: .init(value.turnID)),
                key: "contextCompacted",
                value: .bool(true)
            )])

        case .modelRerouted:
            let value: CodexSchemaModelReroutedNotification = try decodeNotification(method, params)
            return .state([.turnExtensionReplaced(
                turn: TurnKey(threadID: .init(value.threadID), turnID: .init(value.turnID)),
                key: method.rawValue,
                value: .dictionary(params)
            )])

        case .modelVerification:
            let value: CodexSchemaModelVerificationNotification = try decodeNotification(method, params)
            return .state([.turnExtensionReplaced(
                turn: TurnKey(threadID: .init(value.threadID), turnID: .init(value.turnID)),
                key: method.rawValue,
                value: .dictionary(params)
            )])

        case .modelSafetyBufferingUpdated:
            let value: CodexSchemaModelSafetyBufferingUpdatedNotification =
                try decodeNotification(method, params)
            return .state([.turnExtensionReplaced(
                turn: TurnKey(threadID: .init(value.threadID), turnID: .init(value.turnID)),
                key: method.rawValue,
                value: .dictionary(params)
            )])

        case .turnModerationMetadata:
            let value: CodexSchemaTurnModerationMetadataNotification = try decodeNotification(method, params)
            return .state([.moderationMetadataReplaced(
                turn: TurnKey(threadID: .init(value.threadID), turnID: .init(value.turnID)),
                metadata: value.metadata
            )])

        case .warning:
            let value: CodexSchemaWarningNotification = try decodeNotification(method, params)
            return .diagnostic(.init(
                method: method,
                threadID: value.threadID,
                content: .warning(message: value.message)
            ))

        case .guardianWarning:
            let value: CodexSchemaGuardianWarningNotification = try decodeNotification(method, params)
            return .diagnostic(.init(
                method: method,
                threadID: value.threadID,
                content: .guardianWarning(message: value.message)
            ))

        case .deprecationNotice:
            let value: CodexSchemaDeprecationNoticeNotification = try decodeNotification(method, params)
            return .diagnostic(.init(
                method: method,
                content: .deprecationNotice(
                    summary: value.summary,
                    details: value.details
                )
            ))

        case .configWarning:
            let value: CodexSchemaConfigWarningNotification = try decodeNotification(method, params)
            return .diagnostic(.init(
                method: method,
                content: .configWarning(
                    summary: value.summary,
                    details: value.details,
                    path: value.path
                )
            ))

        case .fuzzyFileSearchSessionUpdated, .fuzzyFileSearchSessionCompleted,
             .threadRealtimeStarted, .threadRealtimeItemAdded,
             .threadRealtimeTranscriptDelta, .threadRealtimeTranscriptDone,
             .threadRealtimeOutputAudioDelta, .threadRealtimeSdp,
             .threadRealtimeError, .threadRealtimeClosed,
             .windowsSandboxSetupCompleted, .accountLoginCompleted:
            return operation(method)

        case .windowsWorldWritableWarning:
            let value: CodexSchemaWindowsWorldWritableWarningNotification =
                try decodeNotification(method, params)
            return .diagnostic(.init(
                method: method,
                content: .windowsWorldWritableWarning(
                    extraCount: value.extraCount,
                    failedScan: value.failedScan,
                    samplePaths: value.samplePaths
                )
            ))
        }
    }

    func operation(_ method: CodexAppServerNotificationMethod) -> ProtocolStateAdaptation {
        ProtocolStateAdaptation(disposition: .operation, diagnostic: method.rawValue)
    }

    func malformed(
        _ method: CodexAppServerNotificationMethod,
        _ message: String
    ) -> ProtocolStateAdapterError {
        .malformedNotification(method: method.rawValue, message: message)
    }

    func nullableStringField(
        _ method: CodexAppServerNotificationMethod,
        params: [String: CodexJSONValue],
        key: String
    ) throws -> CanonicalFieldUpdate<String> {
        guard let raw = params[key] else { return .unchanged }
        switch raw {
        case .null: return .clear
        case .string(let value): return .set(value)
        default: throw malformed(method, "\(key) must be a string or null")
        }
    }

    func fieldUpdate<Value: Sendable & Equatable>(
        raw: CodexJSONValue?,
        value: Value?
    ) -> CanonicalFieldUpdate<Value> {
        guard let raw else { return .unchanged }
        if raw == .null { return .clear }
        return value.map(CanonicalFieldUpdate.set) ?? .unchanged
    }

    func decodeNotification<Value: Decodable>(
        _ method: CodexAppServerNotificationMethod,
        _ params: [String: CodexJSONValue],
        as type: Value.Type = Value.self
    ) throws -> Value {
        do {
            let raw = CodexJSONValue.dictionary(params)
            let decodable: CodexJSONValue = switch method {
            case .threadStarted, .turnStarted, .turnCompleted, .itemStarted, .itemCompleted:
                ProtocolFileChangeSanitizer.sanitize(raw)
            default:
                raw
            }
            return try decodable.decode(type)
        } catch {
            throw ProtocolStateAdapterError.malformedNotification(
                method: method.rawValue,
                message: String(describing: error)
            )
        }
    }
}

// MARK: - Generated model conversion

private extension ProtocolStateAdapter {
    struct CanonicalTurnConversion {
        let turn: CanonicalTurn
        let items: [CanonicalItem]
    }

    struct RequiredCoordinates {
        let threadID: ThreadID
        let turnID: TurnID

        var turnKey: TurnKey { TurnKey(threadID: threadID, turnID: turnID) }
    }

    func threadMutations(
        _ value: CodexSchemaThread,
        rawThread: [String: CodexJSONValue]?,
        isLoaded: Bool,
        itemPolicy: CanonicalItemCollectionMergePolicy,
        turnsCoverageOverride: StateCoverage? = nil
    ) throws -> [CanonicalStateMutation] {
        let threadID = ThreadID(value.id)
        // Assign field-by-field to keep this open alpha model legible and avoid a
        // pathological type-checking expression as generated fields are added.
        var metadata = CanonicalThreadMetadata()
        metadata.agentNickname = value.agentNickname
        metadata.agentRole = value.agentRole
        metadata.canAcceptDirectInput = value.canAcceptDirectInput
        metadata.cliVersion = value.cliVersion
        metadata.createdAt = ProtocolSeconds(Int64(value.createdAt))
        metadata.cwd = value.cwd.rawValue
        metadata.ephemeral = value.ephemeral
        metadata.extra = value.extra?.rawValue
        metadata.forkedFromID = value.forkedFromID.map { ThreadID($0) }
        if let rawGitInfo = rawThread?["gitInfo"], rawGitInfo != .null {
            metadata.gitInfo = rawGitInfo
        } else {
            metadata.gitInfo = try value.gitInfo.map { try CodexJSONValue(encoding: $0) }
        }
        metadata.modelProvider = value.modelProvider
        metadata.name = value.name
        metadata.parentThreadID = value.parentThreadID.map { ThreadID($0) }
        metadata.path = value.path
        metadata.preview = value.preview
        metadata.recencyAt = value.recencyAt.map { ProtocolSeconds(Int64($0)) }
        metadata.section = value.section
        metadata.sectionEnteredAt = value.sectionEnteredAt.map { ProtocolSeconds(Int64($0)) }
        metadata.sessionID = value.sessionID
        metadata.source = value.source.rawValue
        metadata.threadSource = value.threadSource?.rawValue
        metadata.updatedAt = ProtocolSeconds(Int64(value.updatedAt))
        metadata.extensions = (rawThread ?? [:]).filterKeys(excluding: Self.threadWireFields)
        let history = CanonicalHistoryState(
            mode: value.historyMode.map { CanonicalHistoryMode(rawValue: $0.rawValue) },
            turnsCoverage: turnsCoverageOverride ?? (value.turns.isEmpty ? .notLoaded : .summary)
        )
        let thread = CanonicalThread(
            id: threadID,
            metadata: metadata,
            status: canonicalStatus(value.status),
            turnOrder: value.turns.map { TurnID($0.id) },
            history: history,
            isLoaded: isLoaded,
            consistency: .authoritative
        )

        var mutations: [CanonicalStateMutation] = [.threadSnapshotReplaced(thread)]
        let rawTurns = rawThread?.array(at: "turns") ?? []
        for (index, turn) in value.turns.enumerated() {
            let converted = try canonicalTurn(
                turn,
                threadID: threadID,
                rawTurn: rawTurns[safe: index]?.objectValue
            )
            mutations.append(.turnSnapshot(
                converted.turn,
                items: converted.items,
                itemPolicy: itemPolicy
            ))
        }
        return mutations
    }

    func canonicalTurn(
        _ value: CodexSchemaTurn,
        threadID: ThreadID,
        rawTurn: [String: CodexJSONValue]? = nil,
        assertedCoverage: StateCoverage? = nil
    ) throws -> CanonicalTurnConversion {
        let key = TurnKey(threadID: threadID, turnID: .init(value.id))
        let status = CanonicalTurnStatus(rawValue: value.status.rawValue)
        let itemAuthority: ItemAuthority = status.isTerminal ? .completed : .started
        let itemsCoverage = assertedCoverage ?? canonicalCoverage(value.itemsView)
        let itemConsistency: StateConsistency = itemsCoverage == .full && status.isTerminal
            ? .authoritative
            : .partial
        let rawItems = rawTurn?.array(at: "items") ?? []
        let items = try value.items.enumerated().map { index, item in
            try canonicalItem(
                item,
                threadID: threadID,
                turnID: key.turnID,
                authority: itemAuthority,
                consistency: itemConsistency,
                rawOverride: rawItems[safe: index]?.objectValue
            )
        }
        var turnExtensions = (rawTurn ?? [:]).filterKeys(excluding: Self.turnWireFields)
        if case .some(.unrecognized(let rawCoverage)) = value.itemsView {
            turnExtensions["itemsView"] = .string(rawCoverage)
        }
        let turn = CanonicalTurn(
            key: key,
            status: status,
            error: value.error.map(canonicalError),
            startedAt: value.startedAt.map { ProtocolSeconds(Int64($0)) },
            completedAt: value.completedAt.map { ProtocolSeconds(Int64($0)) },
            duration: value.durationMs.map { DurationMilliseconds(Int64($0)) },
            itemOrder: items.map { $0.key.itemID },
            itemsCoverage: itemsCoverage,
            itemsConsistency: itemConsistency,
            extensions: turnExtensions
        )
        return CanonicalTurnConversion(turn: turn, items: items)
    }

    func canonicalItem(
        _ value: CodexSchemaThreadItem,
        threadID: ThreadID,
        turnID: TurnID,
        authority: ItemAuthority,
        startedAt: ProtocolMilliseconds? = nil,
        completedAt: ProtocolMilliseconds? = nil,
        consistency: StateConsistency? = nil,
        rawOverride: [String: CodexJSONValue]? = nil
    ) throws -> CanonicalItem {
        guard let rawID = value.id else {
            throw ProtocolStateAdapterError.missingItemIdentity(
                method: authority == .completed ? "item/completed" : "item/started",
                type: value.type
            )
        }
        let payload: [String: CodexJSONValue]
        if let rawOverride {
            payload = rawOverride
        } else if case .dictionary(let object) = value.rawValue {
            payload = object
        } else {
            throw ProtocolStateAdapterError.malformedNotification(
                method: authority == .completed ? "item/completed" : "item/started",
                message: "ThreadItem must be an object"
            )
        }
        let clientID: SubmissionIntentID?
        if case .userMessage(let userMessage) = value {
            clientID = userMessage.clientID.map { SubmissionIntentID($0) }
        } else {
            clientID = nil
        }
        return CanonicalItem(
            key: ItemKey(threadID: threadID, turnID: turnID, itemID: .init(rawID)),
            kind: ThreadItemKind(rawValue: value.type),
            payload: payload,
            authority: authority,
            startedAt: startedAt,
            completedAt: completedAt,
            clientUserMessageID: clientID,
            consistency: consistency ?? (authority == .completed ? .authoritative : .partial)
        )
    }

    func canonicalStatus(_ value: CodexSchemaThreadStatus) -> CanonicalThreadStatus {
        switch value {
        case .notLoaded:
            return .notLoaded
        case .idle:
            return .idle
        case .systemError(let payload):
            return .systemError(payload.rawValue)
        case .active(let payload):
            return .active(flags: Set(payload.activeFlags.map {
                ThreadActiveFlag(rawValue: $0.rawValue)
            }))
        case .unrecognized(let type, let rawValue):
            return .unknown(type: type, raw: rawValue)
        }
    }

    func canonicalCoverage(_ value: CodexSchemaTurnItemsView?) -> StateCoverage {
        guard let value else { return .full }
        switch value.rawValue {
        case "notLoaded": return .notLoaded
        case "summary": return .summary
        case "full": return .full
        default: return .notLoaded
        }
    }

    func pageCoverage(nextCursor: String?) -> StateCoverage {
        nextCursor == nil ? .full : .summary
    }

    func canonicalError(_ value: CodexSchemaTurnError) -> CanonicalTurnError {
        CanonicalTurnError(
            message: value.message,
            additionalDetails: value.additionalDetails,
            codexErrorInfo: value.codexErrorInfo?.rawValue
        )
    }

    func canonicalUsage(_ value: CodexSchemaThreadTokenUsage) -> CanonicalTokenUsage {
        CanonicalTokenUsage(
            last: canonicalUsageBreakdown(value.last),
            total: canonicalUsageBreakdown(value.total),
            modelContextWindow: value.modelContextWindow
        )
    }

    func canonicalUsageBreakdown(
        _ value: CodexSchemaTokenUsageBreakdown
    ) -> CanonicalTokenUsageBreakdown {
        CanonicalTokenUsageBreakdown(
            inputTokens: value.inputTokens,
            cacheWriteInputTokens: value.cacheWriteInputTokens,
            cachedInputTokens: value.cachedInputTokens,
            outputTokens: value.outputTokens,
            reasoningOutputTokens: value.reasoningOutputTokens,
            totalTokens: value.totalTokens
        )
    }

    func canonicalPlanStep(
        raw value: CodexJSONValue,
        method: String
    ) throws -> CanonicalPlanStep {
        guard let object = value.objectValue,
              let step = object.string(at: "step"),
              let status = object.string(at: "status") else {
            throw ProtocolStateAdapterError.malformedNotification(
                method: method,
                message: "each plan step requires string step and status fields"
            )
        }
        return CanonicalPlanStep(step: step, status: .init(rawValue: status))
    }

    func canonicalGoal(
        raw: [String: CodexJSONValue],
        method: String,
        isResponse: Bool = false
    ) throws -> CanonicalThreadGoal {
        guard let threadID = raw.string(at: "threadId"),
              let objective = raw.string(at: "objective"),
              let status = raw.string(at: "status"),
              let tokensUsed = raw.int(at: "tokensUsed"),
              let timeUsedSeconds = raw.int(at: "timeUsedSeconds"),
              let createdAt = raw.int(at: "createdAt"),
              let updatedAt = raw.int(at: "updatedAt") else {
            let message = "goal is missing a required field or has the wrong type"
            if isResponse {
                throw ProtocolStateAdapterError.malformedResponse(method: method, message: message)
            }
            throw ProtocolStateAdapterError.malformedNotification(method: method, message: message)
        }
        let tokenBudget: Int64?
        switch raw["tokenBudget"] {
        case nil, .some(.null): tokenBudget = nil
        case .some(.int(let value)): tokenBudget = Int64(value)
        default:
            let message = "goal tokenBudget must be an integer or null"
            if isResponse {
                throw ProtocolStateAdapterError.malformedResponse(method: method, message: message)
            }
            throw ProtocolStateAdapterError.malformedNotification(method: method, message: message)
        }
        return CanonicalThreadGoal(
            threadID: .init(threadID),
            objective: objective,
            status: CanonicalThreadGoalStatus(rawValue: status),
            tokenBudget: tokenBudget,
            tokensUsed: Int64(tokensUsed),
            timeUsedSeconds: Int64(timeUsedSeconds),
            createdAt: ProtocolSeconds(Int64(createdAt)),
            updatedAt: ProtocolSeconds(Int64(updatedAt)),
            extensions: raw.filterKeys(excluding: Self.goalWireFields)
        )
    }

    func requiredCoordinates(
        method: CodexAppServerNotificationMethod,
        params: [String: CodexJSONValue]
    ) throws -> RequiredCoordinates {
        guard let threadID = params.string(at: "threadId") else {
            throw ProtocolStateAdapterError.malformedNotification(
                method: method.rawValue,
                message: "threadId must be a string"
            )
        }
        guard let turnID = params.string(at: "turnId") else {
            throw ProtocolStateAdapterError.malformedNotification(
                method: method.rawValue,
                message: "turnId must be a string"
            )
        }
        return RequiredCoordinates(threadID: .init(threadID), turnID: .init(turnID))
    }

    static let threadWireFields: Set<String> = [
        "agentNickname", "agentRole", "canAcceptDirectInput", "cliVersion", "createdAt", "cwd", "ephemeral",
        "extra", "forkedFromId", "gitInfo", "historyMode", "id", "modelProvider",
        "name", "parentThreadId", "path", "preview", "recencyAt", "section", "sectionEnteredAt", "sessionId",
        "source", "status", "threadSource", "turns", "updatedAt",
    ]

    static let turnWireFields: Set<String> = [
        "completedAt", "durationMs", "error", "id", "items", "itemsView", "startedAt", "status",
    ]

    static let goalWireFields: Set<String> = [
        "createdAt", "objective", "status", "threadId", "timeUsedSeconds",
        "tokenBudget", "tokensUsed", "updatedAt",
    ]

    // These exclusions are reused for every thread lifecycle response. Keeping
    // them static avoids rebuilding a Set literal on each response while
    // retaining the existing top-level settings filtering semantics.
    static let threadSettingsResponseWireFields: Set<String> = ["thread"]
    static let threadResumeResponseWireFields: Set<String> = [
        "initialTurnsPage", "itemsBackwardsCursor", "thread", "turnsBackwardsCursor",
    ]
}

extension Dictionary where Key == String, Value == CodexJSONValue {
    func string(at key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }

    func int(at key: String) -> Int? {
        guard case .int(let value)? = self[key] else { return nil }
        return value
    }

    func bool(at key: String) -> Bool? {
        guard case .bool(let value)? = self[key] else { return nil }
        return value
    }

    func object(at key: String) -> [String: CodexJSONValue]? {
        self[key]?.objectValue
    }

    func array(at key: String) -> [CodexJSONValue]? {
        guard case .array(let value)? = self[key] else { return nil }
        return value
    }

    func filterKeys(excluding keys: Set<String>) -> Self {
        filter { !keys.contains($0.key) }
    }
}

private extension CodexJSONValue {
    func object(at key: String) -> [String: CodexJSONValue]? {
        objectValue?.object(at: key)
    }

    func array(at key: String) -> [CodexJSONValue]? {
        objectValue?.array(at: key)
    }

    func containsObjectKey(_ key: String) -> Bool {
        objectValue?[key] != nil
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Correlated response adaptation

private extension ProtocolStateAdapter {
    func adaptKnownResponse(
        _ context: ProtocolResponseContext,
        result: CodexJSONValue
    ) throws -> ProtocolStateAdaptation {
        switch context.method {
        case .threadArchive:
            try requireObjectResponse(context, result)
            return .state([.threadLifecycleUpdated(
                id: try requestThreadID(context),
                isArchived: .set(true),
                isLoaded: .unchanged
            )])

        case .threadDelete:
            try requireObjectResponse(context, result)
            return .state([.threadRemoved(try requestThreadID(context))])

        case .threadUnsubscribe:
            let value: CodexSchemaThreadUnsubscribeResponse = try decodeResponse(context, result)
            if case .unrecognized(let status) = value.status {
                throw ProtocolStateAdapterError.malformedResponse(
                    method: context.method.rawValue,
                    message: "unrecognized unsubscribe status \(status)"
                )
            }
            // Unsubscribe removes this connection from the listener set. It
            // does not unload the server thread or change its protocol status.
            return .init(disposition: .ignored)

        case .threadNameSet:
            try requireObjectResponse(context, result)
            guard let name = context.requestParams.string(at: "name") else {
                throw ProtocolStateAdapterError.missingRequestContext(
                    method: context.method.rawValue,
                    field: "name"
                )
            }
            return .state([.threadNameReplaced(id: try requestThreadID(context), name: name)])

        case .threadSettingsUpdate:
            try requireObjectResponse(context, result)
            var patch = context.requestParams
            patch.removeValue(forKey: "threadId")
            guard !patch.isEmpty else { return .state([]) }
            return .state([.threadSettingsPatched(
                id: try requestThreadID(context),
                patch: patch
            )])

        case .threadMemoryModeSet:
            try requireObjectResponse(context, result)
            guard let mode = context.requestParams["mode"] else {
                throw ProtocolStateAdapterError.missingRequestContext(
                    method: context.method.rawValue,
                    field: "mode"
                )
            }
            return .state([.threadSettingsPatched(
                id: try requestThreadID(context),
                patch: ["memoryMode": mode]
            )])

        case .threadStart:
            let value: CodexSchemaThreadStartResponse = try decodeResponse(context, result)
            var mutations = try threadMutations(
                value.thread,
                rawThread: result.object(at: "thread"),
                isLoaded: true,
                itemPolicy: context.itemCollectionPolicy,
                turnsCoverageOverride: .full
            )
            mutations.append(.threadSettingsReplaced(
                id: .init(value.thread.id),
                settings: try responseThreadSettings(
                    result,
                    method: context.method.rawValue,
                    excluding: Self.threadSettingsResponseWireFields
                )
            ))
            return .state(mutations)

        case .threadResume:
            let value: CodexSchemaThreadResumeResponse = try decodeResponse(context, result)
            guard let rawHistoryMode = value.thread.historyMode?.rawValue else {
                throw ProtocolStateAdapterError.malformedResponse(
                    method: context.method.rawValue,
                    message: "thread omitted experimental historyMode"
                )
            }
            let historyMode = CanonicalHistoryMode(rawValue: rawHistoryMode)
            let resumeItemPolicy: CanonicalItemCollectionMergePolicy = historyMode == .legacy
                ? .authoritativeReplacement
                : context.itemCollectionPolicy

            var mutations = try threadMutations(
                value.thread,
                rawThread: result.object(at: "thread"),
                isLoaded: true,
                itemPolicy: resumeItemPolicy
            )
            let threadID = ThreadID(value.thread.id)
            mutations.append(.threadSettingsReplaced(
                id: threadID,
                settings: try responseThreadSettings(
                    result,
                    method: context.method.rawValue,
                    excluding: Self.threadResumeResponseWireFields
                )
            ))
            let initialPage = value.initialTurnsPage
            let isPaginated = historyMode == .paginated
            let history = CanonicalHistoryState(
                mode: historyMode,
                turnsCoverage: historyMode == .legacy
                    ? .full
                    : initialPage.map { pageCoverage(nextCursor: $0.nextCursor) }
                        ?? (value.thread.turns.isEmpty ? .notLoaded : .summary),
                resumeCut: isPaginated
                    ? CanonicalResumeCut(
                        connectionEpoch: context.connectionEpoch,
                        resumeGeneration: context.resumeGeneration,
                        turnsBackwardsCursor: value.turnsBackwardsCursor,
                        itemsBackwardsCursor: value.itemsBackwardsCursor
                    )
                    : nil,
                turnsPage: CanonicalPageCursorState(
                    backwardsCursor: initialPage?.backwardsCursor,
                    nextCursor: initialPage?.nextCursor,
                    isExhausted: historyMode == .legacy
                        || (initialPage != nil && initialPage?.nextCursor == nil)
                )
            )
            mutations.append(.threadHistoryReplaced(id: threadID, history: history))
            var uncertainTurns = Set(value.thread.turns.compactMap { turn in
                turn.status == .inProgress
                    ? TurnKey(threadID: threadID, turnID: TurnID(turn.id))
                    : nil
            })

            if let initialPage {
                let pageRaw = result.object(at: "initialTurnsPage")?.array(at: "data") ?? []
                for (index, turn) in initialPage.data.enumerated() {
                    let rawTurn = pageRaw[safe: index]?.objectValue
                    let converted = try canonicalTurn(turn, threadID: threadID, rawTurn: rawTurn)
                    mutations.append(.turnSnapshot(
                        converted.turn,
                        items: converted.items,
                        itemPolicy: context.itemCollectionPolicy
                    ))
                    if turn.status == .inProgress {
                        uncertainTurns.insert(converted.turn.key)
                    }
                }
            }
            mutations.append(contentsOf: uncertainTurns.sorted().map {
                .turnItemsMarkedUncertain($0)
            })
            return .state(mutations)

        case .threadFork:
            let value: CodexSchemaThreadForkResponse = try decodeResponse(context, result)
            var mutations = try threadMutations(
                value.thread,
                rawThread: result.object(at: "thread"),
                isLoaded: true,
                itemPolicy: context.itemCollectionPolicy,
                turnsCoverageOverride: .full
            )
            mutations.append(.threadSettingsReplaced(
                id: .init(value.thread.id),
                settings: try responseThreadSettings(
                    result,
                    method: context.method.rawValue,
                    excluding: Self.threadSettingsResponseWireFields
                )
            ))
            return .state(mutations)

        case .threadUnarchive:
            let value: CodexSchemaThreadUnarchiveResponse = try decodeResponse(context, result)
            var mutations = try threadMutations(
                value.thread,
                rawThread: result.object(at: "thread"),
                isLoaded: true,
                itemPolicy: context.itemCollectionPolicy
            )
            mutations.append(.threadLifecycleUpdated(
                id: .init(value.thread.id),
                isArchived: .set(false),
                isLoaded: .set(true)
            ))
            return .state(mutations)

        case .threadRollback:
            let value: CodexSchemaThreadRollbackResponse = try decodeResponse(context, result)
            let decoded = try threadMutations(
                value.thread,
                rawThread: result.object(at: "thread"),
                isLoaded: true,
                itemPolicy: .authoritativeReplacement,
                turnsCoverageOverride: .full
            )
            guard case .threadSnapshotReplaced(let thread)? = decoded.first else {
                throw ProtocolStateAdapterError.malformedResponse(
                    method: context.method.rawValue,
                    message: "internal thread snapshot conversion failed"
                )
            }
            var turns: [CanonicalTurn] = []
            var items: [CanonicalItem] = []
            for mutation in decoded.dropFirst() {
                guard case .turnSnapshot(let turn, let turnItems, _) = mutation else { continue }
                turns.append(turn)
                items.append(contentsOf: turnItems)
            }
            return .state([.threadRollbackReplaced(thread: thread, turns: turns, items: items)])

        case .threadMetadataUpdate:
            let value: CodexSchemaThreadMetadataUpdateResponse = try decodeResponse(context, result)
            return .state(try threadMutations(
                value.thread,
                rawThread: result.object(at: "thread"),
                isLoaded: false,
                itemPolicy: .mergePreservingExistingOrder
            ))

        case .threadRead:
            let value: CodexSchemaThreadReadResponse = try decodeResponse(context, result)
            let includeTurns = context.requestParams.bool(at: "includeTurns") == true
            return .state(try threadMutations(
                value.thread,
                rawThread: result.object(at: "thread"),
                isLoaded: false,
                itemPolicy: includeTurns ? context.itemCollectionPolicy : .mergePreservingExistingOrder,
                turnsCoverageOverride: includeTurns ? .full : nil
            ))

        case .threadList:
            let value: CodexSchemaThreadListResponse = try decodeResponse(context, result)
            let rawThreads = result.array(at: "data") ?? []
            let archived = context.requestParams.bool(at: "archived")
            var mutations: [CanonicalStateMutation] = []
            for (index, thread) in value.data.enumerated() {
                mutations.append(contentsOf: try threadMutations(
                    thread,
                    rawThread: rawThreads[safe: index]?.objectValue,
                    isLoaded: false,
                    itemPolicy: .mergePreservingExistingOrder
                ))
                if let archived {
                    mutations.append(.threadLifecycleUpdated(
                        id: .init(thread.id),
                        isArchived: .set(archived),
                        isLoaded: .unchanged
                    ))
                }
            }
            return .state(mutations)

        case .threadSearch:
            let value: CodexSchemaThreadSearchResponse = try decodeResponse(context, result)
            let rawResults = result.array(at: "data") ?? []
            var mutations: [CanonicalStateMutation] = []
            for (index, entry) in value.data.enumerated() {
                mutations.append(contentsOf: try threadMutations(
                    entry.thread,
                    rawThread: rawResults[safe: index]?.object(at: "thread"),
                    isLoaded: false,
                    itemPolicy: .mergePreservingExistingOrder
                ))
            }
            return .state(mutations)

        case .threadLoadedList:
            let value: CodexSchemaThreadLoadedListResponse = try decodeResponse(context, result)
            return .state(value.data.map {
                .threadLifecycleUpdated(
                    id: .init($0),
                    isArchived: .unchanged,
                    isLoaded: .set(true)
                )
            })

        case .threadTurnsList:
            let value: CodexSchemaThreadTurnsListResponse = try decodeResponse(context, result)
            let threadID = try requestThreadID(context)
            let rawTurns = result.array(at: "data") ?? []
            var mutations: [CanonicalStateMutation] = []
            for (index, turn) in value.data.enumerated() {
                let converted = try canonicalTurn(
                    turn,
                    threadID: threadID,
                    rawTurn: rawTurns[safe: index]?.objectValue,
                    assertedCoverage: context.assertedItemsCoverage
                )
                mutations.append(.turnSnapshot(
                    converted.turn,
                    items: converted.items,
                    itemPolicy: context.itemCollectionPolicy
                ))
            }
            mutations.append(.threadHistoryUpdated(
                id: threadID,
                history: CanonicalHistoryState(
                    turnsCoverage: pageCoverage(nextCursor: value.nextCursor),
                    turnsPage: CanonicalPageCursorState(
                        backwardsCursor: value.backwardsCursor,
                        nextCursor: value.nextCursor,
                        isExhausted: value.nextCursor == nil
                    )
                )
            ))
            return .state(mutations)

        case .threadItemsList:
            let value: CodexSchemaThreadItemsListResponse = try decodeResponse(context, result)
            let threadID = try requestThreadID(context)
            let requestedTurnID = context.requestParams.string(at: "turnId").map { TurnID($0) }
            let rawEntries = result.array(at: "data") ?? []
            let requestHasCursor = context.requestParams["cursor"].map { $0 != .null } ?? false
            let isCompleteSinglePage = !requestHasCursor && value.nextCursor == nil
            let effectivePolicy: CanonicalItemCollectionMergePolicy =
                context.itemCollectionPolicy == .authoritativeReplacement && !isCompleteSinglePage
                ? .mergePreservingExistingOrder
                : context.itemCollectionPolicy
            var grouped: [TurnID: [CanonicalItem]] = [:]
            for (index, entry) in value.data.enumerated() {
                let turnID = TurnID(entry.turnID)
                let item = try canonicalItem(
                    entry.item,
                    threadID: threadID,
                    turnID: turnID,
                    authority: .completed,
                    rawOverride: rawEntries[safe: index]?.object(at: "item")
                )
                grouped[turnID, default: []].append(item)
            }
            var mutations: [CanonicalStateMutation] = grouped.keys.sorted().map { turnID in
                let items = grouped[turnID] ?? []
                let coverage: StateCoverage = if requestedTurnID == turnID {
                    context.assertedItemsCoverage
                        ?? (effectivePolicy == .authoritativeReplacement && isCompleteSinglePage
                            ? .full
                            : .summary)
                } else {
                    .notLoaded
                }
                return .turnSnapshot(
                    CanonicalTurn(
                        key: TurnKey(threadID: threadID, turnID: turnID),
                        itemOrder: items.map { $0.key.itemID },
                        itemsCoverage: coverage,
                        itemsConsistency: coverage == .full ? .authoritative : .partial
                    ),
                    items: items,
                    itemPolicy: effectivePolicy
                )
            }
            if let requestedTurnID, grouped[requestedTurnID] == nil {
                let coverage = context.assertedItemsCoverage
                    ?? (effectivePolicy == .authoritativeReplacement && isCompleteSinglePage
                        ? StateCoverage.full
                        : StateCoverage.summary)
                mutations.append(.turnSnapshot(
                    CanonicalTurn(
                        key: TurnKey(threadID: threadID, turnID: requestedTurnID),
                        itemOrder: [],
                        itemsCoverage: coverage,
                        itemsConsistency: coverage == .full ? .authoritative : .partial
                    ),
                    items: [],
                    itemPolicy: effectivePolicy
                ))
            }
            if let requestedTurnID {
                mutations.append(.threadHistoryUpdated(
                    id: threadID,
                    history: CanonicalHistoryState(
                        itemPagesByTurn: [
                            requestedTurnID: CanonicalPageCursorState(
                                backwardsCursor: value.backwardsCursor,
                                nextCursor: value.nextCursor,
                                isExhausted: value.nextCursor == nil
                            )
                        ]
                    )
                ))
            } else {
                mutations.append(.threadHistoryUpdated(
                    id: threadID,
                    history: CanonicalHistoryState(protocolMetadata: [
                        "itemsBackwardsCursor": value.backwardsCursor.map(CodexJSONValue.string) ?? .null,
                        "itemsNextCursor": value.nextCursor.map(CodexJSONValue.string) ?? .null,
                        "itemsPageExhausted": .bool(value.nextCursor == nil),
                    ])
                ))
            }
            return .state(mutations)

        case .turnStart:
            let value: CodexSchemaTurnStartResponse = try decodeResponse(context, result)
            let threadID = try requestThreadID(context)
            let converted = try canonicalTurn(
                value.turn,
                threadID: threadID,
                rawTurn: result.object(at: "turn")
            )
            return .state([.turnStarted(converted.turn, items: converted.items)])

        case .threadGoalSet:
            guard let rawGoal = result.object(at: "goal") else {
                throw ProtocolStateAdapterError.malformedResponse(
                    method: context.method.rawValue,
                    message: "goal must be an object"
                )
            }
            let goal = try canonicalGoal(
                raw: rawGoal,
                method: context.method.rawValue,
                isResponse: true
            )
            if let requestedThreadID = context.requestParams.string(at: "threadId"),
               goal.threadID != ThreadID(requestedThreadID) {
                throw ProtocolStateAdapterError.malformedResponse(
                    method: context.method.rawValue,
                    message: "goal.threadId must match request threadId"
                )
            }
            return .state([.threadGoalReplaced(
                id: goal.threadID,
                goal: goal
            )])

        case .threadGoalGet:
            let threadID = try requestThreadID(context)
            let goal: CanonicalThreadGoal?
            switch result.objectValue?["goal"] {
            case nil, .some(.null):
                goal = nil
            case .some(.dictionary(let rawGoal)):
                goal = try canonicalGoal(
                    raw: rawGoal,
                    method: context.method.rawValue,
                    isResponse: true
                )
                guard goal?.threadID == threadID else {
                    throw ProtocolStateAdapterError.malformedResponse(
                        method: context.method.rawValue,
                        message: "goal.threadId must match request threadId"
                    )
                }
            default:
                throw ProtocolStateAdapterError.malformedResponse(
                    method: context.method.rawValue,
                    message: "goal must be an object or null"
                )
            }
            return .state([.threadGoalReplaced(
                id: threadID,
                goal: goal
            )])

        case .threadGoalClear:
            guard let cleared = result.objectValue?.bool(at: "cleared") else {
                throw ProtocolStateAdapterError.malformedResponse(
                    method: context.method.rawValue,
                    message: "cleared must be a boolean"
                )
            }
            guard cleared else { return ProtocolStateAdaptation(disposition: .ignored) }
            return .state([.threadGoalReplaced(id: try requestThreadID(context), goal: nil)])

        case .accountRateLimitsRead:
            let value: CodexSchemaGetAccountRateLimitsResponse = try decodeResponse(context, result)
            _ = value
            var extensions = result.objectValue ?? [:]
            guard let rateLimits = extensions.removeValue(forKey: "rateLimits")?.objectValue else {
                throw ProtocolStateAdapterError.malformedResponse(
                    method: context.method.rawValue,
                    message: "rateLimits must be an object"
                )
            }
            return .state([.accountPatched(CanonicalAccountPatch(
                rateLimits: .set(rateLimits),
                rateLimitsAreSparse: false,
                extensions: extensions
            ))])

        case .accountRead:
            let value: CodexSchemaGetAccountResponse = try decodeResponse(context, result)
            _ = value
            let rawAccount = result.objectValue?["account"]
            let account = rawAccount?.objectValue
            let hasAccount = rawAccount != nil && rawAccount != .null
            if hasAccount, account?.string(at: "type") == nil {
                throw ProtocolStateAdapterError.malformedResponse(
                    method: context.method.rawValue,
                    message: "account must be an object with a string type"
                )
            }
            return .state([.accountPatched(CanonicalAccountPatch(
                authMode: hasAccount
                    ? fieldUpdate(raw: account?["type"], value: account?.string(at: "type"))
                    : .clear,
                planType: hasAccount
                    ? (account?["planType"] == nil
                        ? .clear
                        : fieldUpdate(raw: account?["planType"], value: account?.string(at: "planType")))
                    : .clear,
                extensions: result.objectValue ?? [:]
            ))])

        case .accountLogout:
            return .state([.accountPatched(CanonicalAccountPatch(
                authMode: .clear,
                planType: .clear,
                rateLimits: .set([:]),
                rateLimitsAreSparse: false,
                extensions: ["account": .null]
            ))])

        default:
            return ProtocolStateAdaptation(disposition: .ignored)
        }
    }

    func decodeResponse<Value: Decodable>(
        _ context: ProtocolResponseContext,
        _ result: CodexJSONValue,
        as type: Value.Type = Value.self
    ) throws -> Value {
        do {
            let decodable: CodexJSONValue = switch context.method {
            case .threadStart, .threadResume, .threadFork, .threadUnarchive,
                 .threadRollback, .threadMetadataUpdate, .threadRead, .threadList,
                 .threadSearch, .threadTurnsList, .threadItemsList, .turnStart:
                ProtocolFileChangeSanitizer.sanitize(result)
            default:
                result
            }
            return try decodable.decode(type)
        } catch {
            throw ProtocolStateAdapterError.malformedResponse(
                method: context.method.rawValue,
                message: String(describing: error)
            )
        }
    }

    func requestThreadID(_ context: ProtocolResponseContext) throws -> ThreadID {
        guard let raw = context.requestParams.string(at: "threadId") else {
            throw ProtocolStateAdapterError.missingRequestContext(
                method: context.method.rawValue,
                field: "threadId"
            )
        }
        return ThreadID(raw)
    }

    func requireObjectResponse(
        _ context: ProtocolResponseContext,
        _ result: CodexJSONValue
    ) throws {
        guard result.objectValue != nil else {
            throw ProtocolStateAdapterError.malformedResponse(
                method: context.method.rawValue,
                message: "result must be an object"
            )
        }
    }

    func responseThreadSettings(
        _ result: CodexJSONValue,
        method: String,
        excluding keys: Set<String>
    ) throws -> [String: CodexJSONValue] {
        guard let object = result.objectValue else {
            throw ProtocolStateAdapterError.malformedResponse(
                method: method,
                message: "result must be an object"
            )
        }
        return object.filterKeys(excluding: keys)
    }
}
