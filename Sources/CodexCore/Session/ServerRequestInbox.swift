import Foundation

/// Revisioned pending-only view used by atomic session-state projections.
public struct CodexServerRequestSnapshotBatch: Sendable, Equatable {
    public let revision: StateRevision
    public let requests: [CodexPendingInteractionSnapshot]

    public init(
        revision: StateRevision,
        requests: [CodexPendingInteractionSnapshot]
    ) {
        self.revision = revision
        self.requests = requests
    }
}

/// Atomic, presentation-safe view of the server requests currently awaiting a
/// client response. The revision belongs to the session state journal, so an
/// empty snapshot after a terminal transition is distinguishable from an old
/// empty snapshot captured before a request arrived.
public struct CodexServerRequestInboxSnapshot: Sendable, Equatable {
    public let revision: StateRevision
    public let requests: [CodexServerRequestInboxEntry]

    public init(
        revision: StateRevision,
        requests: [CodexServerRequestInboxEntry]
    ) {
        self.revision = revision
        self.requests = requests
    }
}

/// Read seam for prompt presenters and adapters. Implementations must capture
/// the snapshot seed and its request-only signal stream in one isolation turn.
public protocol CodexServerRequestInboxObserving: CodexStateObserving {
    func serverRequestInboxSnapshot(
        entities: StateEntityScope
    ) -> CodexServerRequestInboxSnapshot

    func observeServerRequests(
        entities: StateEntityScope
    ) -> StateObservation<CodexServerRequestInboxSnapshot>
}

public extension CodexServerRequestInboxObserving {
    func serverRequestInboxSnapshot() -> CodexServerRequestInboxSnapshot {
        serverRequestInboxSnapshot(entities: .all)
    }

    func observeServerRequests() -> StateObservation<CodexServerRequestInboxSnapshot> {
        observeServerRequests(entities: .all)
    }
}

/// One pending inbox entry. The snapshot provides stable placement and
/// correlation metadata; the body is a deliberately smaller presentation
/// projection with no handler, continuation, or response value.
public struct CodexServerRequestInboxEntry: Sendable, Equatable {
    public let key: CodexServerRequestKey
    public let snapshot: CodexPendingInteractionSnapshot
    public let body: CodexServerRequestInboxBody

    public init(
        snapshot: CodexPendingInteractionSnapshot,
        body: CodexServerRequestInboxBody
    ) {
        self.key = snapshot.key
        self.snapshot = snapshot
        self.body = body
    }
}

/// Typed request content safe to hand to prompt presentation. Request kinds
/// that do not require interactive presentation retain only their typed kind;
/// raw dynamic-tool arguments, unknown params, auth material, and attestation
/// data are never copied into the inbox.
public enum CodexServerRequestInboxBody: Sendable, Equatable {
    case commandApproval(CodexCommandApprovalInboxRequest)
    case fileChangeApproval(CodexFileChangeApprovalInboxRequest)
    case permissionsApproval(CodexPermissionsApprovalInboxRequest)
    case userInput(CodexUserInputInboxRequest)
    case mcpElicitation(CodexMCPElicitationInboxRequest)
    case unsupported(CodexServerRequestKind)

    init(presentationBody body: CodexServerRequestBody) {
        switch body {
        case .commandApproval(let request):
            self = .commandApproval(.init(
                command: request.command,
                cwd: request.cwd,
                reason: request.reason,
                startedAtMilliseconds: request.startedAtMilliseconds,
                environmentID: request.environmentID,
                availableDecisions: request.availableDecisions,
                commandActions: request.commandActions ?? [],
                additionalPermissions: request.additionalPermissions,
                networkApprovalContext: request.networkApprovalContext,
                proposedExecpolicyAmendment: request.proposedExecpolicyAmendment,
                proposedNetworkPolicyAmendments: request.proposedNetworkPolicyAmendments ?? []
            ))

        case .fileChangeApproval(let request):
            self = .fileChangeApproval(.init(
                grantRoot: request.grantRoot,
                reason: request.reason,
                startedAtMilliseconds: request.startedAtMilliseconds
            ))

        case .permissionsApproval(let request):
            self = .permissionsApproval(.init(
                cwd: request.cwd,
                permissions: .dictionary(request.permissions),
                reason: request.reason,
                startedAtMilliseconds: request.startedAtMilliseconds,
                environmentID: request.environmentID
            ))

        case .userInput(let request):
            self = .userInput(.init(
                questions: request.questions,
                autoResolutionMilliseconds: request.autoResolutionMilliseconds
            ))

        case .mcpElicitation(let request):
            self = .mcpElicitation(.init(
                serverName: request.serverName,
                message: request.message,
                mode: request.mode
            ))

        case .dynamicToolCall:
            self = .unsupported(.dynamicToolCall)
        case .tokenRefresh:
            self = .unsupported(.tokenRefresh)
        case .attestation:
            self = .unsupported(.attestation)
        case .currentTime:
            self = .unsupported(.currentTime)
        case .legacyApplyPatchApproval(let request):
            self = .fileChangeApproval(.init(
                callID: request.callID,
                fileChanges: request.fileChanges,
                grantRoot: request.grantRoot,
                reason: request.reason,
                startedAtMilliseconds: nil
            ))
        case .legacyExecCommandApproval(let request):
            self = .commandApproval(.init(
                callID: request.callID,
                command: request.command.joined(separator: " "),
                commandArguments: request.command,
                parsedCommand: request.parsedCommand,
                cwd: request.cwd,
                reason: request.reason,
                startedAtMilliseconds: nil,
                environmentID: nil,
                availableDecisions: nil,
                commandActions: [],
                additionalPermissions: nil,
                networkApprovalContext: nil,
                proposedExecpolicyAmendment: nil,
                proposedNetworkPolicyAmendments: []
            ))
        case .unknown(let method, _):
            self = .unsupported(.unknown(method))
        }
    }
}

