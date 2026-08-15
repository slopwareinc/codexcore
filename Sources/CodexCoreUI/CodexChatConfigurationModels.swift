import Foundation
import CodexCore

public enum CodexConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(server: String)
    case failed(String)

    public var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected(let server): return "Connected to \(server)"
        case .failed: return "Connection failed"
        }
    }
}

public enum CodexApprovalSelection: String, CaseIterable, Identifiable, Equatable, Sendable {
    case readOnly
    case askForApproval
    case approveForMe
    case fullAccess
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .readOnly: return "Read only"
        case .askForApproval: return "Ask for approval"
        case .approveForMe: return "Approve for me"
        case .fullAccess: return "Full access"
        case .custom: return "Custom (config.toml)"
        }
    }

    public var detail: String {
        switch self {
        case .readOnly:
            return "inspect files without making changes"
        case .askForApproval:
            return "always ask to edit external files and use the internet"
        case .approveForMe:
            return "only ask for potentially unsafe actions"
        case .fullAccess:
            return "unrestricted internet and files"
        case .custom:
            return "uses permissions defined in config"
        }
    }

    public var approvalMode: ApprovalMode {
        switch self {
        case .readOnly:
            return .denyAll
        case .askForApproval, .approveForMe, .fullAccess, .custom:
            return .autoReview
        }
    }

    public var sandbox: Sandbox {
        switch self {
        case .readOnly:
            return .readOnly
        case .askForApproval, .approveForMe, .custom:
            return .workspaceWrite
        case .fullAccess:
            return .fullAccess
        }
    }

    public var permissionProfileID: String? {
        switch self {
        case .readOnly: return ":read-only"
        case .askForApproval, .approveForMe: return ":workspace"
        case .fullAccess: return ":danger-full-access"
        case .custom: return nil
        }
    }

    /// The authoritative app-server permission profile plus only the legacy
    /// overrides needed to distinguish a user-reviewed workspace profile.
    ///
    /// Profile lookup is a fixed switch so prompt submission performs no
    /// catalog scan or app-server request.
    package var permissionProfileWireConfiguration: CodexPermissionProfileWireConfiguration {
        switch self {
        case .readOnly:
            return CodexPermissionProfileWireConfiguration(
                permissions: permissionProfileID,
                approvalPolicy: CodexSchemaAskForApproval(
                    .string("untrusted")
                ),
                approvalsReviewer: CodexSchemaApprovalsReviewer(
                    rawValue: "user"
                )
            )
        case .askForApproval:
            return CodexPermissionProfileWireConfiguration(
                permissions: permissionProfileID,
                approvalPolicy: CodexSchemaAskForApproval(
                    .string("on-request")
                ),
                approvalsReviewer: .user
            )
        case .approveForMe:
            return CodexPermissionProfileWireConfiguration(
                permissions: permissionProfileID,
                approvalPolicy: CodexSchemaAskForApproval(
                    .string("on-request")
                ),
                approvalsReviewer: .autoReview
            )
        case .fullAccess:
            return CodexPermissionProfileWireConfiguration(
                permissions: permissionProfileID,
                approvalPolicy: CodexSchemaAskForApproval(
                    .string("never")
                ),
                approvalsReviewer: CodexSchemaApprovalsReviewer(rawValue: "user")
            )
        case .custom:
            return CodexPermissionProfileWireConfiguration(permissions: nil)
        }
    }

    public static let defaultOptions: [CodexApprovalSelection] = [
        .askForApproval,
        .approveForMe,
        .fullAccess
    ]

    public static func options(
        from profiles: [CodexPermissionProfileSummary],
        requirements: CodexManagedPolicyRequirements? = nil
    ) -> [CodexApprovalSelection] {
        guard !profiles.isEmpty else {
            return requirements?.narrowApprovalOptions(defaultOptions) ?? defaultOptions
        }
        let ids = Set(profiles.lazy.filter(\.allowed).map(\.id))
        var options: [CodexApprovalSelection] = []

        if ids.contains(":workspace") || ids.contains("workspace") || ids.contains("workspace-write") {
            options.append(contentsOf: [.askForApproval, .approveForMe])
        }
        if ids.contains(":danger-full-access") || ids.contains("danger-full-access") {
            options.append(.fullAccess)
        }

        return requirements?.narrowApprovalOptions(options) ?? options
    }

    package static func selection(
        profileID: String?,
        approvalsReviewer: CodexSchemaApprovalsReviewer
    ) -> CodexApprovalSelection {
        switch profileID {
        case ":read-only", "read-only":
            return .readOnly
        case ":workspace", "workspace", "workspace-write":
            switch approvalsReviewer {
            case .user: return .askForApproval
            case .autoReview, .guardianSubagent: return .approveForMe
            case .unrecognized: return .custom
            }
        case ":danger-full-access", "danger-full-access":
            return .fullAccess
        case nil:
            return .custom
        default:
            return .custom
        }
    }
}

