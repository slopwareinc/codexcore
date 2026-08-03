import Foundation

// MARK: - Parsed server requests

/// A validated server-originated request. The request body is typed for every
/// method in the pinned app-server inventory; an unknown method is retained
/// losslessly so the session can return a method-not-found error without
/// corrupting request identity or canonical state.
public struct CodexParsedServerRequest: Sendable, Equatable {
    public let key: CodexServerRequestKey
    public let body: CodexServerRequestBody
    /// Additive fields not known by the pinned schema. They are retained for
    /// diagnostics and future adapters but never enter sanitized snapshots.
    public let unknownFields: [String: CodexJSONValue]

    public init(
        key: CodexServerRequestKey,
        body: CodexServerRequestBody,
        unknownFields: [String: CodexJSONValue] = [:]
    ) {
        self.key = key
        self.body = body
        self.unknownFields = unknownFields
    }

    public var registration: CodexServerRequestRegistration {
        .init(
            key: key,
            method: body.method,
            scope: body.scope,
            approvalCorrelation: body.approvalCorrelation
        )
    }

    /// Validates and canonicalizes a success result for this request method.
    /// JSON-RPC error responses bypass method-specific result validation.
    public func validate(result: CodexJSONValue) throws -> CodexValidatedServerRequestResult {
        try body.validate(result: result)
    }
}

public enum CodexServerRequestBody: Sendable, Equatable {
    case commandApproval(CodexCommandApprovalServerRequest)
    case fileChangeApproval(CodexFileChangeApprovalServerRequest)
    case userInput(CodexUserInputServerRequest)
    case mcpElicitation(CodexMCPElicitationServerRequest)
    case permissionsApproval(CodexPermissionsApprovalServerRequest)
    case dynamicToolCall(CodexDynamicToolServerRequest)
    case tokenRefresh(CodexTokenRefreshServerRequest)
    case attestation(CodexAttestationServerRequest)
    case currentTime(CodexCurrentTimeServerRequest)
    case legacyApplyPatchApproval(CodexLegacyApplyPatchServerRequest)
    case legacyExecCommandApproval(CodexLegacyExecCommandServerRequest)
    case unknown(method: String, params: [String: CodexJSONValue])

    public var method: String {
        switch self {
        case .commandApproval: CodexServerRequestKind.commandApproval.method
        case .fileChangeApproval: CodexServerRequestKind.fileChangeApproval.method
        case .userInput: CodexServerRequestKind.userInput.method
        case .mcpElicitation: CodexServerRequestKind.mcpElicitation.method
        case .permissionsApproval: CodexServerRequestKind.permissionsApproval.method
        case .dynamicToolCall: CodexServerRequestKind.dynamicToolCall.method
        case .tokenRefresh: CodexServerRequestKind.tokenRefresh.method
        case .attestation: CodexServerRequestKind.attestation.method
        case .currentTime: CodexServerRequestKind.currentTime.method
        case .legacyApplyPatchApproval: CodexServerRequestKind.legacyApplyPatchApproval.method
        case .legacyExecCommandApproval: CodexServerRequestKind.legacyExecCommandApproval.method
        case .unknown(let method, _): method
        }
    }

    public var kind: CodexServerRequestKind { .init(method: method) }

    public var scope: CodexServerRequestScope {
        switch self {
        case .commandApproval(let request): request.scope
        case .fileChangeApproval(let request): request.scope
        case .userInput(let request): request.scope
        case .mcpElicitation(let request): request.scope
        case .permissionsApproval(let request): request.scope
        case .dynamicToolCall(let request): request.scope
        case .tokenRefresh, .attestation, .unknown: .init()
        case .currentTime(let request): request.scope
        case .legacyApplyPatchApproval(let request): request.scope
        case .legacyExecCommandApproval(let request): request.scope
        }
    }

    public var approvalCorrelation: CodexApprovalCorrelation? {
        switch self {
        case .commandApproval(let request): request.approvalCorrelation
        case .legacyExecCommandApproval(let request): request.approvalCorrelation
        default: nil
        }
    }

