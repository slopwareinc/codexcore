import Foundation
import CodexCore

public struct CodexChatConfigurationActivity: Equatable, Sendable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

public struct CodexChatConfigurationSession: Equatable, Sendable {
    private var selectedApprovalSelection: CodexApprovalSelection
    private var ambientApprovalSelection: CodexApprovalSelection
    private var hasActiveThreadPermissionConfiguration: Bool
    public private(set) var approvalOptions: [CodexApprovalSelection]
    private var catalogApprovalOptions: [CodexApprovalSelection]
    private var activeThreadHasExplicitPermissionProfile: Bool
    public private(set) var collaborationModes: [CodexCollaborationModeOption]
    public private(set) var isPlanModeEnabled: Bool
    public private(set) var modelSelection: CodexModelSelection
    public private(set) var modelOptions: [CodexModelSelection]
    public var reasoningSelection: CodexReasoningSelection
    public private(set) var slashCommands: [CodexSlashCommand]

    public init(
        approvalSelection: CodexApprovalSelection = .askForApproval,
        approvalOptions: [CodexApprovalSelection] = CodexApprovalSelection.defaultOptions,
        collaborationModes: [CodexCollaborationModeOption] = CodexCollaborationModeOption.defaultOptions,
        isPlanModeEnabled: Bool = false,
        modelSelection: CodexModelSelection = .appServerDefault,
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        reasoningSelection: CodexReasoningSelection = .medium,
        slashCommands: [CodexSlashCommand] = CodexSlashCommand.observedCommands
    ) {
        self.selectedApprovalSelection = approvalSelection
        self.ambientApprovalSelection = approvalSelection
        self.hasActiveThreadPermissionConfiguration = false
        self.approvalOptions = approvalOptions
        self.catalogApprovalOptions = approvalOptions
        self.activeThreadHasExplicitPermissionProfile = false
        self.collaborationModes = collaborationModes
        self.isPlanModeEnabled = isPlanModeEnabled
        self.modelSelection = modelSelection
        self.modelOptions = modelOptions
        self.reasoningSelection = reasoningSelection
        self.slashCommands = slashCommands
    }

    public var approvalSelection: CodexApprovalSelection {
        get { selectedApprovalSelection }
        set {
            selectedApprovalSelection = newValue
            if !hasActiveThreadPermissionConfiguration {
                ambientApprovalSelection = newValue
            }
        }
    }

    /// The selection used when creating a thread independently of the active
    /// thread, such as from the Voice task tool.
    package var newThreadApprovalSelection: CodexApprovalSelection {
        ambientApprovalSelection
    }

    public var canUsePlanMode: Bool {
        planModeOption != nil
    }

    public var turnParameterOverrides: [String: CodexJSONValue] {
        var params = approvalSelection.turnParameterOverrides
        if isPlanModeEnabled,
           let planModeOption,
           let model = planModeOption.modelIdentifier ?? modelSelection.modelIdentifier {
            var settings: [String: CodexJSONValue] = ["model": .string(model)]
            if let reasoning = planModeOption.reasoning ?? Optional(reasoningSelection) {
                settings["reasoning_effort"] = .string(reasoning.effort.rawValue)
            }
            params["collaborationMode"] = .dictionary([
                "mode": .string(planModeOption.mode),
                "settings": .dictionary(settings),
            ])
        }
        return params
    }

    public mutating func reset() {
        selectedApprovalSelection = .askForApproval
        ambientApprovalSelection = .askForApproval
        hasActiveThreadPermissionConfiguration = false
        approvalOptions = CodexApprovalSelection.defaultOptions
        catalogApprovalOptions = CodexApprovalSelection.defaultOptions
        activeThreadHasExplicitPermissionProfile = false
        collaborationModes = CodexCollaborationModeOption.defaultOptions
        isPlanModeEnabled = false
        modelSelection = .appServerDefault
        modelOptions = CodexModelSelection.defaultOptions
        reasoningSelection = .medium
        slashCommands = CodexSlashCommand.observedCommands
    }

