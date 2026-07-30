import SwiftUI

public enum CodexComposerModelPickerStyle: Sendable {
    case menu
    case grid
}

public struct CodexModelGridV2: Equatable, Sendable {
    public struct Column: Identifiable, Equatable, Sendable {
        public enum Appearance: String, Equatable, Sendable {
            case sol, terra, luna, generic
        }

        public var id: String
        public var title: String
        public var model: CodexModelSelection
        public var appearance: Appearance

        public init(id: String, title: String, model: CodexModelSelection, appearance: Appearance) {
            self.id = id
            self.title = title
            self.model = model
            self.appearance = appearance
        }
    }

    public struct Cell: Identifiable, Equatable, Sendable {
        public var columnID: String
        public var modelID: String
        public var effort: CodexReasoningSelection
        public var isEnabled: Bool
        public var isSelected: Bool
        public var id: String { "\(columnID):\(effort.rawValue)" }

        public init(columnID: String, modelID: String, effort: CodexReasoningSelection, isEnabled: Bool, isSelected: Bool) {
            self.columnID = columnID
            self.modelID = modelID
            self.effort = effort
            self.isEnabled = isEnabled
            self.isSelected = isSelected
        }
    }

    public static let orderedEfforts: [CodexReasoningSelection] = [.low, .medium, .high, .extraHigh, .maximum, .ultra]

    public var columns: [Column]
    public var efforts: [CodexReasoningSelection]
    public var cells: [Cell]
    public var selectedModel: CodexModelSelection
    public var selectedReasoning: CodexReasoningSelection
    public var fastModel: CodexModelSelection?
    public var standardModel: CodexModelSelection?

    public init(
        modelOptions: [CodexModelSelection],
        selectedModel: CodexModelSelection,
        selectedReasoning: CodexReasoningSelection
    ) {
        let options = modelOptions.isEmpty ? CodexModelSelection.defaultOptions : modelOptions
        var seen = Set<String>()
        let orderedOptions = options.sorted { lhs, rhs in
            let lhs56 = lhs.displayName.lowercased().contains("5.6") || lhs.id.lowercased().contains("5.6")
            let rhs56 = rhs.displayName.lowercased().contains("5.6") || rhs.id.lowercased().contains("5.6")
            if lhs56 != rhs56 { return lhs56 && !rhs56 }
            return options.firstIndex(where: { $0.id == lhs.id })! < options.firstIndex(where: { $0.id == rhs.id })!
        }
        let columns: [Column] = orderedOptions.compactMap { model -> Column? in
            let family = Self.family(for: model)
            guard seen.insert(family.id).inserted else { return nil }
            return Column(id: family.id, title: model.displayName, model: model, appearance: family.appearance)
        }
        let efforts = Self.orderedEfforts.filter { effort in
            columns.contains { Self.supportedEfforts(for: $0.model).contains(effort) }
        }
        let cells = columns.flatMap { column in
            let supported = Self.supportedEfforts(for: column.model)
            return efforts.map { effort in
                Cell(
                    columnID: column.id,
                    modelID: column.model.id,
                    effort: effort,
                    isEnabled: supported.contains(effort),
                    isSelected: column.model.id == selectedModel.id && effort == selectedReasoning
                )
            }
        }
        let appearanceOrder: [Column.Appearance] = [.sol, .terra, .luna, .generic]
        self.columns = columns.sorted {
            let left = appearanceOrder.firstIndex(of: $0.appearance) ?? appearanceOrder.count
            let right = appearanceOrder.firstIndex(of: $1.appearance) ?? appearanceOrder.count
            return left == right ? $0.title < $1.title : left < right
        }
        self.efforts = efforts
        self.cells = cells
        self.selectedModel = selectedModel
        self.selectedReasoning = selectedReasoning
        self.fastModel = options.first(where: {
            $0.isFastModel || $0.id.localizedCaseInsensitiveContains("speed")
                || $0.modelIdentifier?.localizedCaseInsensitiveContains("speed") == true
                || $0.displayName.localizedCaseInsensitiveContains("speed")
        })
        self.standardModel = options.first(where: {
            !($0.isFastModel || $0.id.localizedCaseInsensitiveContains("speed")
                || $0.modelIdentifier?.localizedCaseInsensitiveContains("speed") == true
                || $0.displayName.localizedCaseInsensitiveContains("speed"))
        })
    }

