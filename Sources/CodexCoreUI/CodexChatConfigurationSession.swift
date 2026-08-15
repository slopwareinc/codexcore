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
    private var permissionProfiles: [CodexPermissionProfileSummary]
    public private(set) var managedPolicyRequirements: CodexManagedPolicyRequirements?
    private var activeThreadHasExplicitPermissionProfile: Bool
    public private(set) var collaborationModes: [CodexCollaborationModeOption]
    public private(set) var isPlanModeEnabled: Bool
    public private(set) var modelSelection: CodexModelSelection
    public private(set) var modelOptions: [CodexModelSelection]
    public private(set) var serviceTierSelection: CodexServiceTierSelection
    public var reasoningSelection: CodexReasoningSelection
    public private(set) var slashCommands: [CodexSlashCommand]
    private var modelIndex: CodexModelIndex
    private var preferredModel: CodexModelSelection

    public init(
        approvalSelection: CodexApprovalSelection = .askForApproval,
        approvalOptions: [CodexApprovalSelection] = CodexApprovalSelection.defaultOptions,
        managedPolicyRequirements: CodexManagedPolicyRequirements? = nil,
        collaborationModes: [CodexCollaborationModeOption] = CodexCollaborationModeOption.defaultOptions,
        isPlanModeEnabled: Bool = false,
        modelSelection: CodexModelSelection = .appServerDefault,
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        serviceTierSelection: CodexServiceTierSelection = .standard,
        reasoningSelection: CodexReasoningSelection = .medium,
        slashCommands: [CodexSlashCommand] = CodexSlashCommand.observedCommands
    ) {
        let narrowedApprovalOptions = managedPolicyRequirements?.narrowApprovalOptions(approvalOptions)
            ?? approvalOptions
        let initialApprovalSelection = narrowedApprovalOptions.contains(approvalSelection)
            ? approvalSelection
            : Self.safeFallbackApprovalSelection(in: narrowedApprovalOptions)
        self.selectedApprovalSelection = initialApprovalSelection
        self.ambientApprovalSelection = initialApprovalSelection
        self.hasActiveThreadPermissionConfiguration = false
        self.approvalOptions = narrowedApprovalOptions
        self.catalogApprovalOptions = narrowedApprovalOptions
        self.permissionProfiles = []
        self.managedPolicyRequirements = managedPolicyRequirements
        self.activeThreadHasExplicitPermissionProfile = false
        self.collaborationModes = collaborationModes
        self.isPlanModeEnabled = isPlanModeEnabled
        self.modelSelection = modelSelection
        self.modelOptions = modelOptions
        self.serviceTierSelection = serviceTierSelection.reconciled(
            for: modelSelection
        )
        self.reasoningSelection = reasoningSelection
        self.slashCommands = slashCommands
        self.modelIndex = CodexModelIndex(models: modelOptions)
        self.preferredModel = CodexModelSelection.preferredDefault(from: modelOptions)
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

    package var wireSelection: CodexTaskWireSelection {
        CodexTaskWireSelection(
            modelIdentifier: modelSelection.modelIdentifier,
            serviceTier: serviceTierSelection.protocolValue,
            effort: CodexSchemaReasoningEffort(
                .string(reasoningSelection.effort.rawValue)
            )
        )
    }

    package func wireSelection(
        for preference: CodexResolvedModelPreference?,
        explicitTierOnly: Bool = false
    ) -> CodexTaskWireSelection {
        guard let preference else {
            return CodexTaskWireSelection(
                modelIdentifier: nil,
                serviceTier: nil,
                effort: wireSelection.effort
            )
        }
        return CodexTaskWireSelection(
            modelIdentifier: preference.model.modelIdentifier,
            serviceTier: explicitTierOnly && !preference.isServiceTierExplicit
                ? nil
                : preference.serviceTier.protocolValue,
            effort: wireSelection.effort
        )
    }

    public var collaborationModeOverride: CodexSchemaCollaborationMode? {
        guard isPlanModeEnabled,
              let planModeOption,
              let model = planModeOption.modelIdentifier ?? modelSelection.modelIdentifier else {
            return nil
        }
        let reasoning = planModeOption.reasoning ?? reasoningSelection
        return CodexSchemaCollaborationMode(
            mode: CodexSchemaModeKind(rawValue: planModeOption.mode)!,
            settings: CodexSchemaSettings(
                model: model,
                reasoningEffort: CodexSchemaReasoningEffort(.string(reasoning.effort.rawValue))
            )
        )
    }

    public mutating func reset() {
        hasActiveThreadPermissionConfiguration = false
        let defaults = managedPolicyRequirements?.narrowApprovalOptions(
            CodexApprovalSelection.defaultOptions
        ) ?? CodexApprovalSelection.defaultOptions
        let resetSelection = defaults.contains(.askForApproval)
            ? .askForApproval
            : Self.safeFallbackApprovalSelection(in: defaults)
        selectedApprovalSelection = resetSelection
        ambientApprovalSelection = resetSelection
        approvalOptions = defaults
        catalogApprovalOptions = defaults
        permissionProfiles = []
        activeThreadHasExplicitPermissionProfile = false
        collaborationModes = CodexCollaborationModeOption.defaultOptions
        isPlanModeEnabled = false
        modelSelection = .appServerDefault
        modelOptions = CodexModelSelection.defaultOptions
        modelIndex = CodexModelIndex(models: modelOptions)
        preferredModel = CodexModelSelection.preferredDefault(from: modelOptions)
        serviceTierSelection = .standard
        reasoningSelection = .medium
        slashCommands = CodexSlashCommand.observedCommands
    }

    public mutating func setPlanModeEnabled(_ enabled: Bool) {
        isPlanModeEnabled = enabled
        guard enabled, let reasoning = planModeOption?.reasoning else { return }
        reasoningSelection = reasoning
    }

    public mutating func selectModel(
        _ selection: CodexModelSelection,
        useServerDefaults: Bool = false
    ) {
        let previousTier = serviceTierSelection
        modelSelection = selection
        if useServerDefaults {
            reasoningSelection = selection.defaultReasoning
                ?? supportedReasoning(for: selection).first
                ?? .medium
            serviceTierSelection = selection.defaultServiceTierSelection
        } else {
            normalizeReasoningForSelectedModel()
            serviceTierSelection = previousTier.reconciled(for: selection)
        }
    }

    private func modelOption(id: String?) -> CodexModelSelection? {
        id.flatMap { modelIndex.model(id: $0) }
    }

    package func resolveModelPreference(
        _ preference: CodexModelPreference
    ) -> CodexResolvedModelPreference {
        let model = modelOption(id: preference.modelID)
            ?? authoritativeFallbackModel(for: preference)
            ?? preferredModel
        let serviceTier = if preference.serviceTierID == nil,
                             !preference.isServiceTierExplicit {
            model.defaultServiceTierSelection
        } else {
            model.serviceTierSelection(id: preference.serviceTierID)
        }
        return CodexResolvedModelPreference(
            model: model,
            serviceTier: serviceTier,
            isServiceTierExplicit: preference.isServiceTierExplicit
        )
    }

    @discardableResult
    public mutating func selectServiceTier(
        _ selection: CodexServiceTierSelection
    ) -> Bool {
        switch selection {
        case .standard:
            serviceTierSelection = .standard
            return true
        case .tier(let requested):
            guard let tier = modelSelection.serviceTier(id: requested.id) else {
                return false
            }
            serviceTierSelection = .tier(tier)
            return true
        }
    }

    @discardableResult
    public mutating func applyPermissionProfileResponse(_ raw: CodexJSONValue) -> CodexChatConfigurationActivity {
        let profiles = CodexPermissionProfileSummary.profiles(from: raw)
        permissionProfiles = profiles
        let options = CodexApprovalSelection.options(
            from: profiles,
            requirements: managedPolicyRequirements
        )
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

    /// Applies the installation policy fetched by `configRequirements/read`.
    /// Call this after a requirements response arrives; no-op requirements
    /// preserve the normal permission-profile catalog behavior.
    public mutating func applyConfigurationRequirements(
        _ requirements: CodexManagedPolicyRequirements?
    ) {
        managedPolicyRequirements = requirements
        let options: [CodexApprovalSelection]
        if permissionProfiles.isEmpty {
            options = requirements?.narrowApprovalOptions(
                CodexApprovalSelection.defaultOptions
            ) ?? CodexApprovalSelection.defaultOptions
        } else {
            options = CodexApprovalSelection.options(
                from: permissionProfiles,
                requirements: requirements
            )
        }
        catalogApprovalOptions = options
        reconcileApprovalOptions()

        if !options.contains(ambientApprovalSelection) {
            ambientApprovalSelection = Self.safeFallbackApprovalSelection(in: options)
        }
        if !hasActiveThreadPermissionConfiguration,
           !approvalOptions.contains(approvalSelection) {
            selectedApprovalSelection = ambientApprovalSelection
        }
    }

    public mutating func applyConfigurationRequirements(
        _ requirements: CodexSchemaConfigRequirements?
    ) {
        applyConfigurationRequirements(
            requirements.map(CodexManagedPolicyRequirements.init(requirements:))
        )
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
        approvalOptions = catalogApprovalOptions
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
            installModelOptions(CodexModelSelection.defaultOptions)
            selectModel(.appServerDefault)
            return CodexChatConfigurationActivity(title: "Model list empty", detail: "Using app-server default model")
        }

        installModelOptions(options)
        let usesServerDefaults = modelSelection.id == CodexModelSelection.appServerDefault.id
        let selection = usesServerDefaults
            ? CodexModelSelection.preferredDefault(from: options)
            : selectedModel(from: options)
        selectModel(selection, useServerDefaults: usesServerDefaults)
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
        installModelOptions(CodexModelSelection.defaultOptions)
        selectModel(.appServerDefault)
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
        fallbackQuery: String = "fast",
        fallbackReasoning: CodexReasoningSelection? = nil
    ) -> CodexChatConfigurationActivity {
        applyFastCommandResult(
            fallbackQuery: fallbackQuery,
            fallbackReasoning: fallbackReasoning
        ).activity
    }

    package mutating func applyFastCommandResult(
        fallbackQuery: String = "fast",
        fallbackReasoning: CodexReasoningSelection? = nil
    ) -> (
        activity: CodexChatConfigurationActivity,
        didApply: Bool
    ) {
        guard case .tier(let target) = modelSelection.serviceTierSelection(
            id: fallbackQuery
        ) else {
            return (
                CodexChatConfigurationActivity(
                    title: "Fast mode",
                    detail: "Fast is unavailable for \(modelSelection.displayName)"
                ),
                false
            )
        }

        serviceTierSelection = .tier(target)
        if let fastReasoning = fallbackReasoning,
           supportedReasoning(for: modelSelection).contains(fastReasoning) {
            reasoningSelection = fastReasoning
        }

        return (
            CodexChatConfigurationActivity(
                title: "Fast mode",
                detail: "\(modelSelection.displayName) \(target.displayName)"
            ),
            true
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

    private mutating func installModelOptions(
        _ models: [CodexModelSelection]
    ) {
        modelOptions = models
        modelIndex = CodexModelIndex(models: models)
        preferredModel = CodexModelSelection.preferredDefault(from: models)
    }

    private func authoritativeFallbackModel(
        for preference: CodexModelPreference
    ) -> CodexModelSelection? {
        guard preference.isAuthoritativeModelID,
              let id = preference.modelID,
              !id.isEmpty
        else { return nil }
        return CodexModelSelection(
            id: id,
            displayName: id,
            modelIdentifier: id
        )
    }
}

private struct CodexModelIndex: Equatable, Sendable {
    private var exact: [String: CodexModelSelection] = [:]
    private var aliases: [String: CodexModelSelection] = [:]

    init(models: [CodexModelSelection]) {
        for model in models {
            let exactKey = model.id.lowercased()
            if exact[exactKey] == nil {
                exact[exactKey] = model
            }
            if let identifier = model.modelIdentifier {
                let aliasKey = identifier.lowercased()
                if aliases[aliasKey] == nil {
                    aliases[aliasKey] = model
                }
            }
        }
    }

    func model(id: String) -> CodexModelSelection? {
        let key = id.lowercased()
        return exact[key] ?? aliases[key]
    }
}