public struct CodexCommandApprovalInboxRequest: Sendable, Equatable {
    public let callID: String?
    public let command: String?
    public let commandArguments: [String]?
    public let parsedCommand: [CodexLegacyParsedCommand]?
    public let cwd: String?
    public let reason: String?
    public let startedAtMilliseconds: Int64?
    public let environmentID: String?
    public let availableDecisions: [CodexCommandApprovalDecision]?
    public let commandActions: [CodexCommandAction]
    public let additionalPermissions: CodexJSONValue?
    public let networkApprovalContext: CodexNetworkApprovalContext?
    public let proposedExecpolicyAmendment: [String]?
    public let proposedNetworkPolicyAmendments: [CodexNetworkPolicyAmendment]

    public init(
        callID: String? = nil,
        command: String?,
        commandArguments: [String]? = nil,
        parsedCommand: [CodexLegacyParsedCommand]? = nil,
        cwd: String?,
        reason: String?,
        startedAtMilliseconds: Int64?,
        environmentID: String?,
        availableDecisions: [CodexCommandApprovalDecision]?,
        commandActions: [CodexCommandAction],
        additionalPermissions: CodexJSONValue?,
        networkApprovalContext: CodexNetworkApprovalContext?,
        proposedExecpolicyAmendment: [String]?,
        proposedNetworkPolicyAmendments: [CodexNetworkPolicyAmendment]
    ) {
        self.callID = callID
        self.command = command
        self.commandArguments = commandArguments
        self.parsedCommand = parsedCommand
        self.cwd = cwd
        self.reason = reason
        self.startedAtMilliseconds = startedAtMilliseconds
        self.environmentID = environmentID
        self.availableDecisions = availableDecisions
        self.commandActions = commandActions
        self.additionalPermissions = additionalPermissions
        self.networkApprovalContext = networkApprovalContext
        self.proposedExecpolicyAmendment = proposedExecpolicyAmendment
        self.proposedNetworkPolicyAmendments = proposedNetworkPolicyAmendments
    }
}

public struct CodexFileChangeApprovalInboxRequest: Sendable, Equatable {
    public let callID: String?
    public let fileChanges: [String: CodexLegacyFileChange]?
    public let grantRoot: String?
    public let reason: String?
    public let startedAtMilliseconds: Int64?

    public init(
        callID: String? = nil,
        fileChanges: [String: CodexLegacyFileChange]? = nil,
        grantRoot: String?,
        reason: String?,
        startedAtMilliseconds: Int64?
    ) {
        self.callID = callID
        self.fileChanges = fileChanges
        self.grantRoot = grantRoot
        self.reason = reason
        self.startedAtMilliseconds = startedAtMilliseconds
    }
}

public struct CodexPermissionsApprovalInboxRequest: Sendable, Equatable {
    public let cwd: String
    public let permissions: CodexJSONValue
    public let reason: String?
    public let startedAtMilliseconds: Int64
    public let environmentID: String?

    public init(
        cwd: String,
        permissions: CodexJSONValue,
        reason: String?,
        startedAtMilliseconds: Int64,
        environmentID: String?
    ) {
        self.cwd = cwd
        self.permissions = permissions
        self.reason = reason
        self.startedAtMilliseconds = startedAtMilliseconds
        self.environmentID = environmentID
    }
}

public struct CodexUserInputInboxRequest: Sendable, Equatable {
    public let questions: [CodexUserInputQuestion]
    public let autoResolutionMilliseconds: UInt64?

    public init(
        questions: [CodexUserInputQuestion],
        autoResolutionMilliseconds: UInt64?
    ) {
        self.questions = questions
        self.autoResolutionMilliseconds = autoResolutionMilliseconds
    }
}

public struct CodexMCPElicitationInboxRequest: Sendable, Equatable {
    public let serverName: String
    public let message: String
    public let mode: CodexMCPElicitationMode

    public init(
        serverName: String,
        message: String,
        mode: CodexMCPElicitationMode
    ) {
        self.serverName = serverName
        self.message = message
        self.mode = mode
    }
}
