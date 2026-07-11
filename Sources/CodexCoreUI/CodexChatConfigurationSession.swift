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
    public var approvalSelection: CodexApprovalSelection
    public private(set) var approvalOptions: [CodexApprovalSelection]
    public private(set) var collaborationModes: [CodexCollaborationModeOption]
    public private(set) var isPlanModeEnabled: Bool
    public private(set) var modelSelection: CodexModelSelection
    public private(set) var modelOptions: [CodexModelSelection]
    public var reasoningSelection: CodexReasoningSelection
    public private(set) var slashCommands: [CodexSlashCommand]

    public init(
        approvalSelection: CodexApprovalSelection = .fullAccess,
        approvalOptions: [CodexApprovalSelection] = CodexApprovalSelection.defaultOptions,
        collaborationModes: [CodexCollaborationModeOption] = CodexCollaborationModeOption.defaultOptions,
        isPlanModeEnabled: Bool = false,
        modelSelection: CodexModelSelection = .appServerDefault,
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        reasoningSelection: CodexReasoningSelection = .medium,
        slashCommands: [CodexSlashCommand] = CodexSlashCommand.observedCommands
    ) {
        self.approvalSelection = approvalSelection
        self.approvalOptions = approvalOptions
        self.collaborationModes = collaborationModes
        self.isPlanModeEnabled = isPlanModeEnabled
        self.modelSelection = modelSelection
        self.modelOptions = modelOptions
        self.reasoningSelection = reasoningSelection
        self.slashCommands = slashCommands
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
        approvalSelection = .fullAccess
        approvalOptions = CodexApprovalSelection.defaultOptions
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
        approvalOptions = options
        if !options.contains(approvalSelection) {
            approvalSelection = options.contains(.fullAccess) ? .fullAccess : (options.first ?? .approveForMe)
        }
        return CodexChatConfigurationActivity(title: "Loaded access profiles", detail: "\(profiles.count) app-server profiles")
    }

    @discardableResult
    public mutating func refreshPermissionProfiles(
        using codex: Codex,
        errorMessage: (Error) -> String
    ) async -> CodexChatConfigurationActivity {
        do {
            return applyPermissionProfileResponse(try CodexJSONValue(encoding: await codex.permissionProfileList()))
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
        approvalOptions = CodexApprovalSelection.defaultOptions
        return CodexChatConfigurationActivity(title: "Access profiles unavailable", detail: message)
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
            return applyCollaborationModeResponse(try CodexJSONValue(encoding: await codex.collaborationModeList()))
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
    public mutating func applyModelResponse(_ response: ModelListResponse) -> CodexChatConfigurationActivity {
        let options = CodexModelSelection.options(from: response)
        guard !options.isEmpty else {
            modelOptions = CodexModelSelection.defaultOptions
            selectModel(.appServerDefault)
            return CodexChatConfigurationActivity(title: "Model list empty", detail: "Using app-server default model")
        }

        modelOptions = options
        selectModel(selectedModel(from: options))
        return CodexChatConfigurationActivity(title: "Loaded models", detail: "\(options.count) app-server models")
    }

    @discardableResult
    public mutating func refreshModelOptions(
        using codex: Codex,
        errorMessage: (Error) -> String
    ) async -> CodexChatConfigurationActivity {
        do {
            return applyModelResponse(try await codex.models(includeHidden: false))
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
            return applySlashCommandResponse(try CodexJSONValue(encoding: await codex.skillsList(cwds: cwds, forceReload: forceReload)))
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