    fileprivate func validate(
        result: CodexJSONValue
    ) throws -> CodexValidatedServerRequestResult {
        switch self {
        case .commandApproval(let request):
            let object = try ServerRequestJSON.object(result, context: method)
            let decisionValue = try ServerRequestJSON.required(object, "decision", context: method)
            guard ServerRequestJSON.isValidCommandDecisionShape(decisionValue),
                  let decision = CodexCommandApprovalDecision(jsonValue: decisionValue) else {
                throw CodexServerRequestValidationError.invalidField(method: method, field: "decision")
            }
            if let available = request.availableDecisions, !available.contains(decision) {
                throw CodexServerRequestValidationError.unavailableDecision(method: method)
            }
            return .commandApproval(decision)

        case .fileChangeApproval:
            let object = try ServerRequestJSON.object(result, context: method)
            let raw = try ServerRequestJSON.string(object, "decision", context: method)
            guard let decision = CodexApprovalDecision(rawValue: raw) else {
                throw CodexServerRequestValidationError.invalidField(method: method, field: "decision")
            }
            return .fileChangeApproval(decision)

        case .userInput(let request):
            let object = try ServerRequestJSON.object(result, context: method)
            let answersObject = try ServerRequestJSON.dictionary(object, "answers", context: method)
            var answers: [String: [String]] = [:]
            let questionIDs = Set(request.questions.map(\.id))
            for (questionID, rawAnswer) in answersObject {
                guard questionIDs.contains(questionID) else {
                    throw CodexServerRequestValidationError.unknownQuestionID(questionID)
                }
                let answerObject = try ServerRequestJSON.object(rawAnswer, context: method)
                answers[questionID] = try ServerRequestJSON.stringArray(
                    answerObject,
                    "answers",
                    context: method
                )
            }
            return .userInput(answers)

        case .mcpElicitation:
            let object = try ServerRequestJSON.object(result, context: method)
            let rawAction = try ServerRequestJSON.string(object, "action", context: method)
            guard let action = CodexMCPElicitationAction(rawValue: rawAction) else {
                throw CodexServerRequestValidationError.invalidField(method: method, field: "action")
            }
            return .mcpElicitation(
                action: action,
                content: object["content"],
                metadata: object["_meta"]
            )

        case .permissionsApproval(let request):
            let object = try ServerRequestJSON.object(result, context: method)
            let permissions = try ServerRequestJSON.dictionary(object, "permissions", context: method)
            try ServerRequestJSON.validatePermissionProfile(
                permissions,
                requested: request.permissions,
                context: method
            )
            let scope: CodexPermissionGrantScope
            if let rawScope = try ServerRequestJSON.optionalString(object, "scope", context: method) {
                guard let parsed = CodexPermissionGrantScope(rawValue: rawScope) else {
                    throw CodexServerRequestValidationError.invalidField(method: method, field: "scope")
                }
                scope = parsed
            } else {
                scope = .turn
            }
            let strict = try ServerRequestJSON.optionalBool(object, "strictAutoReview", context: method)
            return .permissions(
                permissions: .dictionary(permissions),
                scope: scope,
                strictAutoReview: strict
            )

        case .dynamicToolCall:
            let object = try ServerRequestJSON.object(result, context: method)
            let success = try ServerRequestJSON.bool(object, "success", context: method)
            let rawItems = try ServerRequestJSON.array(object, "contentItems", context: method)
            let items = try rawItems.map { try CodexDynamicToolResultContent(jsonValue: $0, method: method) }
            return .dynamicTool(success: success, contentItems: items)

        case .tokenRefresh:
            let object = try ServerRequestJSON.object(result, context: method)
            return .tokenRefresh(
                accessToken: try ServerRequestJSON.string(object, "accessToken", context: method),
                accountID: try ServerRequestJSON.string(object, "chatgptAccountId", context: method),
                planType: try ServerRequestJSON.optionalString(object, "chatgptPlanType", context: method)
            )

        case .attestation:
            let object = try ServerRequestJSON.object(result, context: method)
            return .attestation(
                token: try ServerRequestJSON.string(object, "token", context: method)
            )

        case .currentTime:
            let object = try ServerRequestJSON.object(result, context: method)
            return .currentTime(
                unixSeconds: try ServerRequestJSON.int64(object, "currentTimeAt", context: method)
            )

        case .legacyApplyPatchApproval, .legacyExecCommandApproval:
            let object = try ServerRequestJSON.object(result, context: method)
            let raw = try ServerRequestJSON.required(object, "decision", context: method)
            let decision = try CodexLegacyReviewDecision(jsonValue: raw, method: method)
            if case .legacyApplyPatchApproval = self {
                return .legacyApplyPatchApproval(decision)
            }
            return .legacyExecCommandApproval(decision)

        case .unknown:
            return .unknown(result)
        }
    }
}

public struct CodexCommandApprovalServerRequest: Sendable, Equatable {
    public let scope: CodexServerRequestScope
    public let approvalID: String?
    public let command: String?
    public let cwd: String?
    public let reason: String?
    public let startedAtMilliseconds: Int64
    public let environmentID: String?
    public let availableDecisions: [CodexCommandApprovalDecision]?
    public let commandActions: [CodexCommandAction]?
    public let additionalPermissions: CodexJSONValue?
    public let networkApprovalContext: CodexNetworkApprovalContext?
    public let proposedExecpolicyAmendment: [String]?
    public let proposedNetworkPolicyAmendments: [CodexNetworkPolicyAmendment]?

    public var approvalCorrelation: CodexApprovalCorrelation? {
        guard let threadID = scope.threadID, let approvalID else { return nil }
        return .init(threadID: threadID, approvalID: approvalID)
    }
}

public struct CodexFileChangeApprovalServerRequest: Sendable, Equatable {
    public let scope: CodexServerRequestScope
    public let grantRoot: String?
    public let reason: String?
    public let startedAtMilliseconds: Int64
}

public struct CodexUserInputServerRequest: Sendable, Equatable {
    public let scope: CodexServerRequestScope
    public let questions: [CodexUserInputQuestion]
    public let autoResolutionMilliseconds: UInt64?
}

public enum CodexMCPElicitationMode: Sendable, Equatable {
    case form(requestedSchema: CodexJSONValue)
    case openAIForm(requestedSchema: CodexJSONValue)
    case url(elicitationID: String, url: String)

    /// Unknown upstream modes are represented as an inert URL-shaped mode so
    /// existing presentation code can decline them without attempting to
    /// interpret an unrecognized schema. The original mode remains available
    /// through `unknownMode` for diagnostics.
    public static func unknown(_ mode: String) -> Self {
        .url(elicitationID: "unknown:(mode)", url: "")
    }

    public var unknownMode: String? {
        guard case .url(let elicitationID, let url) = self,
              url.isEmpty,
              elicitationID.hasPrefix("unknown:") else {
            return nil
        }
        return String(elicitationID.dropFirst("unknown:".count))
    }
}

public struct CodexMCPElicitationServerRequest: Sendable, Equatable {
    public let scope: CodexServerRequestScope
    public let serverName: String
    public let message: String
    public let mode: CodexMCPElicitationMode
    public let metadata: CodexJSONValue?
}

public struct CodexPermissionsApprovalServerRequest: Sendable, Equatable {
    public let scope: CodexServerRequestScope
    public let cwd: String
    public let permissions: [String: CodexJSONValue]
    public let reason: String?
    public let startedAtMilliseconds: Int64
    public let environmentID: String?
}

public struct CodexDynamicToolServerRequest: Sendable, Equatable {
    public let scope: CodexServerRequestScope
    public let callID: String
    public let namespace: String?
    public let tool: String
    public let arguments: CodexJSONValue
}

public enum CodexTokenRefreshReason: Sendable, Equatable {
    case unauthorized
    case unrecognized(String)

    public init(rawValue: String) {
        self = rawValue == "unauthorized" ? .unauthorized : .unrecognized(rawValue)
    }
}