/// One managed setting exposed by `configRequirements/read`.
///
/// A missing allow-list means the installation did not constrain that setting.
/// An explicitly empty allow-list is therefore different: it is a managed
/// setting that currently permits no values.
public struct CodexManagedPolicyConstraint: Equatable, Sendable {
    public let allowedValues: [String]?
    public let isAdminLocked: Bool

    public init(
        allowedValues: [String]? = nil,
        isAdminLocked: Bool? = nil
    ) {
        self.allowedValues = allowedValues
        self.isAdminLocked = isAdminLocked ?? (allowedValues != nil)
    }

    public var isRestricted: Bool {
        isAdminLocked
    }

    public func allows(_ value: String) -> Bool {
        guard let allowedValues else { return true }
        return allowedValues.contains(value)
    }
}

public struct CodexManagedDefaultPermissions: Equatable, Sendable {
    public let value: String?
    public let isAdminLocked: Bool

    public init(value: String? = nil, isAdminLocked: Bool? = nil) {
        self.value = value
        self.isAdminLocked = isAdminLocked ?? (value != nil)
    }
}

/// The subset of installation policy that affects CodexCoreUI controls.
///
/// This type intentionally stores wire values as strings. The generated
/// protocol currently represents approval policies as an opaque JSON wrapper,
/// and keeping the UI layer on that generated surface avoids coupling it to
/// the stale hand-written protocol conveniences.
public struct CodexManagedPolicyRequirements: Equatable, Sendable {
    public let allowedApprovalPolicies: CodexManagedPolicyConstraint
    public let allowedSandboxModes: CodexManagedPolicyConstraint
    public let allowedReviewers: CodexManagedPolicyConstraint
    public let allowedWebSearchModes: CodexManagedPolicyConstraint
    public let allowedPermissionProfiles: CodexManagedPolicyConstraint
    public let defaultPermissions: CodexManagedDefaultPermissions

    public init(
        allowedApprovalPolicies: [String]? = nil,
        allowedSandboxModes: [String]? = nil,
        allowedReviewers: [String]? = nil,
        allowedWebSearchModes: [String]? = nil,
        allowedPermissionProfiles: [String]? = nil,
        defaultPermissions: String? = nil,
        approvalPoliciesAdminLocked: Bool? = nil,
        sandboxModesAdminLocked: Bool? = nil,
        reviewersAdminLocked: Bool? = nil,
        webSearchModesAdminLocked: Bool? = nil,
        permissionProfilesAdminLocked: Bool? = nil,
        defaultPermissionsAdminLocked: Bool? = nil
    ) {
        self.allowedApprovalPolicies = CodexManagedPolicyConstraint(
            allowedValues: allowedApprovalPolicies,
            isAdminLocked: approvalPoliciesAdminLocked
        )
        self.allowedSandboxModes = CodexManagedPolicyConstraint(
            allowedValues: allowedSandboxModes,
            isAdminLocked: sandboxModesAdminLocked
        )
        self.allowedReviewers = CodexManagedPolicyConstraint(
            allowedValues: allowedReviewers,
            isAdminLocked: reviewersAdminLocked
        )
        self.allowedWebSearchModes = CodexManagedPolicyConstraint(
            allowedValues: allowedWebSearchModes,
            isAdminLocked: webSearchModesAdminLocked
        )
        self.allowedPermissionProfiles = CodexManagedPolicyConstraint(
            allowedValues: allowedPermissionProfiles,
            isAdminLocked: permissionProfilesAdminLocked
        )
        self.defaultPermissions = CodexManagedDefaultPermissions(
            value: defaultPermissions,
            isAdminLocked: defaultPermissionsAdminLocked
        )
    }

    public init(requirements: CodexSchemaConfigRequirements?) {
        self.init(
            allowedApprovalPolicies: requirements?.allowedApprovalPolicies?.compactMap(Self.string),
            allowedSandboxModes: requirements?.allowedSandboxModes?.map(\.rawValue),
            allowedReviewers: requirements?.allowedApprovalsReviewers?.map(\.rawValue),
            allowedWebSearchModes: requirements?.allowedWebSearchModes?.map(\.rawValue),
            allowedPermissionProfiles: requirements.map {
                Self.allowedProfileIDs(from: $0)
            } ?? nil,
            defaultPermissions: requirements?.defaultPermissions
        )
    }

    public init(_ requirements: CodexSchemaConfigRequirements) {
        self.init(requirements: requirements)
    }

    public var isManaged: Bool {
        allowedApprovalPolicies.isAdminLocked
            || allowedSandboxModes.isAdminLocked
            || allowedReviewers.isAdminLocked
            || allowedWebSearchModes.isAdminLocked
            || allowedPermissionProfiles.isAdminLocked
            || defaultPermissions.isAdminLocked
    }

    public var isApprovalPolicyAdminLocked: Bool {
        allowedApprovalPolicies.isAdminLocked
    }

    public var isSandboxModeAdminLocked: Bool {
        allowedSandboxModes.isAdminLocked
    }

