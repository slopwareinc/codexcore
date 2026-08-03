import Foundation

public struct CodexComposerReasoningMenuItem: Identifiable, Equatable, Sendable {
    public var selection: CodexReasoningSelection
    public var title: String
    public var isSelected: Bool

    public var id: CodexReasoningSelection { selection }

    public init(selection: CodexReasoningSelection, title: String, isSelected: Bool) {
        self.selection = selection
        self.title = title
        self.isSelected = isSelected
    }
}

public struct CodexComposerModelMenuItem: Identifiable, Equatable, Sendable {
    public var selection: CodexModelSelection
    public var title: String
    public var detail: String?
    public var isSelected: Bool

    public var id: String { selection.id }

    public init(selection: CodexModelSelection, title: String, detail: String?, isSelected: Bool) {
        self.selection = selection
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
    }
}

public enum CodexComposerSpeedMenuItemKind: String, Equatable, Sendable {
    case standard
    case fast
}

public struct CodexComposerSpeedMenuItem: Identifiable, Equatable, Sendable {
    public var kind: CodexComposerSpeedMenuItemKind
    public var title: String
    public var detail: String
    public var selection: CodexModelSelection?
    public var isSelected: Bool
    public var isEnabled: Bool

    public var id: CodexComposerSpeedMenuItemKind { kind }

    public init(
        kind: CodexComposerSpeedMenuItemKind,
        title: String,
        detail: String,
        selection: CodexModelSelection?,
        isSelected: Bool,
        isEnabled: Bool
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.selection = selection
        self.isSelected = isSelected
        self.isEnabled = isEnabled
    }
}

public struct CodexComposerModelMenuState: Equatable, Sendable {
    public var displayTitle: String
    public var reasoningTitle: String
    public var reasoningItems: [CodexComposerReasoningMenuItem]
    public var gptFamilyTitle: String
    public var gptFamilyItems: [CodexComposerModelMenuItem]
    public var speedTitle: String
    public var speedItems: [CodexComposerSpeedMenuItem]

    public init(
        displayTitle: String,
        reasoningTitle: String,
        reasoningItems: [CodexComposerReasoningMenuItem],
        gptFamilyTitle: String,
        gptFamilyItems: [CodexComposerModelMenuItem],
        speedTitle: String,
        speedItems: [CodexComposerSpeedMenuItem]
    ) {
        self.displayTitle = displayTitle
        self.reasoningTitle = reasoningTitle
        self.reasoningItems = reasoningItems
        self.gptFamilyTitle = gptFamilyTitle
        self.gptFamilyItems = gptFamilyItems
        self.speedTitle = speedTitle
        self.speedItems = speedItems
    }
}

public enum CodexComposerModelMenuModel {
    public static func state(
        modelOptions: [CodexModelSelection],
        selectedModel: CodexModelSelection,
        selectedReasoning: CodexReasoningSelection
    ) -> CodexComposerModelMenuState {
        let options = modelOptions.isEmpty ? CodexModelSelection.defaultOptions : modelOptions
        let fastOptions = options.filter(isSpeedModel)
        let gptOptions = options.filter { !isSpeedModel($0) }
        let standardOptions = gptOptions.isEmpty ? options : gptOptions
        let standardSelection = standardOptions.first(where: { $0.id == selectedModel.id }) ?? standardOptions.first
        let fastSelection = fastOptions.first(where: { $0.id == selectedModel.id }) ?? fastOptions.first
        let supportedReasoning = selectedModel.supportedReasoning.isEmpty
            ? CodexReasoningSelection.defaultOptions
            : selectedModel.supportedReasoning

        return CodexComposerModelMenuState(
            displayTitle: "\(selectedModel.displayName) \(selectedReasoning.displayName)",
            reasoningTitle: "Reasoning",
            reasoningItems: supportedReasoning.map {
                CodexComposerReasoningMenuItem(selection: $0, title: $0.displayName, isSelected: $0 == selectedReasoning)
            },
            gptFamilyTitle: standardSelection?.displayName ?? "GPT",
            gptFamilyItems: standardOptions.map {
                CodexComposerModelMenuItem(
                    selection: $0,
                    title: $0.displayName,
                    detail: $0.detail,
                    isSelected: $0.id == selectedModel.id
                )
            },
            speedTitle: "Speed",
            speedItems: [
                CodexComposerSpeedMenuItem(
                    kind: .standard,
                    title: "Standard",
                    detail: "Default speed",
                    selection: standardSelection,
                    isSelected: !isSpeedModel(selectedModel),
                    isEnabled: standardSelection != nil
                ),
                CodexComposerSpeedMenuItem(
                    kind: .fast,
                    title: "Fast",
                    detail: "1.5x speed, increased usage",
                    selection: fastSelection,
                    isSelected: isSpeedModel(selectedModel),
                    isEnabled: fastSelection != nil
                )
            ]
        )
    }

    public static func reconciledReasoning(
        _ current: CodexReasoningSelection,
        for model: CodexModelSelection
    ) -> CodexReasoningSelection {
        let supported = model.supportedReasoning.isEmpty ? CodexReasoningSelection.defaultOptions : model.supportedReasoning
        if supported.contains(current) { return current }
        if let defaultReasoning = model.defaultReasoning, supported.contains(defaultReasoning) {
            return defaultReasoning
        }
        return supported.first ?? .medium
    }

    private static func isSpeedModel(_ option: CodexModelSelection) -> Bool {
        option.isFastModel
            || option.id.localizedCaseInsensitiveContains("speed")
            || option.modelIdentifier?.localizedCaseInsensitiveContains("speed") == true
            || option.displayName.localizedCaseInsensitiveContains("speed")
            || option.serviceTiers.contains(where: {
                $0.id.localizedCaseInsensitiveContains("fast")
                    || $0.displayName.localizedCaseInsensitiveContains("fast")
            })
    }
}