public struct CodexTokenRefreshServerRequest: Sendable, Equatable {
    public let reason: CodexTokenRefreshReason
    public let previousAccountID: String?
}

public struct CodexAttestationServerRequest: Sendable, Equatable {
    public init() {}
}

public struct CodexCurrentTimeServerRequest: Sendable, Equatable {
    public let scope: CodexServerRequestScope
}

public struct CodexLegacyApplyPatchServerRequest: Sendable, Equatable {
    public let scope: CodexServerRequestScope
    public let callID: String
    public let fileChanges: [String: CodexLegacyFileChange]
    public let grantRoot: String?
    public let reason: String?
}

public enum CodexLegacyFileChange: Sendable, Equatable {
    case add(content: String)
    case delete(content: String)
    case update(unifiedDiff: String, movePath: String?)

    fileprivate init(jsonValue: CodexJSONValue, method: String) throws {
        let object = try ServerRequestJSON.object(jsonValue, context: method)
        switch try ServerRequestJSON.string(object, "type", context: method) {
        case "add":
            self = .add(content: try ServerRequestJSON.string(
                object,
                "content",
                context: method
            ))
        case "delete":
            self = .delete(content: try ServerRequestJSON.string(
                object,
                "content",
                context: method
            ))
        case "update":
            self = .update(
                unifiedDiff: try ServerRequestJSON.string(
                    object,
                    "unified_diff",
                    context: method
                ),
                movePath: try ServerRequestJSON.optionalString(
                    object,
                    "move_path",
                    context: method
                )
            )
        default:
            throw CodexServerRequestParseError.invalidField(
                method: method,
                field: "fileChanges.type"
            )
        }
    }
}

public struct CodexLegacyExecCommandServerRequest: Sendable, Equatable {
    public let scope: CodexServerRequestScope
    public let callID: String
    public let approvalID: String?
    public let command: [String]
    public let cwd: String
    public let parsedCommand: [CodexLegacyParsedCommand]
    public let reason: String?

    public var approvalCorrelation: CodexApprovalCorrelation? {
        guard let threadID = scope.threadID, let approvalID else { return nil }
        return .init(threadID: threadID, approvalID: approvalID)
    }
}

public enum CodexLegacyParsedCommand: Sendable, Equatable {
    case read(command: String, name: String, path: String)
    case listFiles(command: String, path: String?)
    case search(command: String, path: String?, query: String?)
    case unknown(command: String)

    fileprivate init(jsonValue: CodexJSONValue, method: String) throws {
        let object = try ServerRequestJSON.object(jsonValue, context: method)
        let command = try ServerRequestJSON.string(object, "cmd", context: method)
        switch try ServerRequestJSON.string(object, "type", context: method) {
        case "read":
            self = .read(
                command: command,
                name: try ServerRequestJSON.string(object, "name", context: method),
                path: try ServerRequestJSON.string(object, "path", context: method)
            )
        case "list_files":
            self = .listFiles(
                command: command,
                path: try ServerRequestJSON.optionalString(object, "path", context: method)
            )
        case "search":
            self = .search(
                command: command,
                path: try ServerRequestJSON.optionalString(object, "path", context: method),
                query: try ServerRequestJSON.optionalString(object, "query", context: method)
            )
        case "unknown":
            self = .unknown(command: command)
        default:
            throw CodexServerRequestParseError.invalidField(
                method: method,
                field: "parsedCmd.type"
            )
        }
    }
}

// MARK: - Parser