    public var isReviewerAdminLocked: Bool {
        allowedReviewers.isAdminLocked
    }

    public var isWebSearchModeAdminLocked: Bool {
        allowedWebSearchModes.isAdminLocked
    }

    public var noticeTitle: String {
        "Managed by your organization"
    }

    public var noticeDetail: String {
        let categories = restrictedCategories
        guard !categories.isEmpty else {
            return "Some settings are restricted by this installation."
        }
        return "Restricted by this installation: "
            + categories.joined(separator: ", ")
            + "."
    }

    public var restrictedCategories: [String] {
        var categories: [String] = []
        if allowedApprovalPolicies.isAdminLocked { categories.append("approval policies") }
        if allowedSandboxModes.isAdminLocked { categories.append("sandbox modes") }
        if allowedReviewers.isAdminLocked { categories.append("approval reviewers") }
        if allowedWebSearchModes.isAdminLocked { categories.append("web search") }
        if allowedPermissionProfiles.isAdminLocked { categories.append("permission profiles") }
        if defaultPermissions.isAdminLocked { categories.append("default permissions") }
        return categories
    }

    public func allows(_ selection: CodexApprovalSelection) -> Bool {
        let wire = selection.permissionProfileWireConfiguration
        guard allowsProfile(selection.permissionProfileID),
              allows(wire.approvalPolicy),
              allows(wire.approvalsReviewer),
              allowedSandboxModes.allows(selection.sandbox.threadMode.rawValue)
        else {
            return false
        }

        // Custom config has no explicit wire values to intersect. Once any
        // permission constraint is managed, allowing it would provide an
        // uncheckable escape hatch around the installation policy.
        if selection == .custom {
            return !hasPermissionRestriction
        }
        return true
    }

    public func narrowApprovalOptions(
        _ options: [CodexApprovalSelection]
    ) -> [CodexApprovalSelection] {
        options.filter(allows)
    }

    public func approvalOptions(
        from profiles: [CodexPermissionProfileSummary]
    ) -> [CodexApprovalSelection] {
        CodexApprovalSelection.options(from: profiles, requirements: self)
    }

    public func narrowSandboxModes(
        _ modes: [CodexSchemaSandboxMode]
    ) -> [CodexSchemaSandboxMode] {
        modes.filter { allowedSandboxModes.allows($0.rawValue) }
    }

    public func narrowReviewers(
        _ reviewers: [CodexSchemaApprovalsReviewer]
    ) -> [CodexSchemaApprovalsReviewer] {
        reviewers.filter { allowedReviewers.allows($0.rawValue) }
    }

    public func narrowWebSearchModes(
        _ modes: [CodexSchemaWebSearchMode]
    ) -> [CodexSchemaWebSearchMode] {
        modes.filter { allowedWebSearchModes.allows($0.rawValue) }
    }

    public func defaultApprovalSelection(
        in options: [CodexApprovalSelection]
    ) -> CodexApprovalSelection? {
        guard let value = defaultPermissions.value else { return nil }
        return options.first {
            $0.permissionProfileID == value || $0.rawValue == value
        }
    }

    private var hasPermissionRestriction: Bool {
        allowedApprovalPolicies.isAdminLocked
            || allowedSandboxModes.isAdminLocked
            || allowedReviewers.isAdminLocked
            || allowedPermissionProfiles.isAdminLocked
            || defaultPermissions.isAdminLocked
    }

    private func allowsProfile(_ profileID: String?) -> Bool {
        guard let profileID else {
            return !allowedPermissionProfiles.isAdminLocked
        }
        return allowedPermissionProfiles.allows(profileID)
    }

    private func allows(_ value: CodexSchemaAskForApproval?) -> Bool {
        guard let value, let string = Self.string(value) else {
            return !allowedApprovalPolicies.isAdminLocked
        }
        return allowedApprovalPolicies.allows(string)
    }

    private func allows(_ value: CodexSchemaApprovalsReviewer?) -> Bool {
        guard let value else { return !allowedReviewers.isAdminLocked }
        if value == .autoReview,
           allowedReviewers.allowedValues?.contains("guardian_subagent") == true {
            return true
        }
        return allowedReviewers.allows(value.rawValue)
    }

    private static func string(_ value: CodexSchemaAskForApproval) -> String? {
        CodexJSONCoercion.flatString(from: value.rawValue)
    }

    private static func allowedProfileIDs(
        from requirements: CodexSchemaConfigRequirements
    ) -> [String]? {
        guard let profiles = requirements.allowedPermissionProfiles else { return nil }
        return profiles.compactMap { $0.value ? $0.key : nil }
    }
}

