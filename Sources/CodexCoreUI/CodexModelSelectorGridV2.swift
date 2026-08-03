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
        let orderedOptions = options.enumerated().sorted { lhs, rhs in
            if lhs.element.isDefault != rhs.element.isDefault {
                return lhs.element.isDefault && !rhs.element.isDefault
            }
            let lhsFast = Self.isSpeedModel(lhs.element)
            let rhsFast = Self.isSpeedModel(rhs.element)
            if lhsFast != rhsFast { return !lhsFast && rhsFast }
            if let ordering = Self.compareGeneration(lhs.element, rhs.element), ordering != .orderedSame {
                return ordering == .orderedDescending
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        let columns: [Column] = orderedOptions.compactMap { model -> Column? in
            let family = Self.family(for: model)
            guard seen.insert(family.id).inserted else { return nil }
            return Column(id: family.id, title: model.displayName, model: model, appearance: family.appearance)
        }
        let efforts = Self.efforts(for: columns.map(\.model))
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
        self.columns = columns
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

    private static func efforts(for models: [CodexModelSelection]) -> [CodexReasoningSelection] {
        var supported = Set<CodexReasoningSelection>()
        for model in models {
            supported.formUnion(supportedEfforts(for: model))
        }
        let canonical = orderedEfforts.filter(supported.contains)
        let catalogOnly = CodexReasoningSelection.allCases.filter {
            supported.contains($0) && !orderedEfforts.contains($0)
        }
        return canonical + catalogOnly
    }

    public static func appearance(for model: CodexModelSelection) -> Column.Appearance {
        family(for: model).appearance
    }

    private static func family(for model: CodexModelSelection) -> (id: String, appearance: Column.Appearance) {
        let displayName = model.displayName
            .lowercased()
            .replacingOccurrences(of: "speed", with: "")
            .replacingOccurrences(of: "fast", with: "")
        let meaningfulTokens = displayName
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            .filter { token in
                !token.isEmpty
                    && token != "gpt"
                    && token != "codex"
                    && token.range(of: #"^\d+(?:\.\d+)*$"#, options: .regularExpression) == nil
            }
        let identifier = if meaningfulTokens.count > 1, let token = meaningfulTokens.last {
            String(token)
        } else {
            (model.modelIdentifier ?? model.id)
                .lowercased()
                .replacingOccurrences(of: "-speed", with: "")
        }
        let appearance: Column.Appearance
        switch identifier {
        case "sol": appearance = .sol
        case "terra": appearance = .terra
        case "luna": appearance = .luna
        default: appearance = .generic
        }
        return (identifier, appearance)
    }

    public static func isCurrentGeneration(_ model: CodexModelSelection, among options: [CodexModelSelection]) -> Bool {
        guard let generation = generationKey(for: options.first(where: \.isDefault) ?? options.first) else {
            return options.contains(where: \.isDefault) ? model.isDefault : true
        }
        return generationKey(for: model) == generation
    }

    public static func currentGenerationOptions(
        from options: [CodexModelSelection]
    ) -> [CodexModelSelection] {
        options.filter { isCurrentGeneration($0, among: options) }
    }

    private static func isSpeedModel(_ model: CodexModelSelection) -> Bool {
        model.isFastModel
            || model.id.localizedCaseInsensitiveContains("speed")
            || model.modelIdentifier?.localizedCaseInsensitiveContains("speed") == true
            || model.displayName.localizedCaseInsensitiveContains("speed")
            || model.serviceTiers.contains(where: {
                $0.id.localizedCaseInsensitiveContains("fast")
                    || $0.displayName.localizedCaseInsensitiveContains("fast")
            })
    }

    private static func generationKey(for model: CodexModelSelection?) -> [Int]? {
        guard let model else { return nil }
        let searchable = "\(model.displayName) \(model.id) \(model.modelIdentifier ?? "")"
        guard let match = searchable.range(
            of: #"\d+(?:\.\d+)+"#,
            options: .regularExpression
        ) else { return nil }
        return searchable[match]
            .split(separator: ".")
            .compactMap { Int($0) }
    }

    private static func compareGeneration(
        _ lhs: CodexModelSelection,
        _ rhs: CodexModelSelection
    ) -> ComparisonResult? {
        guard let left = generationKey(for: lhs), let right = generationKey(for: rhs) else {
            return nil
        }
        for (leftPart, rightPart) in zip(left, right) where leftPart != rightPart {
            return leftPart < rightPart ? .orderedAscending : .orderedDescending
        }
        if left.count != right.count {
            return left.count < right.count ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
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
                Text("Models")
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
        column.title
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
    @Binding public var isPresented: Bool
    @State private var showOlderModels = false

    public init(
        model: Binding<CodexModelSelection>,
        modelOptions: [CodexModelSelection],
        serviceTier: Binding<CodexServiceTierSelection> = .constant(.standard),
        reasoning: Binding<CodexReasoningSelection>,
        isPresented: Binding<Bool> = .constant(false)
    ) {
        self._model = model
        self.modelOptions = modelOptions
        self._serviceTier = serviceTier
        self._reasoning = reasoning
        self._isPresented = isPresented
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
        let current = CodexModelGridV2.currentGenerationOptions(from: availableOptions)
        return current.isEmpty ? availableOptions : current
    }

    private var gridModel: CodexModelGridV2 {
        CodexModelGridV2(modelOptions: visibleOptions, selectedModel: model, selectedReasoning: reasoning)
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

#Preview("Catalog model grid") {
    let efforts = CodexModelGridV2.orderedEfforts
    let sol = CodexModelSelection(id: "catalog-sol", displayName: "Catalog Sol", isDefault: true, defaultReasoning: .medium, supportedReasoning: efforts)
    let terra = CodexModelSelection(id: "catalog-terra", displayName: "Catalog Terra", defaultReasoning: .medium, supportedReasoning: [.low, .medium, .high, .extraHigh])
    let luna = CodexModelSelection(id: "catalog-luna", displayName: "Catalog Luna", defaultReasoning: .high, supportedReasoning: efforts)
    CodexModelSelectorGridV2(model: .init(modelOptions: [sol, terra, luna], selectedModel: sol, selectedReasoning: .medium)) { _, _ in }
        .padding()
        .frame(width: 520)
}