    public func cell(columnID: String, effort: CodexReasoningSelection) -> Cell? {
        cells.first { $0.columnID == columnID && $0.effort == effort }
    }

    public func selection(for cell: Cell) -> (modelID: String, reasoningEffort: CodexReasoningSelection)? {
        cell.isEnabled ? (cell.modelID, cell.effort) : nil
    }

    private static func supportedEfforts(for model: CodexModelSelection) -> [CodexReasoningSelection] {
        model.supportedReasoning.isEmpty ? CodexReasoningSelection.defaultOptions : model.supportedReasoning
    }

    public static func appearance(for model: CodexModelSelection) -> Column.Appearance {
        family(for: model).appearance
    }

    private static func family(for model: CodexModelSelection) -> (id: String, appearance: Column.Appearance) {
        let searchable = "\(model.id) \(model.modelIdentifier ?? "") \(model.displayName)".lowercased()
        if searchable.contains("sol") { return ("sol", .sol) }
        if searchable.contains("terra") { return ("terra", .terra) }
        if searchable.contains("luna") { return ("luna", .luna) }
        let generic = (model.modelIdentifier ?? model.id).lowercased()
            .replacingOccurrences(of: "-speed", with: "")
        return (generic, .generic)
    }
}

public struct CodexModelSelectorGridV2: View {
    @Environment(\.codexAgentTheme) private var theme

    public let model: CodexModelGridV2
    public let onSelect: (String, CodexReasoningSelection) -> Void

    public init(model: CodexModelGridV2, onSelect: @escaping (String, CodexReasoningSelection) -> Void) {
        self.model = model
        self.onSelect = onSelect
    }

    public var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 5) {
            GridRow {
                Text(model.columns.allSatisfy { isCurrentGeneration($0.model) } ? "GPT 5.6" : "Models")
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 46, alignment: .leading)
                ForEach(model.columns) { column in
                    Label(shortTitle(for: column), systemImage: icon(for: column.appearance))
                        .font(theme.fonts.caption.weight(.semibold))
                        .foregroundStyle(tint(for: column.appearance))
                        .lineLimit(1)
                        .frame(minWidth: 76)
                }
            }

            ForEach(model.efforts) { effort in
                GridRow {
                    Text(effort.displayName)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: 42, alignment: .trailing)
                    ForEach(model.columns) { column in
                        if let cell = model.cell(columnID: column.id, effort: effort) {
                            cellButton(cell, appearance: column.appearance)
                        }
                    }
                }
            }
        }
        .padding(4)
        .background(theme.colors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous).stroke(theme.colors.border))
    }

    private func cellButton(_ cell: CodexModelGridV2.Cell, appearance: CodexModelGridV2.Column.Appearance) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
        return Button { onSelect(cell.modelID, cell.effort) } label: {
            ZStack {
                shape.fill(tint(for: appearance).opacity(cell.isEnabled ? shade(for: cell.effort) : 0.04))
                if cell.isSelected {
                    Image(systemName: "checkmark")
                        .font(theme.fonts.caption.weight(.bold))
                        .foregroundStyle(theme.colors.textPrimary)
                }
            }
            .frame(minWidth: 76, minHeight: 24)
            .overlay(shape.stroke(cell.isSelected ? theme.colors.borderStrong : theme.colors.border.opacity(0.55), lineWidth: cell.isSelected ? 2 : 1))
            .opacity(cell.isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!cell.isEnabled)
        .accessibilityLabel("\(cell.modelID), \(cell.effort.displayName)")
    }

    private func icon(for appearance: CodexModelGridV2.Column.Appearance) -> String {
        switch appearance { case .sol: "sun.max.fill"; case .terra: "leaf.fill"; case .luna: "moon.fill"; case .generic: "sparkles" }
    }

    private func shortTitle(for column: CodexModelGridV2.Column) -> String {
        guard isCurrentGeneration(column.model) else { return column.title }
        return switch column.appearance {
        case .sol: "Sol"
        case .terra: "Terra"
        case .luna: "Luna"
        case .generic: "GPT 5.6"
        }
    }

    private func isCurrentGeneration(_ model: CodexModelSelection) -> Bool {
        let searchable = "\(model.id) \(model.modelIdentifier ?? "") \(model.displayName)"
        return searchable.range(of: #"\b5\.6\b"#, options: .regularExpression) != nil
    }

    private func tint(for appearance: CodexModelGridV2.Column.Appearance) -> Color {
        switch appearance { case .sol: .orange; case .terra: .green; case .luna: .indigo; case .generic: theme.colors.accent }
    }

    private func shade(for effort: CodexReasoningSelection) -> Double {
        switch effort {
        case .low: 0.16
        case .medium: 0.25
        case .high: 0.36
        case .extraHigh: 0.49
        case .maximum: 0.57
        case .ultra: 0.65
        default: 0.1
        }
    }
}