    public mutating func setPlanModeEnabled(_ enabled: Bool) {
        isPlanModeEnabled = enabled
        guard enabled, let reasoning = planModeOption?.reasoning else { return }
        reasoningSelection = reasoning
    }

    public mutating func selectModel(_ selection: CodexModelSelection) {
        modelSelection = selection
        normalizeReasoningForSelectedModel()
    }

    @discardableResult
    public mutating func applyPermissionProfileResponse(_ raw: CodexJSONValue) -> CodexChatConfigurationActivity {
        let profiles = CodexPermissionProfileSummary.profiles(from: raw)
        let options = CodexApprovalSelection.options(from: profiles)
        catalogApprovalOptions = options
        reconcileApprovalOptions()
        if !options.contains(ambientApprovalSelection) {
            ambientApprovalSelection = Self.safeFallbackApprovalSelection(
                in: options
            )
        }
        if !hasActiveThreadPermissionConfiguration,
           !approvalOptions.contains(approvalSelection) {
            selectedApprovalSelection = ambientApprovalSelection
        }
        return CodexChatConfigurationActivity(title: "Loaded access profiles", detail: "\(profiles.count) app-server profiles")
    }

    @discardableResult
    public mutating func refreshPermissionProfiles(
        using codex: Codex,
        errorMessage: (Error) -> String
    ) async -> CodexChatConfigurationActivity {
        do {
            let response = try await codex.perform(CodexRequest.permissionProfileList(.init()))
            return applyPermissionProfileResponse(try CodexJSONValue(encoding: response))
        } catch {
            return failPermissionProfileRefresh(message: errorMessage(error))
        }
    }

    public mutating func refreshStartupCatalogs(
        using codex: Codex,
        cwds: [String],
        forceReloadSkills: Bool = false,
        errorMessage: (Error) -> String
    ) async -> [CodexChatConfigurationActivity] {
        [
            await refreshPermissionProfiles(using: codex, errorMessage: errorMessage),
            await refreshCollaborationModes(using: codex, errorMessage: errorMessage),
            await refreshModelOptions(using: codex, errorMessage: errorMessage),
            await refreshSlashCommands(
                using: codex,
                cwds: cwds,
                forceReload: forceReloadSkills,
                errorMessage: errorMessage
            )
        ]
    }

    @discardableResult
    public mutating func failPermissionProfileRefresh(message: String) -> CodexChatConfigurationActivity {
        reconcileApprovalOptions()
        return CodexChatConfigurationActivity(title: "Access profiles unavailable", detail: message)
    }

    package mutating func applyActiveThreadPermissionConfiguration(
        _ configuration: CodexThreadPermissionConfiguration
    ) {
        if !hasActiveThreadPermissionConfiguration {
            ambientApprovalSelection = selectedApprovalSelection
        }
        hasActiveThreadPermissionConfiguration = true
        activeThreadHasExplicitPermissionProfile = configuration.profileID != nil
        selectedApprovalSelection = CodexApprovalSelection.selection(
            profileID: configuration.profileID,
            approvalsReviewer: configuration.approvalsReviewer
        )
        reconcileApprovalOptions()
    }

    package mutating func clearActiveThreadPermissionConfiguration() {
        let restoredSelection = catalogApprovalOptions.contains(ambientApprovalSelection)
            ? ambientApprovalSelection
            : Self.safeFallbackApprovalSelection(in: catalogApprovalOptions)
        hasActiveThreadPermissionConfiguration = false
        activeThreadHasExplicitPermissionProfile = false
        selectedApprovalSelection = restoredSelection
        ambientApprovalSelection = restoredSelection
        reconcileApprovalOptions()
    }