public enum CodexServerRequestParser {
    public static func parse(
        connectionEpoch: UInt64,
        id: CodexJSONValue,
        method: String,
        params: [String: CodexJSONValue]
    ) throws -> CodexParsedServerRequest {
        let requestID: CodexServerRequestID
        do {
            requestID = try .init(jsonValue: id)
        } catch {
            throw CodexServerRequestParseError.invalidRequestID
        }
        let key = CodexServerRequestKey(
            connectionEpoch: connectionEpoch,
            requestID: requestID
        )

        let body: CodexServerRequestBody
        switch CodexServerRequestKind(method: method) {
        case .commandApproval:
            let threadID = try ServerRequestJSON.string(params, "threadId", context: method)
            let turnID = try ServerRequestJSON.string(params, "turnId", context: method)
            let itemID = try ServerRequestJSON.string(params, "itemId", context: method)
            let availableDecisions: [CodexCommandApprovalDecision]?
            if let raw = try ServerRequestJSON.optionalArray(params, "availableDecisions", context: method) {
                availableDecisions = try raw.map { value in
                    guard ServerRequestJSON.isValidCommandDecisionShape(value),
                          let decision = CodexCommandApprovalDecision(jsonValue: value) else {
                        throw CodexServerRequestParseError.invalidField(
                            method: method,
                            field: "availableDecisions"
                        )
                    }
                    return decision
                }
            } else {
                availableDecisions = nil
            }
            body = .commandApproval(.init(
                scope: .init(threadID: threadID, turnID: turnID, itemID: itemID),
                approvalID: try ServerRequestJSON.optionalString(params, "approvalId", context: method),
                command: try ServerRequestJSON.optionalString(params, "command", context: method),
                cwd: try ServerRequestJSON.optionalString(params, "cwd", context: method),
                reason: try ServerRequestJSON.optionalString(params, "reason", context: method),
                startedAtMilliseconds: try ServerRequestJSON.int64(params, "startedAtMs", context: method),
                environmentID: try ServerRequestJSON.optionalString(params, "environmentId", context: method),
                availableDecisions: availableDecisions,
                commandActions: try ServerRequestJSON.optionalArray(
                    params,
                    "commandActions",
                    context: method
                )?.map {
                    try ServerRequestJSON.commandAction($0, context: method)
                },
                additionalPermissions: ServerRequestJSON.optionalValue(params["additionalPermissions"]),
                networkApprovalContext: try ServerRequestJSON.networkApprovalContext(
                    params["networkApprovalContext"],
                    context: method
                ),
                proposedExecpolicyAmendment: try ServerRequestJSON.optionalStringArray(
                    params,
                    "proposedExecpolicyAmendment",
                    context: method
                ),
                proposedNetworkPolicyAmendments: try ServerRequestJSON.optionalArray(
                    params,
                    "proposedNetworkPolicyAmendments",
                    context: method
                )?.map {
                    try ServerRequestJSON.networkPolicyAmendment($0, context: method)
                }
            ))

        case .fileChangeApproval:
            body = .fileChangeApproval(.init(
                scope: try scope(params, method: method, requiresItem: true),
                grantRoot: try ServerRequestJSON.optionalString(params, "grantRoot", context: method),
                reason: try ServerRequestJSON.optionalString(params, "reason", context: method),
                startedAtMilliseconds: try ServerRequestJSON.int64(params, "startedAtMs", context: method)
            ))

        case .userInput:
            let rawQuestions = try ServerRequestJSON.array(params, "questions", context: method)
            let questions = try rawQuestions.map { raw -> CodexUserInputQuestion in
                let question = try ServerRequestJSON.object(raw, context: method)
                let options: [CodexUserInputOption]
                if let rawOptions = try ServerRequestJSON.optionalArray(question, "options", context: method) {
                    options = try rawOptions.map { rawOption in
                        let option = try ServerRequestJSON.object(rawOption, context: method)
                        return .init(
                            label: try ServerRequestJSON.string(option, "label", context: method),
                            description: try ServerRequestJSON.string(option, "description", context: method)
                        )
                    }
                } else {
                    options = []
                }
                return .init(
                    id: try ServerRequestJSON.string(question, "id", context: method),
                    question: try ServerRequestJSON.string(question, "question", context: method),
                    header: try ServerRequestJSON.string(question, "header", context: method),
                    isSecret: try ServerRequestJSON.bool(
                        question,
                        "isSecret",
                        default: false,
                        context: method
                    ),
                    isOtherAllowed: try ServerRequestJSON.bool(
                        question,
                        "isOther",
                        default: false,
                        context: method
                    ),
                    options: options
                )
            }
            body = .userInput(.init(
                scope: try scope(params, method: method, requiresItem: true),
                questions: questions,
                autoResolutionMilliseconds: try ServerRequestJSON.optionalUInt64(
                    params,
                    "autoResolutionMs",
                    context: method
                )
            ))

        case .mcpElicitation:
            let threadID = try ServerRequestJSON.string(params, "threadId", context: method)
            let turnID = try ServerRequestJSON.optionalString(params, "turnId", context: method)
            let modeName = try ServerRequestJSON.string(params, "mode", context: method)
            let mode: CodexMCPElicitationMode
            switch modeName {
            case "form":
                mode = .form(requestedSchema: try ServerRequestJSON.required(
                    params,
                    "requestedSchema",
                    context: method
                ))
            case "openai/form":
                mode = .openAIForm(requestedSchema: try ServerRequestJSON.required(
                    params,
                    "requestedSchema",
                    context: method
                ))
            case "url":
                mode = .url(
                    elicitationID: try ServerRequestJSON.string(params, "elicitationId", context: method),
                    url: try ServerRequestJSON.string(params, "url", context: method)
                )
            default:
                mode = .unknown(modeName)
            }
            body = .mcpElicitation(.init(
                scope: .init(threadID: threadID, turnID: turnID),
                serverName: try ServerRequestJSON.string(params, "serverName", context: method),
                message: try ServerRequestJSON.string(params, "message", context: method),
                mode: mode,
                metadata: ServerRequestJSON.optionalValue(params["_meta"])
            ))

        case .permissionsApproval:
            let permissions = try ServerRequestJSON.dictionary(params, "permissions", context: method)
            try ServerRequestJSON.validatePermissionProfile(
                permissions,
                requested: nil,
                context: method
            )
            body = .permissionsApproval(.init(
                scope: try scope(params, method: method, requiresItem: true),
                cwd: try ServerRequestJSON.string(params, "cwd", context: method),
                permissions: permissions,
                reason: try ServerRequestJSON.optionalString(params, "reason", context: method),
                startedAtMilliseconds: try ServerRequestJSON.int64(params, "startedAtMs", context: method),
                environmentID: try ServerRequestJSON.optionalString(params, "environmentId", context: method)
            ))

        case .dynamicToolCall:
            body = .dynamicToolCall(.init(
                scope: .init(
                    threadID: try ServerRequestJSON.string(params, "threadId", context: method),
                    turnID: try ServerRequestJSON.string(params, "turnId", context: method)
                ),
                callID: try ServerRequestJSON.string(params, "callId", context: method),
                namespace: try ServerRequestJSON.optionalString(params, "namespace", context: method),
                tool: try ServerRequestJSON.string(params, "tool", context: method),
                arguments: try ServerRequestJSON.required(params, "arguments", context: method)
            ))

        case .tokenRefresh:
            body = .tokenRefresh(.init(
                reason: .init(rawValue: try ServerRequestJSON.string(params, "reason", context: method)),
                previousAccountID: try ServerRequestJSON.optionalString(
                    params,
                    "previousAccountId",
                    context: method
                )
            ))

        case .attestation:
            body = .attestation(.init())

        case .currentTime:
            body = .currentTime(.init(scope: .init(
                threadID: try ServerRequestJSON.string(params, "threadId", context: method)
            )))

        case .legacyApplyPatchApproval:
            let threadID = try ServerRequestJSON.string(params, "conversationId", context: method)
            let callID = try ServerRequestJSON.string(params, "callId", context: method)
            let rawFileChanges = try ServerRequestJSON.dictionary(
                params,
                "fileChanges",
                context: method
            )
            body = .legacyApplyPatchApproval(.init(
                scope: .init(threadID: threadID, itemID: callID),
                callID: callID,
                fileChanges: try rawFileChanges.mapValues {
                    try CodexLegacyFileChange(jsonValue: $0, method: method)
                },
                grantRoot: try ServerRequestJSON.optionalString(params, "grantRoot", context: method),
                reason: try ServerRequestJSON.optionalString(params, "reason", context: method)
            ))

        case .legacyExecCommandApproval:
            let threadID = try ServerRequestJSON.string(params, "conversationId", context: method)
            let callID = try ServerRequestJSON.string(params, "callId", context: method)
            body = .legacyExecCommandApproval(.init(
                scope: .init(threadID: threadID, itemID: callID),
                callID: callID,
                approvalID: try ServerRequestJSON.optionalString(params, "approvalId", context: method),
                command: try ServerRequestJSON.stringArray(params, "command", context: method),
                cwd: try ServerRequestJSON.string(params, "cwd", context: method),
                parsedCommand: try ServerRequestJSON.array(
                    params,
                    "parsedCmd",
                    context: method
                ).map {
                    try CodexLegacyParsedCommand(jsonValue: $0, method: method)
                },
                reason: try ServerRequestJSON.optionalString(params, "reason", context: method)
            ))

        case .unknown:
            body = .unknown(method: method, params: params)
        }

        let unknownFields: [String: CodexJSONValue]
        if case .unknown = body {
            unknownFields = [:] // The unknown body already retains all params.
        } else {
            let knownFields = knownParamFields(for: body.kind)
            unknownFields = params.filter { !knownFields.contains($0.key) }
        }
        return .init(key: key, body: body, unknownFields: unknownFields)
    }