public struct ComposerModelGridPicker: View {
    @Environment(\.codexAgentTheme) private var theme
    @Binding public var model: CodexModelSelection
    public let modelOptions: [CodexModelSelection]
    @Binding public var serviceTier: CodexServiceTierSelection
    @Binding public var reasoning: CodexReasoningSelection
    @State private var isPresented = false
    @State private var showOlderModels = false

    public init(
        model: Binding<CodexModelSelection>,
        modelOptions: [CodexModelSelection],
        serviceTier: Binding<CodexServiceTierSelection> = .constant(.standard),
        reasoning: Binding<CodexReasoningSelection>
    ) {
        self._model = model
        self.modelOptions = modelOptions
        self._serviceTier = serviceTier
        self._reasoning = reasoning
    }

    public var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 7) {
                Text("\(model.displayName) \(reasoning.displayName)")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(theme.fonts.micro)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(modelTint)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show older models", isOn: $showOlderModels)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(theme.fonts.caption)
                    .padding(.horizontal, 4)

                if !model.serviceTiers.isEmpty {
                    Picker("Speed", selection: $serviceTier) {
                        Text(CodexServiceTierSelection.standard.displayName)
                            .tag(CodexServiceTierSelection.standard)
                        ForEach(model.serviceTiers) { tier in
                            Text(tier.displayName)
                                .tag(CodexServiceTierSelection.tier(tier))
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .font(theme.fonts.caption)
                    .padding(.horizontal, 4)
                }

                CodexModelSelectorGridV2(model: gridModel) { modelID, effort in
                    guard let selection = availableOptions.first(where: { $0.id == modelID }) else { return }
                    model = selection
                    reasoning = effort
                    let reconciledTier = serviceTier.reconciled(for: selection)
                    if reconciledTier != serviceTier {
                        serviceTier = reconciledTier
                    }
                    isPresented = false
                }
            }
            .padding(6)
        }
        .help("Model and reasoning")
    }

    private var availableOptions: [CodexModelSelection] {
        modelOptions.isEmpty ? CodexModelSelection.defaultOptions : modelOptions
    }

    private var visibleOptions: [CodexModelSelection] {
        guard !showOlderModels else { return availableOptions }
        let current = availableOptions.filter(isCurrentGeneration)
        return current.isEmpty ? availableOptions : current
    }

    private var gridModel: CodexModelGridV2 {
        CodexModelGridV2(modelOptions: visibleOptions, selectedModel: model, selectedReasoning: reasoning)
    }

    private func isCurrentGeneration(_ option: CodexModelSelection) -> Bool {
        let searchable = "\(option.id) \(option.modelIdentifier ?? "") \(option.displayName)"
        return searchable.range(of: #"\b5\.6\b"#, options: .regularExpression) != nil
    }

    private var modelTint: Color {
        switch CodexModelGridV2.appearance(for: model) {
        case .sol: .orange
        case .terra: .green
        case .luna: .indigo
        case .generic: theme.colors.accent
        }
    }
}

#Preview("GPT 5.6 model grid") {
    let efforts = CodexModelGridV2.orderedEfforts
    let sol = CodexModelSelection(id: "gpt-5.6-sol", displayName: "GPT 5.6 Sol", isDefault: true, defaultReasoning: .medium, supportedReasoning: efforts)
    let terra = CodexModelSelection(id: "gpt-5.6-terra", displayName: "GPT 5.6 Terra", defaultReasoning: .medium, supportedReasoning: [.low, .medium, .high, .extraHigh])
    let luna = CodexModelSelection(id: "gpt-5.6-luna", displayName: "GPT 5.6 Luna", defaultReasoning: .high, supportedReasoning: efforts)
    CodexModelSelectorGridV2(model: .init(modelOptions: [sol, terra, luna], selectedModel: sol, selectedReasoning: .medium)) { _, _ in }
        .padding()
        .frame(width: 520)
}