    /// Commits the exact profile from a successful main-thread turn request.
    package mutating func markPermissionProfileActive(
        _ configuration: CodexPermissionProfileWireConfiguration
    ) {
        guard let profileID = configuration.permissions else { return }
        if !hasActiveThreadPermissionConfiguration {
            ambientApprovalSelection = selectedApprovalSelection
        }
        hasActiveThreadPermissionConfiguration = true
        activeThreadHasExplicitPermissionProfile = true
        selectedApprovalSelection = CodexApprovalSelection.selection(
            profileID: profileID,
            approvalsReviewer: configuration.approvalsReviewer ?? .user
        )
        reconcileApprovalOptions()
    }

    private mutating func reconcileApprovalOptions() {
        approvalOptions = activeThreadHasExplicitPermissionProfile
            ? catalogApprovalOptions.filter { $0 != .custom }
            : catalogApprovalOptions
    }

    private static func safeFallbackApprovalSelection(
        in options: [CodexApprovalSelection]
    ) -> CodexApprovalSelection {
        [.askForApproval, .readOnly, .approveForMe, .custom]
            .first(where: { options.contains($0) })
            ?? .custom
    }

    @discardableResult
    public mutating func applyCollaborationModeResponse(_ raw: CodexJSONValue) -> CodexChatConfigurationActivity {
        let modes = CodexCollaborationModeOption.options(from: raw)
        collaborationModes = modes
        syncPlanModeReasoning()
        return CodexChatConfigurationActivity(title: "Loaded collaboration modes", detail: "\(modes.count) app-server modes")
    }

    @discardableResult
    public mutating func refreshCollaborationModes(
        using codex: Codex,
        errorMessage: (Error) -> String
    ) async -> CodexChatConfigurationActivity {
        do {
            let response = try await codex.perform(CodexRequest.collaborationModeList(.init()))
            return applyCollaborationModeResponse(try CodexJSONValue(encoding: response))
        } catch {
            return failCollaborationModeRefresh(message: errorMessage(error))
        }
    }

    @discardableResult
    public mutating func failCollaborationModeRefresh(message: String) -> CodexChatConfigurationActivity {
        collaborationModes = CodexCollaborationModeOption.defaultOptions
        syncPlanModeReasoning()
        return CodexChatConfigurationActivity(title: "Collaboration modes unavailable", detail: message)
    }

    @discardableResult
    public mutating func applyModelResponse(_ response: CodexSchemaModelListResponse) -> CodexChatConfigurationActivity {
        let options = CodexModelSelection.options(from: response)
        guard !options.isEmpty else {
            modelOptions = CodexModelSelection.defaultOptions
            selectModel(.appServerDefault)
            return CodexChatConfigurationActivity(title: "Model list empty", detail: "Using app-server default model")
        }

        modelOptions = options
        let selection = modelSelection.id == CodexModelSelection.appServerDefault.id
            ? CodexModelSelection.preferredDefault(from: options)
            : selectedModel(from: options)
        selectModel(selection)
        return CodexChatConfigurationActivity(title: "Loaded models", detail: "\(options.count) app-server models")
    }

    @discardableResult
    public mutating func refreshModelOptions(
        using codex: Codex,
        errorMessage: (Error) -> String
    ) async -> CodexChatConfigurationActivity {
        do {
            return applyModelResponse(try await codex.perform(CodexRequest.modelList(.init(includeHidden: false))))
        } catch {
            return failModelRefresh(message: errorMessage(error))
        }
    }

    @discardableResult
    public mutating func failModelRefresh(message: String) -> CodexChatConfigurationActivity {
        modelOptions = CodexModelSelection.defaultOptions
        return CodexChatConfigurationActivity(title: "Model list unavailable", detail: message)
    }

    @discardableResult
    public mutating func applySlashCommandResponse(_ raw: CodexJSONValue) -> CodexChatConfigurationActivity {
        let skillCommands = CodexSlashCommand.skillCommands(from: raw)
        slashCommands = CodexSlashCommand.observedCommands + skillCommands
        return CodexChatConfigurationActivity(title: "Loaded skills", detail: "\(skillCommands.count) app-server skills")
    }