/// Applies one composer permission selection to every request path that can
/// establish or change an app-server permission profile.
///
/// Applying the configuration deliberately clears handwritten sandbox values.
/// The selected profile (or config.toml for Custom) remains authoritative.
package struct CodexPermissionProfileWireConfiguration: Equatable, Sendable {
    package let permissions: String?
    package let approvalPolicy: CodexSchemaAskForApproval?
    package let approvalsReviewer: CodexSchemaApprovalsReviewer?

    package init(
        permissions: String?,
        approvalPolicy: CodexSchemaAskForApproval? = nil,
        approvalsReviewer: CodexSchemaApprovalsReviewer? = nil
    ) {
        self.permissions = permissions
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
    }

    package func apply(to parameters: inout CodexSchemaThreadStartParams) {
        parameters.permissions = permissions
        parameters.approvalPolicy = approvalPolicy
        parameters.approvalsReviewer = approvalsReviewer
        parameters.sandbox = nil
    }

    package func apply(to parameters: inout CodexSchemaThreadForkParams) {
        parameters.permissions = permissions
        parameters.approvalPolicy = approvalPolicy
        parameters.approvalsReviewer = approvalsReviewer
        parameters.sandbox = nil
    }

    package func apply(to parameters: inout CodexSchemaTurnStartParams) {
        parameters.permissions = permissions
        parameters.approvalPolicy = approvalPolicy
        parameters.approvalsReviewer = approvalsReviewer
        parameters.sandboxPolicy = nil
    }
}

public struct CodexPermissionProfileSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var detail: String?
    public var allowed: Bool
    public var raw: CodexJSONValue

    public init(
        id: String,
        displayName: String,
        detail: String? = nil,
        allowed: Bool = true,
        raw: CodexJSONValue = .dictionary([:])
    ) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.allowed = allowed
        self.raw = raw
    }

    public static func profiles(from value: CodexJSONValue) -> [CodexPermissionProfileSummary] {
        let rawProfiles: [CodexJSONValue]
        switch value {
        case .dictionary(let object):
            if case .array(let data)? = object["data"] {
                rawProfiles = data
            } else if case .array(let profiles)? = object["profiles"] {
                rawProfiles = profiles
            } else {
                rawProfiles = []
            }
        case .array(let values):
            rawProfiles = values
        case .string, .int, .double, .bool, .null:
            rawProfiles = []
        }

        return rawProfiles.compactMap(profile(from:))
    }

    private static func profile(from value: CodexJSONValue) -> CodexPermissionProfileSummary? {
        switch value {
        case .string(let id):
            return CodexPermissionProfileSummary(id: id, displayName: displayName(for: id), raw: value)
        case .dictionary(let object):
            guard let id = string(in: object, keys: ["id", "profileId", "name"]) else { return nil }
            let displayName = string(in: object, keys: ["displayName", "title", "name"]) ?? displayName(for: id)
            let detail = string(in: object, keys: ["description", "detail", "subtitle"])
            let allowed = bool(in: object, key: "allowed") ?? true
            return CodexPermissionProfileSummary(
                id: id,
                displayName: displayName,
                detail: detail,
                allowed: allowed,
                raw: value
            )
        case .array, .int, .double, .bool, .null:
            return nil
        }
    }

    private static func displayName(for id: String) -> String {
        switch id {
        case ":read-only", "read-only": return "Read only"
        case ":workspace", "workspace", "workspace-write": return "Workspace"
        case ":danger-full-access", "danger-full-access": return "Full access"
        default:
            let trimmed = id.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return trimmed
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let string):
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case .int(let int): return String(int)
            case .double(let double): return String(double)
            case .bool(let bool): return String(bool)
            case .array, .dictionary, .null:
                continue
            }
        }
        return nil
    }

    private static func bool(in object: [String: CodexJSONValue], key: String) -> Bool? {
        guard case .bool(let value)? = object[key] else { return nil }
        return value
    }
}

public struct CodexModelServiceTier: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let detail: String

    public init(id: String, displayName: String, detail: String) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
    }
}

public enum CodexServiceTierSelection: Identifiable, Equatable, Hashable, Sendable {
    case standard
    case tier(CodexModelServiceTier)

    public var id: String {
        switch self {
        case .standard: "standard"
        case .tier(let tier): tier.id
        }
    }

    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .tier(let tier): tier.displayName
        }
    }

    public var detail: String {
        switch self {
        case .standard: "Default speed"
        case .tier(let tier): tier.detail
        }
    }

    /// `nil` is the app-server's explicit Standard/default tier behavior.
    public var protocolValue: String? {
        switch self {
        case .standard: nil
        case .tier(let tier): tier.id
        }
    }

    func reconciled(for model: CodexModelSelection) -> Self {
        switch self {
        case .standard:
            .standard
        case .tier(let tier):
            model.serviceTier(id: tier.id)
                .map(Self.tier)
                ?? model.defaultServiceTierSelection
        }
    }
}

package struct CodexResolvedModelPreference: Equatable, Sendable {
    package var model: CodexModelSelection
    package var serviceTier: CodexServiceTierSelection
    package var isServiceTierExplicit: Bool

    package init(
        model: CodexModelSelection,
        serviceTier: CodexServiceTierSelection,
        isServiceTierExplicit: Bool
    ) {
        self.model = model
        self.serviceTier = serviceTier
        self.isServiceTierExplicit = isServiceTierExplicit
    }
}