    private static func scope(
        _ params: [String: CodexJSONValue],
        method: String,
        requiresItem: Bool
    ) throws -> CodexServerRequestScope {
        .init(
            threadID: try ServerRequestJSON.string(params, "threadId", context: method),
            turnID: try ServerRequestJSON.string(params, "turnId", context: method),
            itemID: requiresItem
                ? try ServerRequestJSON.string(params, "itemId", context: method)
                : nil
        )
    }

    private static func knownParamFields(for kind: CodexServerRequestKind) -> Set<String> {
        switch kind {
        case .commandApproval:
            [
                "additionalPermissions", "approvalId", "availableDecisions", "command",
                "commandActions", "cwd", "environmentId", "itemId", "networkApprovalContext",
                "proposedExecpolicyAmendment", "proposedNetworkPolicyAmendments", "reason",
                "startedAtMs", "threadId", "turnId"
            ]
        case .fileChangeApproval:
            ["grantRoot", "itemId", "reason", "startedAtMs", "threadId", "turnId"]
        case .userInput:
            ["autoResolutionMs", "itemId", "questions", "threadId", "turnId"]
        case .mcpElicitation:
            [
                "_meta", "elicitationId", "message", "mode", "requestedSchema", "serverName",
                "threadId", "turnId", "url"
            ]
        case .permissionsApproval:
            ["cwd", "environmentId", "itemId", "permissions", "reason", "startedAtMs", "threadId", "turnId"]
        case .dynamicToolCall:
            ["arguments", "callId", "namespace", "threadId", "tool", "turnId"]
        case .tokenRefresh:
            ["previousAccountId", "reason"]
        case .attestation:
            []
        case .currentTime:
            ["threadId"]
        case .legacyApplyPatchApproval:
            ["callId", "conversationId", "fileChanges", "grantRoot", "reason"]
        case .legacyExecCommandApproval:
            ["approvalId", "callId", "command", "conversationId", "cwd", "parsedCmd", "reason"]
        case .unknown:
            []
        }
    }
}

public enum CodexServerRequestProtocolError: Error, Sendable, Equatable {
    case invalidRequestID
    case missingField(method: String, field: String)
    case invalidField(method: String, field: String)
    case unavailableDecision(method: String)
    case unknownQuestionID(String)
    case permissionGrantExceedsRequest(field: String)
}

public typealias CodexServerRequestParseError = CodexServerRequestProtocolError
public typealias CodexServerRequestValidationError = CodexServerRequestProtocolError

// MARK: - Validated results

public enum CodexMCPElicitationAction: String, Sendable, Codable, Equatable {
    case accept
    case decline
    case cancel
}

public enum CodexPermissionGrantScope: String, Sendable, Codable, Equatable {
    case turn
    case session
}

public enum CodexDynamicToolResultContent: Sendable, Equatable {
    case inputText(String)
    case inputImage(String)
    case inputAudio(String)

    fileprivate init(jsonValue: CodexJSONValue, method: String) throws {
        let object = try ServerRequestJSON.object(jsonValue, context: method)
        let type = try ServerRequestJSON.string(object, "type", context: method)
        switch type {
        case "inputText":
            self = .inputText(try ServerRequestJSON.string(object, "text", context: method))
        case "inputImage":
            self = .inputImage(try ServerRequestJSON.string(object, "imageUrl", context: method))
        case "inputAudio":
            self = .inputAudio(try ServerRequestJSON.string(object, "audioUrl", context: method))
        default:
            throw CodexServerRequestValidationError.invalidField(
                method: method,
                field: "contentItems.type"
            )
        }
    }

    public var jsonValue: CodexJSONValue {
        switch self {
        case .inputText(let text):
            return .dictionary(["type": .string("inputText"), "text": .string(text)])
        case .inputImage(let url):
            return .dictionary(["type": .string("inputImage"), "imageUrl": .string(url)])
        case .inputAudio(let url):
            return .dictionary(["type": .string("inputAudio"), "audioUrl": .string(url)])
        }
    }
}

public enum CodexLegacyReviewDecision: Sendable, Equatable {
    case approved
    case approvedForSession
    case approvedExecpolicyAmendment([String])
    case networkPolicyAmendment(CodexNetworkPolicyAmendment)
    case denied(rejection: String)
    case timedOut
    case abort