    @discardableResult
    public mutating func refreshSlashCommands(
        using codex: Codex,
        cwds: [String],
        forceReload: Bool = false,
        errorMessage: (Error) -> String
    ) async -> CodexChatConfigurationActivity {
        do {
            let response = try await codex.perform(CodexRequest.skillsList(.init(
                cwds: cwds.isEmpty ? nil : cwds,
                forceReload: forceReload ? true : nil
            )))
            return applySlashCommandResponse(try CodexJSONValue(encoding: response))
        } catch {
            return failSlashCommandRefresh(message: errorMessage(error))
        }
    }

    @discardableResult
    public mutating func failSlashCommandRefresh(message: String) -> CodexChatConfigurationActivity {
        slashCommands = CodexSlashCommand.observedCommands
        return CodexChatConfigurationActivity(title: "Skill list unavailable", detail: message)
    }

    @discardableResult
    public mutating func applyFastCommand(
        fallbackQuery: String = "speed",
        fallbackReasoning: CodexReasoningSelection? = nil
    ) -> CodexChatConfigurationActivity {
        guard let target = modelOptions.first(where: { option in
            option.isFastModel ||
            option.id.caseInsensitiveCompare(fallbackQuery) == .orderedSame ||
            option.modelIdentifier?.caseInsensitiveCompare(fallbackQuery) == .orderedSame ||
            option.displayName.localizedCaseInsensitiveContains(fallbackQuery)
        }) else {
            return CodexChatConfigurationActivity(title: "Fast mode", detail: "No Fast model returned by app-server")
        }

        selectModel(target)

        let supported = target.supportedReasoning
        if let fastReasoning = fallbackReasoning ?? target.defaultReasoning ?? [CodexReasoningSelection.minimal, .low, .none].first(where: { supported.contains($0) }) {
            reasoningSelection = fastReasoning
        }

        return CodexChatConfigurationActivity(
            title: "Fast mode",
            detail: "\(modelSelection.displayName) \(reasoningSelection.displayName)"
        )
    }

    @discardableResult
    public mutating func cycleReasoning() -> CodexChatConfigurationActivity? {
        let supported = supportedReasoning(for: modelSelection)
        guard !supported.isEmpty else { return nil }

        if let index = supported.firstIndex(of: reasoningSelection) {
            reasoningSelection = supported[(index + 1) % supported.count]
        } else {
            reasoningSelection = modelSelection.defaultReasoning ?? supported.first ?? .medium
        }

        return CodexChatConfigurationActivity(title: "Reasoning", detail: reasoningSelection.displayName)
    }

    private var planModeOption: CodexCollaborationModeOption? {
        collaborationModes.first(where: \.isPlanMode)
    }

    private mutating func syncPlanModeReasoning() {
        if isPlanModeEnabled, planModeOption == nil {
            isPlanModeEnabled = false
        } else if isPlanModeEnabled, let reasoning = planModeOption?.reasoning {
            reasoningSelection = reasoning
        }
    }

    private func selectedModel(from options: [CodexModelSelection]) -> CodexModelSelection {
        if let current = options.first(where: { option in
            option.id == modelSelection.id ||
                (option.modelIdentifier != nil && option.modelIdentifier == modelSelection.modelIdentifier)
        }) {
            return current
        }
        if let defaultOption = options.first(where: \.isDefault) {
            return defaultOption
        }
        return options.first ?? modelSelection
    }

    private mutating func normalizeReasoningForSelectedModel() {
        let supported = supportedReasoning(for: modelSelection)
        if !supported.contains(reasoningSelection) {
            if let defaultReasoning = modelSelection.defaultReasoning, supported.contains(defaultReasoning) {
                reasoningSelection = defaultReasoning
            } else {
                reasoningSelection = supported.first ?? .medium
            }
        }
    }

    private func supportedReasoning(for model: CodexModelSelection) -> [CodexReasoningSelection] {
        model.supportedReasoning.isEmpty ? CodexReasoningSelection.defaultOptions : model.supportedReasoning
    }
}