public struct CodexModelSelection: Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var modelIdentifier: String?
    public var specialty: String?
    public var detail: String?
    public var isDefault: Bool
    public var defaultReasoning: CodexReasoningSelection?
    public var supportedReasoning: [CodexReasoningSelection]
    public let serviceTiers: [CodexModelServiceTier]
    public let defaultServiceTierID: String?
    public var isFastModel: Bool
    private let serviceTierByID: [String: CodexModelServiceTier]

    public init(
        id: String,
        displayName: String,
        modelIdentifier: String? = nil,
        specialty: String? = nil,
        detail: String? = nil,
        isDefault: Bool = false,
        defaultReasoning: CodexReasoningSelection? = nil,
        supportedReasoning: [CodexReasoningSelection] = CodexReasoningSelection.defaultOptions,
        serviceTiers: [CodexModelServiceTier] = [],
        defaultServiceTierID: String? = nil,
        isFastModel: Bool = false
    ) {
        var normalizedTiers = serviceTiers
        var tierByID: [String: CodexModelServiceTier] = [:]
        normalizedTiers = normalizedTiers.filter { tier in
            let key = tier.id.lowercased()
            guard tierByID[key] == nil else { return false }
            tierByID[key] = tier
            return true
        }
        if tierByID["fast"] == nil,
           let fast = normalizedTiers.first(where: Self.isFastTier) {
            tierByID["fast"] = fast
        }
        let normalizedDefaultTierID = defaultServiceTierID.flatMap {
            tierByID[$0.lowercased()]?.id
        }

        self.id = id
        self.displayName = displayName
        self.modelIdentifier = modelIdentifier
        self.specialty = specialty
        self.detail = detail
        self.isDefault = isDefault
        self.defaultReasoning = defaultReasoning
        self.supportedReasoning = supportedReasoning
        self.serviceTiers = normalizedTiers
        self.defaultServiceTierID = normalizedDefaultTierID
        self.isFastModel = isFastModel
        self.serviceTierByID = tierByID
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.modelIdentifier == rhs.modelIdentifier
            && lhs.specialty == rhs.specialty
            && lhs.detail == rhs.detail
            && lhs.isDefault == rhs.isDefault
            && lhs.defaultReasoning == rhs.defaultReasoning
            && lhs.supportedReasoning == rhs.supportedReasoning
            && lhs.serviceTiers == rhs.serviceTiers
            && lhs.defaultServiceTierID == rhs.defaultServiceTierID
            && lhs.isFastModel == rhs.isFastModel
    }

    func serviceTier(id: String) -> CodexModelServiceTier? {
        serviceTierByID[id.lowercased()]
    }

    func serviceTierSelection(id: String?) -> CodexServiceTierSelection {
        guard let id,
              id.caseInsensitiveCompare("default") != .orderedSame,
              id.caseInsensitiveCompare("standard") != .orderedSame
        else { return .standard }
        return serviceTier(id: id).map(CodexServiceTierSelection.tier) ?? .standard
    }

    var defaultServiceTierSelection: CodexServiceTierSelection {
        defaultServiceTierID
            .flatMap(serviceTier(id:))
            .map(CodexServiceTierSelection.tier)
            ?? .standard
    }

    public static let appServerDefault = CodexModelSelection(
        id: "app-server-default",
        displayName: "Default",
        modelIdentifier: nil,
        detail: "default app-server model",
        isDefault: true,
        defaultReasoning: .medium
    )

    public static let defaultOptions: [CodexModelSelection] = [.appServerDefault]

    public static func preferredDefault(from options: [CodexModelSelection]) -> CodexModelSelection {
        options.first(where: \.isDefault) ?? options.first ?? .appServerDefault
    }

    public static func options(from response: CodexSchemaModelListResponse) -> [CodexModelSelection] {
        response.data.map { model in
            let supportedReasoning = model.supportedReasoningEfforts.compactMap {
                reasoningSelection(
                    from: CodexJSONCoercion.flatString(from: $0.reasoningEffort.rawValue)
                )
            }
            let serviceTiers = (model.serviceTiers ?? []).map {
                CodexModelServiceTier(
                    id: $0.id,
                    displayName: $0.name,
                    detail: $0.description
                )
            }
            return CodexModelSelection(
                id: model.id,
                displayName: model.displayName,
                modelIdentifier: model.model,
                specialty: model.modelSpecialty,
                detail: model.description,
                isDefault: model.isDefault,
                defaultReasoning: reasoningSelection(
                    from: CodexJSONCoercion.flatString(from: model.defaultReasoningEffort.rawValue)
                ),
                supportedReasoning: supportedReasoning.isEmpty
                    ? CodexReasoningSelection.defaultOptions
                    : supportedReasoning,
                serviceTiers: serviceTiers,
                defaultServiceTierID: model.defaultServiceTier,
                isFastModel: model.additionalSpeedTiers?.isEmpty == false
            )
        }
    }

    private static func reasoningSelection(from rawValue: String?) -> CodexReasoningSelection? {
        rawValue.flatMap(CodexReasoningSelection.init(appServerValue:))
    }

    private static func isFastTier(_ tier: CodexModelServiceTier) -> Bool {
        tier.id.caseInsensitiveCompare("priority") == .orderedSame
            || tier.id.caseInsensitiveCompare("fast") == .orderedSame
            || tier.displayName.caseInsensitiveCompare("fast") == .orderedSame
    }
}