    fileprivate init(jsonValue: CodexJSONValue, method: String) throws {
        switch jsonValue {
        case .string("approved"): self = .approved
        case .string("approved_for_session"): self = .approvedForSession
        case .string("timed_out"): self = .timedOut
        case .string("abort"): self = .abort
        case .dictionary(let outer):
            if outer.count == 1,
               case .dictionary(let payload)? = outer["denied"],
               case .string(let rejection)? = payload["rejection"] {
                self = .denied(rejection: rejection)
                return
            }
            if outer.count == 1,
               case .dictionary(let payload)? = outer["approved_execpolicy_amendment"],
               let values = try? ServerRequestJSON.stringArray(
                payload,
                "proposed_execpolicy_amendment",
                context: method
               ) {
                self = .approvedExecpolicyAmendment(values)
                return
            }
            if outer.count == 1,
               case .dictionary(let payload)? = outer["network_policy_amendment"],
               case .dictionary(let amendment)? = payload["network_policy_amendment"],
               case .string(let rawAction)? = amendment["action"],
               let action = CodexNetworkPolicyRuleAction(rawValue: rawAction),
               case .string(let host)? = amendment["host"] {
                self = .networkPolicyAmendment(.init(action: action, host: host))
                return
            }
            fallthrough
        default:
            throw CodexServerRequestValidationError.invalidField(method: method, field: "decision")
        }
    }

    public var jsonValue: CodexJSONValue {
        switch self {
        case .approved: .string("approved")
        case .approvedForSession: .string("approved_for_session")
        case .approvedExecpolicyAmendment(let amendment):
            .dictionary([
                "approved_execpolicy_amendment": .dictionary([
                    "proposed_execpolicy_amendment": .array(amendment.map(CodexJSONValue.string))
                ])
            ])
        case .networkPolicyAmendment(let amendment):
            .dictionary([
                "network_policy_amendment": .dictionary([
                    "network_policy_amendment": amendment.jsonValue
                ])
            ])
        case .denied(let rejection):
            .dictionary([
                "denied": .dictionary([
                    "rejection": .string(rejection)
                ])
            ])
        case .timedOut: .string("timed_out")
        case .abort: .string("abort")
        }
    }
}

/// Method-matched success result after schema validation. Secret-bearing
/// values are intentionally one-shot values and are never copied into a
/// `CodexPendingInteractionSnapshot`.
public enum CodexValidatedServerRequestResult: Sendable, Equatable {
    case commandApproval(CodexCommandApprovalDecision)
    case fileChangeApproval(CodexApprovalDecision)
    case userInput([String: [String]])
    case mcpElicitation(
        action: CodexMCPElicitationAction,
        content: CodexJSONValue?,
        metadata: CodexJSONValue?
    )
    case permissions(
        permissions: CodexJSONValue,
        scope: CodexPermissionGrantScope,
        strictAutoReview: Bool?
    )
    case dynamicTool(success: Bool, contentItems: [CodexDynamicToolResultContent])
    case tokenRefresh(accessToken: String, accountID: String, planType: String?)
    case attestation(token: String)
    case currentTime(unixSeconds: Int64)
    case legacyApplyPatchApproval(CodexLegacyReviewDecision)
    case legacyExecCommandApproval(CodexLegacyReviewDecision)
    case unknown(CodexJSONValue)

    public var jsonValue: CodexJSONValue {
        switch self {
        case .commandApproval(let decision):
            return .dictionary(["decision": decision.jsonValue])
        case .fileChangeApproval(let decision):
            return .dictionary(["decision": .string(decision.rawValue)])
        case .userInput(let answers):
            return .dictionary([
                "answers": .dictionary(answers.mapValues { values in
                    .dictionary(["answers": .array(values.map(CodexJSONValue.string))])
                })
            ])
        case .mcpElicitation(let action, let content, let metadata):
            var object: [String: CodexJSONValue] = ["action": .string(action.rawValue)]
            if let content { object["content"] = content }
            if let metadata { object["_meta"] = metadata }
            return .dictionary(object)
        case .permissions(let permissions, let scope, let strictAutoReview):
            var object: [String: CodexJSONValue] = [
                "permissions": permissions,
                "scope": .string(scope.rawValue)
            ]
            if let strictAutoReview { object["strictAutoReview"] = .bool(strictAutoReview) }
            return .dictionary(object)
        case .dynamicTool(let success, let contentItems):
            return .dictionary([
                "success": .bool(success),
                "contentItems": .array(contentItems.map(\.jsonValue))
            ])
        case .tokenRefresh(let accessToken, let accountID, let planType):
            var object: [String: CodexJSONValue] = [
                "accessToken": .string(accessToken),
                "chatgptAccountId": .string(accountID)
            ]
            if let planType { object["chatgptPlanType"] = .string(planType) }
            return .dictionary(object)
        case .attestation(let token):
            return .dictionary(["token": .string(token)])
        case .currentTime(let seconds):
            return .dictionary(["currentTimeAt": .int(Int(seconds))])
        case .legacyApplyPatchApproval(let decision),
             .legacyExecCommandApproval(let decision):
            return .dictionary(["decision": decision.jsonValue])
        case .unknown(let value):
            return value
        }
    }
}

// MARK: - JSON validation

private enum ServerRequestJSON {
    static func isValidCommandDecisionShape(_ value: CodexJSONValue) -> Bool {
        switch value {
        case .string(let decision):
            return ["accept", "acceptForSession", "decline", "cancel"].contains(decision)
        case .dictionary(let outer):
            guard outer.count == 1 else { return false }
            if case .dictionary(let payload)? = outer["acceptWithExecpolicyAmendment"] {
                guard case .array(let values)? = payload["execpolicy_amendment"] else { return false }
                return values.allSatisfy { if case .string = $0 { true } else { false } }
            }
            if case .dictionary(let payload)? = outer["applyNetworkPolicyAmendment"] {
                guard case .dictionary(let amendment)? = payload["network_policy_amendment"],
                      case .string(let action)? = amendment["action"],
                      ["allow", "deny"].contains(action),
                      case .string? = amendment["host"] else { return false }
                return true
            }
            return false
        default:
            return false
        }
    }