public enum CodexReasoningSelection: String, CaseIterable, Identifiable, Equatable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case extraHigh
    case maximum
    case ultra

    public var id: String { rawValue }

    public static let defaultOptions: [CodexReasoningSelection] = [.low, .medium, .high, .extraHigh]

    public init?(appServerValue: String) {
        switch appServerValue {
        case ReasoningEffort.none.rawValue:
            self = .none
        case ReasoningEffort.minimal.rawValue:
            self = .minimal
        case ReasoningEffort.low.rawValue:
            self = .low
        case ReasoningEffort.medium.rawValue:
            self = .medium
        case ReasoningEffort.high.rawValue:
            self = .high
        case ReasoningEffort.xhigh.rawValue:
            self = .extraHigh
        case ReasoningEffort.max.rawValue:
            self = .maximum
        case ReasoningEffort.ultra.rawValue:
            self = .ultra
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .extraHigh: return "Extra High"
        case .maximum: return "Maximum"
        case .ultra: return "Ultra"
        }
    }

    public var effort: ReasoningEffort {
        switch self {
        case .none: return .none
        case .minimal: return .minimal
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .extraHigh: return .xhigh
        case .maximum: return .max
        case .ultra: return .ultra
        }
    }
}

public struct CodexCollaborationModeOption: Identifiable, Equatable, Sendable {
    public var id: String { mode }
    public var name: String
    public var mode: String
    public var modelIdentifier: String?
    public var reasoning: CodexReasoningSelection?
    public var raw: CodexJSONValue

    public init(
        name: String,
        mode: String,
        modelIdentifier: String? = nil,
        reasoning: CodexReasoningSelection? = nil,
        raw: CodexJSONValue = .dictionary([:])
    ) {
        self.name = name
        self.mode = mode
        self.modelIdentifier = modelIdentifier
        self.reasoning = reasoning
        self.raw = raw
    }

    public static let defaultMode = CodexCollaborationModeOption(name: "Default", mode: "default")
    public static let planMode = CodexCollaborationModeOption(name: "Plan", mode: "plan", reasoning: .medium)
    public static let defaultOptions: [CodexCollaborationModeOption] = [.planMode, .defaultMode]

    public var isPlanMode: Bool {
        mode.caseInsensitiveCompare("plan") == .orderedSame ||
            name.localizedCaseInsensitiveContains("plan")
    }

    public static func options(from value: CodexJSONValue) -> [CodexCollaborationModeOption] {
        let rawModes: [CodexJSONValue]
        switch value {
        case .dictionary(let object):
            if case .array(let data)? = object["data"] {
                rawModes = data
            } else if case .array(let modes)? = object["modes"] {
                rawModes = modes
            } else {
                rawModes = []
            }
        case .array(let values):
            rawModes = values
        case .string, .int, .double, .bool, .null:
            rawModes = []
        }

        let parsed = rawModes.compactMap(option(from:))
        return parsed.isEmpty ? defaultOptions : parsed
    }

    private static func option(from value: CodexJSONValue) -> CodexCollaborationModeOption? {
        switch value {
        case .string(let mode):
            return CodexCollaborationModeOption(name: displayName(for: mode), mode: mode, raw: value)
        case .dictionary(let object):
            guard let mode = string(in: object, keys: ["mode", "id", "value"]) else { return nil }
            let name = string(in: object, keys: ["name", "displayName", "title"]) ?? displayName(for: mode)
            let model = string(in: object, keys: ["model", "modelIdentifier"])
            let reasoning = string(in: object, keys: ["reasoning_effort", "reasoningEffort"])
                .flatMap(CodexReasoningSelection.init(appServerValue:))
            return CodexCollaborationModeOption(
                name: name,
                mode: mode,
                modelIdentifier: model,
                reasoning: reasoning,
                raw: value
            )
        case .array, .int, .double, .bool, .null:
            return nil
        }
    }

    private static func displayName(for mode: String) -> String {
        mode
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let string):
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case .int(let int): return String(int)
            case .double(let double): return String(double)
            case .bool(let bool): return String(bool)
            case .array, .dictionary, .null:
                continue
            }
        }
        return nil
    }
}

public struct CodexSlashCommand: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var systemImage: String
    public var section: String
    public var scopeBadge: String?
    public var draftText: String?
    public var skillName: String?
    public var skillPath: String?
    public var requiresEmptyComposer: Bool
    public var isEnabled: Bool

    public init(
        id: String,
        title: String,
        detail: String,
        systemImage: String,
        section: String = "Commands",
        scopeBadge: String? = nil,
        draftText: String? = nil,
        skillName: String? = nil,
        skillPath: String? = nil,
        requiresEmptyComposer: Bool = false,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.section = section
        self.scopeBadge = scopeBadge
        self.draftText = draftText
        self.skillName = skillName
        self.skillPath = skillPath
        self.requiresEmptyComposer = requiresEmptyComposer
        self.isEnabled = isEnabled
    }

    public static let observedCommands: [CodexSlashCommand] = [
        CodexSlashCommand(
            id: "compact",
            title: "Compact",
            detail: "Compact the current thread context",
            systemImage: "rectangle.compress.vertical",
            requiresEmptyComposer: true
        ),
        CodexSlashCommand(
            id: "fast",
            title: "Fast",
            detail: "Switch to a faster response mode",
            systemImage: "bolt.fill"
        ),
        CodexSlashCommand(
            id: "feedback",
            title: "Feedback",
            detail: "Send feedback about Codex",
            systemImage: "bubble.left.and.exclamationmark.bubble.right"
        ),
        CodexSlashCommand(
            id: "fork",
            title: "Fork",
            detail: "Continue this chat in a new task",
            systemImage: "arrow.triangle.branch",
            requiresEmptyComposer: true
        ),
        CodexSlashCommand(
            id: "goal",
            title: "Goal",
            detail: "Set a goal to keep pursuing",
            systemImage: "target"
        ),
        CodexSlashCommand(
            id: "init",
            title: "Init",
            detail: "Create an AGENTS.md for this project",
            systemImage: "doc.badge.plus",
            requiresEmptyComposer: true
        ),
        CodexSlashCommand(
            id: "mcp",
            title: "MCP",
            detail: "Inspect configured MCP servers",
            systemImage: "server.rack"
        ),
        CodexSlashCommand(
            id: "model",
            title: "Model",
            detail: "Change model",
            systemImage: "sparkles"
        ),
        CodexSlashCommand(
            id: "new",
            title: "New chat",
            detail: "Start a new chat",
            systemImage: "square.and.pencil",
            requiresEmptyComposer: true
        ),
        CodexSlashCommand(
            id: "plan",
            title: "Plan mode",
            detail: "Plan before editing",
            systemImage: "map"
        ),
        CodexSlashCommand(
            id: "reasoning",
            title: "Reasoning",
            detail: "Change reasoning effort",
            systemImage: "brain"
        ),
        CodexSlashCommand(
            id: "review",
            title: "Review",
            detail: "Review the current changes",
            systemImage: "checkmark.bubble"
        ),
        CodexSlashCommand(
            id: "side",
            title: "Side",
            detail: "Open a side chat",
            systemImage: "rectangle.split.2x1"
        ),
        CodexSlashCommand(
            id: "status",
            title: "Status",
            detail: "Show chat ID, context usage, and rate limits",
            systemImage: "waveform.path.ecg"
        )
    ]

    public static func query(from draft: String) -> String? {
        invocation(from: draft)?.query
    }

    public static func invocation(from draft: String) -> CodexSlashCommandInvocation? {
        guard !draft.isEmpty else { return nil }

        var tokenStart: String.Index?
        var index = draft.startIndex
        while index < draft.endIndex {
            if draft[index] == "/" {
                let isTokenBoundary = index == draft.startIndex || draft[draft.index(before: index)].isWhitespace
                if isTokenBoundary {
                    tokenStart = index
                }
            }
            index = draft.index(after: index)
        }

        guard let start = tokenStart else { return nil }
        let queryStart = draft.index(after: start)
        let end = draft[queryStart...].firstIndex(where: \.isWhitespace) ?? draft.endIndex
        let query = String(draft[queryStart..<end])
        let replacementRange = replacementRange(for: start..<end, in: draft)
        let replacementDraft = String(draft[..<replacementRange.lowerBound] + draft[replacementRange.upperBound...])

        return CodexSlashCommandInvocation(
            query: query,
            replacementDraft: replacementDraft,
            hasOtherContent: !replacementDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    public static func filteredCommands(
        from commands: [CodexSlashCommand] = CodexSlashCommand.observedCommands,
        matching draft: String
    ) -> [CodexSlashCommand] {
        guard let invocation = invocation(from: draft) else { return [] }
        let commands = commands.filter {
            $0.isEnabled && (!$0.requiresEmptyComposer || !invocation.hasOtherContent)
        }
        let query = invocation.query
        guard !query.isEmpty else { return commands }
        let needle = query.lowercased()

        let prefixMatches = commands.filter { command in
            command.id.lowercased().hasPrefix(needle) ||
                command.title.lowercased().hasPrefix(needle)
        }
        if !prefixMatches.isEmpty { return prefixMatches }

        let primaryMatches = commands.filter { command in
            command.id.lowercased().contains(needle) ||
                command.title.lowercased().contains(needle)
        }
        if !primaryMatches.isEmpty { return primaryMatches }

        return commands.filter { command in
            command.detail.lowercased().contains(needle)
        }
    }

    public func withAvailability(_ isEnabled: Bool) -> CodexSlashCommand {
        var copy = self
        copy.isEnabled = isEnabled
        return copy
    }

    private static func replacementRange(
        for commandRange: Range<String.Index>,
        in draft: String
    ) -> Range<String.Index> {
        if commandRange.lowerBound > draft.startIndex {
            let preceding = draft.index(before: commandRange.lowerBound)
            if draft[preceding].isWhitespace {
                return preceding..<commandRange.upperBound
            }
        }
        if commandRange.upperBound < draft.endIndex, draft[commandRange.upperBound].isWhitespace {
            return commandRange.lowerBound..<draft.index(after: commandRange.upperBound)
        }
        return commandRange
    }

    public static func skillCommands(from response: CodexJSONValue) -> [CodexSlashCommand] {
        guard case .dictionary(let object) = response,
              case .array(let entries)? = object["data"] else {
            return []
        }

        var seen: Set<String> = []
        var commands: [CodexSlashCommand] = []
        for entry in entries {
            guard case .dictionary(let entryObject) = entry,
                  case .array(let skills)? = entryObject["skills"] else {
                continue
            }

            for skill in skills {
                guard let command = skillCommand(from: skill) else { continue }
                let identity = command.skillPath ?? command.skillName ?? command.id
                guard seen.insert(identity).inserted else { continue }
                commands.append(command)
            }
        }
        return commands.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func skillCommand(from value: CodexJSONValue) -> CodexSlashCommand? {
        guard case .dictionary(let object) = value,
              (CodexJSONCoercion.bool(in: object, key: "enabled") ?? true),
              !(CodexJSONCoercion.bool(in: object, key: "disable-model-invocation") ?? false),
              !(CodexJSONCoercion.bool(in: object, key: "disableModelInvocation") ?? false),
              let name = string(in: object, keys: ["name"]),
              let path = string(in: object, keys: ["path"]) else {
            return nil
        }

        let interface = dictionary(in: object, key: "interface")
        let title = interface.flatMap { string(in: $0, keys: ["displayName"]) } ?? name
        let detail = interface.flatMap { string(in: $0, keys: ["shortDescription"]) } ??
            string(in: object, keys: ["shortDescription", "description"]) ??
            "Skill"
        let prompt = interface.flatMap { string(in: $0, keys: ["defaultPrompt"]) }?.nilIfBlank
        let scope = string(in: object, keys: ["scope"])

        return CodexSlashCommand(
            id: "skill:\(name)",
            title: title,
            detail: detail,
            systemImage: "hammer",
            section: "Skills",
            scopeBadge: scopeBadge(from: scope),
            draftText: prompt,
            skillName: name,
            skillPath: path
        )
    }

    public static func promptCommands(from prompts: [CodexPromptLibraryEntry]) -> [CodexSlashCommand] {
        prompts.map { prompt in
            let source: (section: String, badge: String?, image: String)
            switch prompt.source {
            case .user:
                source = ("Prompts", "Personal", "text.book.closed")
            case .mcp(let serverName):
                source = ("MCP prompts", serverName, "server.rack")
            }
            return CodexSlashCommand(
                id: "prompt:\(prompt.name)",
                title: prompt.name,
                detail: prompt.argumentHint.map { "\(prompt.description) · \($0)" } ?? prompt.description,
                systemImage: source.image,
                section: source.section,
                scopeBadge: source.badge,
                draftText: prompt.body
            )
        }.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    public static func mergedCommands(
        prompts: [CodexPromptLibraryEntry],
        skillsResponse: CodexJSONValue
    ) -> [CodexSlashCommand] {
        observedCommands + promptCommands(from: prompts) + skillCommands(from: skillsResponse)
    }

    private static func scopeBadge(from rawScope: String?) -> String? {
        switch rawScope {
        case "user": return "Personal"
        case "repo": return "Repo"
        case "system": return "System"
        case "admin": return "Admin"
        case .some(let value): return value.capitalized
        case nil: return nil
        }
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let string): return string.nilIfBlank
            case .int(let int): return String(int)
            case .double(let double): return String(double)
            case .bool(let bool): return String(bool)
            case .array, .dictionary, .null: continue
            }
        }
        return nil
    }

    private static func dictionary(in object: [String: CodexJSONValue], key: String) -> [String: CodexJSONValue]? {
        guard case .dictionary(let dictionary)? = object[key] else { return nil }
        return dictionary
    }
}

public struct CodexSlashCommandInvocation: Equatable, Sendable {
    public var query: String
    public var replacementDraft: String
    public var hasOtherContent: Bool

    public init(query: String, replacementDraft: String, hasOtherContent: Bool) {
        self.query = query
        self.replacementDraft = replacementDraft
        self.hasOtherContent = hasOtherContent
    }
}