    static func required(
        _ object: [String: CodexJSONValue],
        _ field: String,
        context: String
    ) throws -> CodexJSONValue {
        guard let value = object[field] else {
            throw CodexServerRequestProtocolError.missingField(method: context, field: field)
        }
        return value
    }

    static func optionalValue(_ value: CodexJSONValue?) -> CodexJSONValue? {
        guard let value, value != .null else { return nil }
        return value
    }

    static func object(
        _ value: CodexJSONValue,
        context: String
    ) throws -> [String: CodexJSONValue] {
        guard case .dictionary(let object) = value else {
            throw CodexServerRequestProtocolError.invalidField(method: context, field: "result")
        }
        return object
    }

    static func string(
        _ object: [String: CodexJSONValue],
        _ field: String,
        context: String
    ) throws -> String {
        guard case .string(let value) = try required(object, field, context: context) else {
            throw CodexServerRequestProtocolError.invalidField(method: context, field: field)
        }
        return value
    }

    static func optionalString(
        _ object: [String: CodexJSONValue],
        _ field: String,
        context: String
    ) throws -> String? {
        guard let value = object[field], value != .null else { return nil }
        guard case .string(let string) = value else {
            throw CodexServerRequestProtocolError.invalidField(method: context, field: field)
        }
        return string
    }

    static func int64(
        _ object: [String: CodexJSONValue],
        _ field: String,
        context: String
    ) throws -> Int64 {
        guard case .int(let value) = try required(object, field, context: context) else {
            throw CodexServerRequestProtocolError.invalidField(method: context, field: field)
        }
        return Int64(value)
    }

    static func optionalUInt64(
        _ object: [String: CodexJSONValue],
        _ field: String,
        context: String
    ) throws -> UInt64? {
        guard let value = object[field], value != .null else { return nil }
        guard case .int(let integer) = value, integer >= 0 else {
            throw CodexServerRequestProtocolError.invalidField(method: context, field: field)
        }
        return UInt64(integer)
    }

    static func bool(
        _ object: [String: CodexJSONValue],
        _ field: String,
        context: String
    ) throws -> Bool {
        guard case .bool(let value) = try required(object, field, context: context) else {
            throw CodexServerRequestProtocolError.invalidField(method: context, field: field)
        }
        return value
    }

    static func bool(
        _ object: [String: CodexJSONValue],
        _ field: String,
        default defaultValue: Bool,
        context: String
    ) throws -> Bool {
        guard object[field] != nil else { return defaultValue }
        return try bool(object, field, context: context)
    }

    static func optionalBool(
        _ object: [String: CodexJSONValue],
        _ field: String,
        context: String
    ) throws -> Bool? {
        guard let value = object[field], value != .null else { return nil }
        guard case .bool(let bool) = value else {
            throw CodexServerRequestProtocolError.invalidField(method: context, field: field)
        }
        return bool
    }

    static func array(
        _ object: [String: CodexJSONValue],
        _ field: String,
        context: String
    ) throws -> [CodexJSONValue] {
        guard case .array(let value) = try required(object, field, context: context) else {
            throw CodexServerRequestProtocolError.invalidField(method: context, field: field)
        }
        return value
    }

    static func optionalArray(
        _ object: [String: CodexJSONValue],
        _ field: String,
        context: String
    ) throws -> [CodexJSONValue]? {
        guard let value = object[field], value != .null else { return nil }
        guard case .array(let array) = value else {
            throw CodexServerRequestProtocolError.invalidField(method: context, field: field)
        }
        return array
    }

    static func dictionary(
        _ object: [String: CodexJSONValue],
        _ field: String,
        context: String
    ) throws -> [String: CodexJSONValue] {
        guard case .dictionary(let value) = try required(object, field, context: context) else {
            throw CodexServerRequestProtocolError.invalidField(method: context, field: field)
        }
        return value
    }

    static func stringArray(
        _ object: [String: CodexJSONValue],
        _ field: String,
        context: String
    ) throws -> [String] {
        try array(object, field, context: context).map { value in
            guard case .string(let string) = value else {
                throw CodexServerRequestProtocolError.invalidField(method: context, field: field)
            }
            return string
        }
    }

    static func optionalStringArray(
        _ object: [String: CodexJSONValue],
        _ field: String,
        context: String
    ) throws -> [String]? {
        guard let values = try optionalArray(object, field, context: context) else { return nil }
        return try values.map { value in
            guard case .string(let string) = value else {
                throw CodexServerRequestProtocolError.invalidField(method: context, field: field)
            }
            return string
        }
    }

    static func commandAction(
        _ value: CodexJSONValue,
        context: String
    ) throws -> CodexCommandAction {
        guard case .dictionary(let object) = value else {
            throw CodexServerRequestProtocolError.invalidField(
                method: context,
                field: "commandActions"
            )
        }
        let type = try string(object, "type", context: context)
        let command = try string(object, "command", context: context)
        switch type {
        case "read":
            return .init(
                type: type,
                command: command,
                name: try string(object, "name", context: context),
                path: try string(object, "path", context: context)
            )
        case "listFiles":
            return .init(
                type: type,
                command: command,
                path: try optionalString(object, "path", context: context)
            )
        case "search":
            return .init(
                type: type,
                command: command,
                path: try optionalString(object, "path", context: context),
                query: try optionalString(object, "query", context: context)
            )
        case "unknown":
            return .init(type: type, command: command)
        default:
            throw CodexServerRequestProtocolError.invalidField(
                method: context,
                field: "commandActions.type"
            )
        }
    }

    static func networkApprovalContext(
        _ value: CodexJSONValue?,
        context: String
    ) throws -> CodexNetworkApprovalContext? {
        guard let value = optionalValue(value) else { return nil }
        guard case .dictionary(let object) = value else {
            throw CodexServerRequestProtocolError.invalidField(
                method: context,
                field: "networkApprovalContext"
            )
        }
        let networkProtocol = try string(object, "protocol", context: context)
        guard ["http", "https", "socks5Tcp", "socks5Udp"].contains(networkProtocol) else {
            throw CodexServerRequestProtocolError.invalidField(
                method: context,
                field: "networkApprovalContext.protocol"
            )
        }
        return .init(
            host: try string(object, "host", context: context),
            protocol: networkProtocol
        )
    }

    static func networkPolicyAmendment(
        _ value: CodexJSONValue,
        context: String
    ) throws -> CodexNetworkPolicyAmendment {
        guard let amendment = CodexNetworkPolicyAmendment(jsonValue: value) else {
            throw CodexServerRequestProtocolError.invalidField(
                method: context,
                field: "proposedNetworkPolicyAmendments"
            )
        }
        return amendment
    }

    static func validatePermissionProfile(
        _ profile: [String: CodexJSONValue],
        requested: [String: CodexJSONValue]?,
        context: String
    ) throws {
        if let fileSystem = profile["fileSystem"], fileSystem != .null {
            guard case .dictionary(let object) = fileSystem else {
                throw CodexServerRequestProtocolError.invalidField(method: context, field: "permissions.fileSystem")
            }
            try validateFileSystemPermissions(object, context: context)
        }
        if let network = profile["network"], network != .null {
            guard case .dictionary(let object) = network else {
                throw CodexServerRequestProtocolError.invalidField(method: context, field: "permissions.network")
            }
            if let enabled = object["enabled"], enabled != .null, case .bool = enabled {
                // Valid.
            } else if object["enabled"] != nil, object["enabled"] != .null {
                throw CodexServerRequestProtocolError.invalidField(
                    method: context,
                    field: "permissions.network.enabled"
                )
            }
        }

        if let requested,
           !isConservativeSubset(.dictionary(profile), of: .dictionary(requested)) {
            throw CodexServerRequestProtocolError.permissionGrantExceedsRequest(field: "permissions")
        }
    }

    private static func validateFileSystemPermissions(
        _ object: [String: CodexJSONValue],
        context: String
    ) throws {
        for field in ["read", "write"] {
            guard let raw = object[field], raw != .null else { continue }
            guard case .array(let values) = raw,
                  values.allSatisfy({ if case .string = $0 { true } else { false } }) else {
                throw CodexServerRequestProtocolError.invalidField(
                    method: context,
                    field: "permissions.fileSystem.\(field)"
                )
            }
        }

        if let depth = object["globScanMaxDepth"], depth != .null {
            guard case .int(let value) = depth, value >= 1 else {
                throw CodexServerRequestProtocolError.invalidField(
                    method: context,
                    field: "permissions.fileSystem.globScanMaxDepth"
                )
            }
        }

        guard let rawEntries = object["entries"], rawEntries != .null else { return }
        guard case .array(let entries) = rawEntries else {
            throw CodexServerRequestProtocolError.invalidField(
                method: context,
                field: "permissions.fileSystem.entries"
            )
        }
        for entry in entries {
            guard case .dictionary(let object) = entry,
                  case .string(let access)? = object["access"],
                  ["read", "write", "deny"].contains(access),
                  case .dictionary(let path)? = object["path"],
                  case .string(let type)? = path["type"] else {
                throw CodexServerRequestProtocolError.invalidField(
                    method: context,
                    field: "permissions.fileSystem.entries"
                )
            }
            switch type {
            case "path":
                guard case .string? = path["path"] else {
                    throw CodexServerRequestProtocolError.invalidField(method: context, field: "permissions.fileSystem.entries.path")
                }
            case "glob_pattern":
                guard case .string? = path["pattern"] else {
                    throw CodexServerRequestProtocolError.invalidField(method: context, field: "permissions.fileSystem.entries.pattern")
                }
            case "special":
                guard case .dictionary(let special)? = path["value"],
                      case .string(let kind)? = special["kind"],
                      ["root", "minimal", "project_roots", "tmpdir", "slash_tmp", "unknown"].contains(kind) else {
                    throw CodexServerRequestProtocolError.invalidField(method: context, field: "permissions.fileSystem.entries.special")
                }
                if kind == "unknown" {
                    guard case .string? = special["path"] else {
                        throw CodexServerRequestProtocolError.invalidField(
                            method: context,
                            field: "permissions.fileSystem.entries.special.path"
                        )
                    }
                }
                if kind == "project_roots" || kind == "unknown" {
                    if let subpath = special["subpath"], subpath != .null {
                        guard case .string = subpath else {
                            throw CodexServerRequestProtocolError.invalidField(
                                method: context,
                                field: "permissions.fileSystem.entries.special.subpath"
                            )
                        }
                    }
                }
            default:
                throw CodexServerRequestProtocolError.invalidField(
                    method: context,
                    field: "permissions.fileSystem.entries.path.type"
                )
            }
        }
    }

    /// Conservative structural authorization check. Empty/null grants are
    /// always safe; booleans can narrow true to false, numeric limits can only
    /// decrease, arrays can only remove entries, and scalar identities must
    /// match. Future permission fields are therefore fail-closed by default.
    private static func isConservativeSubset(
        _ grant: CodexJSONValue,
        of request: CodexJSONValue?
    ) -> Bool {
        if grant == .null || isEmpty(grant) { return true }
        guard let request else { return false }

        switch (grant, request) {
        case (.dictionary(let grantObject), .dictionary(let requestObject)):
            return grantObject.allSatisfy { field, value in
                isConservativeSubset(value, of: requestObject[field])
            }
        case (.array(let grantValues), .array(let requestValues)):
            return grantValues.allSatisfy { requestValues.contains($0) }
        case (.bool(false), .bool):
            return true
        case (.bool(true), .bool(true)):
            return true
        case (.int(let grantValue), .int(let requestValue)):
            return grantValue <= requestValue
        case (.double(let grantValue), .double(let requestValue)):
            return grantValue <= requestValue
        default:
            return grant == request
        }
    }

    private static func isEmpty(_ value: CodexJSONValue) -> Bool {
        switch value {
        case .dictionary(let object): object.isEmpty
        case .array(let array): array.isEmpty
        default: false
        }
    }
}
