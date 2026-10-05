import AppKit

struct CodexTranscriptTurnMinimapEntry: Equatable {
    var turnID: String
    var targetItemID: CodexTranscriptRenderItemID
    var title: String
    var detail: String
}

enum CodexTranscriptTurnMinimapProjection {
    static func entries(
        presentation: CodexThreadUIPresentation,
        snapshot: CodexTranscriptRenderSnapshot
    ) -> [CodexTranscriptTurnMinimapEntry] {
        var firstItemByTurnID: [String: CodexTranscriptRenderItemID] = [:]
        for itemID in snapshot.orderedItemIDs {
            guard let turnID = snapshot.itemsByID[itemID]?.turnID,
                  firstItemByTurnID[turnID] == nil else { continue }
            firstItemByTurnID[turnID] = itemID
        }
        return presentation.transcript.turns.enumerated().compactMap { index, turn in
            guard let targetItemID = firstItemByTurnID[turn.id] else { return nil }
            return CodexTranscriptTurnMinimapEntry(
                turnID: turn.id,
                targetItemID: targetItemID,
                title: previewText(
                    turn.userMessage?.displayText
                        ?? turn.steeredMessages.first?.displayText
                        ?? "Turn \(index + 1)",
                    limit: 110
                ),
                detail: previewText(
                    turn.finalAnswer?.text
                        ?? turn.liveTail
                        ?? latestAssistantText(in: turn)
                        ?? statusText(turn.status),
                    limit: 520,
                    collapsesWhitespace: false
                )
            )
        }
    }

    private static func latestAssistantText(in turn: CodexTurnV2) -> String? {
        for segment in turn.conversationSegments.reversed() {
            for entry in segment.narrative.reversed() {
                switch entry {
                case .prose(let prose) where !prose.text.isEmpty:
                    return prose.text
                case .notice(let notice) where !notice.message.isEmpty:
                    return notice.message
                case .workGroup(let group) where !group.header.isEmpty:
                    return group.header
                case .inlineActivity(let activity) where !activity.label.isEmpty:
                    return activity.label
                case .structuredCard(let card) where !card.title.isEmpty:
                    return card.title
                case .approvalReview(let review) where !review.title.isEmpty:
                    return review.title
                case .hookActivity(let hook) where !hook.label.isEmpty:
                    return hook.label
                case .recovery(let recovery) where !recovery.message.isEmpty:
                    return recovery.message
                case .productToolCall, .inlineActivity, .prose, .notice, .workGroup,
                     .structuredCard, .approvalReview, .hookActivity, .recovery:
                    continue
                }
            }
        }
        return nil
    }

    private static func statusText(_ status: CodexTurnStatusV2) -> String {
        switch status {
        case .working:
            "Working…"
        case .done:
            "Completed"
        case .failed(let message):
            status.interruption.map { interruption in
                let elapsed = interruption.durationMs.map { " after " + CodexWorkBlockViewV2.duration($0) } ?? ""
                return "Interrupted\(elapsed)"
            } ?? message
        }
    }

    private static func previewText(
        _ text: String,
        limit: Int,
        collapsesWhitespace: Bool = true
    ) -> String {
        let normalized = collapsesWhitespace
            ? text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            : text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

enum CodexTranscriptTurnVisibilityProjection {
    static func visibleTurnIDs(
        entries: [CodexTranscriptTurnMinimapEntry],
        targetYByTurnID: [String: CGFloat],
        contentHeight: CGFloat,
        viewport: NSRect
    ) -> Set<String> {
        let visibleMinY = max(0, viewport.minY)
        let visibleMaxY = min(contentHeight, viewport.maxY)
        guard visibleMaxY > visibleMinY else { return [] }

        var result: Set<String> = []
        for (index, entry) in entries.enumerated() {
            guard let turnMinY = targetYByTurnID[entry.turnID] else { continue }
            let turnMaxY: CGFloat
            if entries.indices.contains(index + 1),
               let nextMinY = targetYByTurnID[entries[index + 1].turnID] {
                turnMaxY = nextMinY
            } else {
                turnMaxY = contentHeight
            }
            if turnMinY < visibleMaxY, turnMaxY > visibleMinY {
                result.insert(entry.turnID)
            }
        }
        return result
    }
}

@MainActor
final class CodexTranscriptTurnMinimapView: NSView {
    private var controlsByTurnID: [String: CodexTranscriptTurnMarkerControl] = [:]
    private var entries: [CodexTranscriptTurnMinimapEntry] = []
    private var visibleTurnIDs: Set<String> = []
    private var hoveredTurnID: String?

    var onSelect: ((CodexTranscriptTurnMinimapEntry) -> Void)?
    var onHover: ((CodexTranscriptTurnMinimapEntry?, NSView?) -> Void)?

    override var isFlipped: Bool { true }

    func configure(
        entries: [CodexTranscriptTurnMinimapEntry],
        visibleTurnIDs: Set<String>,
        theme: CodexTranscriptAppKitTheme
    ) {
        self.entries = entries
        self.visibleTurnIDs = visibleTurnIDs

        let liveTurnIDs = Set(entries.map(\.turnID))
        let staleTurnIDs = controlsByTurnID.keys.filter { !liveTurnIDs.contains($0) }
        for turnID in staleTurnIDs {
            controlsByTurnID.removeValue(forKey: turnID)?.removeFromSuperview()
        }
        for entry in entries {
            let control = controlsByTurnID[entry.turnID] ?? makeControl(for: entry)
            control.entry = entry
            control.isVisible = visibleTurnIDs.contains(entry.turnID)
            control.markerColor = theme.textTertiary
            control.activeColor = theme.textPrimary
            control.setAccessibilityLabel("Jump to turn: \(entry.title)")
            control.setAccessibilityHelp(entry.detail)
            control.setAccessibilityIdentifier("transcript-turn-marker-\(entry.turnID)")
        }
        if let hoveredTurnID, !liveTurnIDs.contains(hoveredTurnID) {
            self.hoveredTurnID = nil
        }
        updateHoverMount()
        needsLayout = true
    }

    func setVisibleTurnIDs(_ turnIDs: Set<String>) {
        guard visibleTurnIDs != turnIDs else { return }
        let changedTurnIDs = visibleTurnIDs.symmetricDifference(turnIDs)
        visibleTurnIDs = turnIDs
        for turnID in changedTurnIDs {
            controlsByTurnID[turnID]?.isVisible = turnIDs.contains(turnID)
        }
    }

    override func layout() {
        super.layout()
        guard !entries.isEmpty else { return }
        let slotHeight = bounds.height / CGFloat(entries.count)
        for (index, entry) in entries.enumerated() {
            guard let control = controlsByTurnID[entry.turnID] else { continue }
            control.frame = NSRect(
                x: 0,
                y: CGFloat(index) * slotHeight,
                width: bounds.width,
                height: max(1, slotHeight)
            )
            control.lineCenterY = slotHeight / 2
        }
    }

    private func makeControl(
        for entry: CodexTranscriptTurnMinimapEntry
    ) -> CodexTranscriptTurnMarkerControl {
        let control = CodexTranscriptTurnMarkerControl()
        control.entry = entry
        control.target = self
        control.action = #selector(selectMarker(_:))
        control.onHover = { [weak self, weak control] isHovered in
            guard let self, let control else { return }
            if isHovered {
                self.setHoveredTurnID(control.entry.turnID)
            }
            self.onHover?(isHovered ? control.entry : nil, isHovered ? control : nil)
        }
        control.setAccessibilityElement(true)
        control.setAccessibilityRole(.button)
        addSubview(control)
        controlsByTurnID[entry.turnID] = control
        return control
    }

    @objc private func selectMarker(_ sender: CodexTranscriptTurnMarkerControl) {
        onSelect?(sender.entry)
    }

    var entriesForTesting: [CodexTranscriptTurnMinimapEntry] { entries }
    var visibleTurnIDsForTesting: Set<String> { visibleTurnIDs }
    func markerForTesting(turnID: String) -> NSView? { controlsByTurnID[turnID] }
    func markerIsVisibleForTesting(turnID: String) -> Bool? {
        controlsByTurnID[turnID]?.isVisible
    }
    func markerLineWidthForTesting(turnID: String) -> CGFloat? {
        controlsByTurnID[turnID]?.lineWidth
    }
    func hoverMountInfluenceForTesting(turnID: String) -> CGFloat? {
        controlsByTurnID[turnID]?.hoverMountInfluence
    }
    func setHoveredTurnIDForTesting(_ turnID: String?) {
        setHoveredTurnID(turnID)
    }
    func preferredHeight(maximum: CGFloat) -> CGFloat {
        min(maximum, CGFloat(entries.count) * 11)
    }

    func clearHoverMount() {
        setHoveredTurnID(nil)
    }

    private func setHoveredTurnID(_ turnID: String?) {
        guard hoveredTurnID != turnID else { return }
        hoveredTurnID = turnID
        updateHoverMount()
    }

    private func updateHoverMount() {
        guard let hoveredTurnID,
              let hoveredIndex = entries.firstIndex(where: { $0.turnID == hoveredTurnID }) else {
            controlsByTurnID.values.forEach { $0.hoverMountInfluence = 0 }
            return
        }

        // A Gaussian falloff makes the rail rise as one continuous mount instead
        // of turning a single tick into an unrelated long line.
        let sigma: CGFloat = 1.35
        for (index, entry) in entries.enumerated() {
            let distance = CGFloat(abs(index - hoveredIndex))
            let influence = exp(-0.5 * pow(distance / sigma, 2))
            controlsByTurnID[entry.turnID]?.hoverMountInfluence =
                influence < 0.025 ? 0 : influence
        }
    }

}

@MainActor
private final class CodexTranscriptTurnMarkerControl: NSControl {
    var entry = CodexTranscriptTurnMinimapEntry(
        turnID: "",
        targetItemID: .init(rawValue: ""),
        title: "",
        detail: ""
    )
    var markerColor = NSColor.tertiaryLabelColor { didSet { needsDisplay = true } }
    var activeColor = NSColor.secondaryLabelColor { didSet { needsDisplay = true } }
    var isVisible = false { didSet { needsDisplay = true } }
    var hoverMountInfluence: CGFloat = 0 { didSet { needsDisplay = true } }
    var lineCenterY: CGFloat = 0 { didSet { needsDisplay = true } }
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(next)
        trackingArea = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    var lineWidth: CGFloat {
        10 + (20 * hoverMountInfluence)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let lineHeight = 2 + (0.7 * hoverMountInfluence)
        let line = NSRect(
            x: 0,
            y: lineCenterY - lineHeight / 2,
            width: min(lineWidth, bounds.width),
            height: lineHeight
        )
        (isVisible || hoverMountInfluence > 0 ? activeColor : markerColor)
            .withAlphaComponent(
                isVisible ? 0.96 : 0.42 + (0.42 * hoverMountInfluence)
            )
            .setFill()
        NSBezierPath(
            roundedRect: line,
            xRadius: lineHeight / 2,
            yRadius: lineHeight / 2
        ).fill()
    }
}

@MainActor
final class CodexTranscriptTurnPreviewView: NSView {
    private let glassSurface: NSView
    private let glassContent = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var isPointerInside = false
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 18
            glass.contentView = glassContent
            glassSurface = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .withinWindow
            material.state = .active
            glassSurface = material
        }
        super.init(frame: frameRect)
        if !(glassSurface is NSGlassEffectView) {
            glassSurface.wantsLayer = true
            glassSurface.layer?.cornerRadius = 18
            glassSurface.layer?.masksToBounds = true
            glassSurface.addSubview(glassContent)
        }
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        detailLabel.maximumNumberOfLines = 6
        detailLabel.lineBreakMode = .byTruncatingTail
        glassContent.addSubview(titleLabel)
        glassContent.addSubview(detailLabel)
        addSubview(glassSurface)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        entry: CodexTranscriptTurnMinimapEntry,
        theme: CodexTranscriptAppKitTheme
    ) {
        titleLabel.stringValue = entry.title
        titleLabel.font = NSFont.systemFont(
            ofSize: max(12, theme.bodyFont.pointSize - 1),
            weight: .medium
        )
        titleLabel.textColor = theme.textPrimary
        detailLabel.font = theme.captionFont
        detailLabel.textColor = theme.textSecondary
        detailLabel.attributedStringValue =
            CodexTranscriptRenderProjector.prepareMinimapPreviewMarkdown(
                entry.detail,
                theme: theme
            )
        if #available(macOS 26.0, *),
           let glass = glassSurface as? NSGlassEffectView {
            glass.tintColor = theme.surfaceSunken.withAlphaComponent(0.12)
        }
        setAccessibilityLabel(entry.title)
        setAccessibilityHelp(entry.detail)
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        let detailWidth = max(1, width - 24)
        let detailHeight = min(
            102,
            ceil(detailLabel.attributedStringValue.boundingRect(
                with: NSSize(width: detailWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height)
        )
        return max(86, 52 + detailHeight)
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(next)
        trackingArea = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        onHoverChanged?(false)
    }

    override func layout() {
        super.layout()
        glassSurface.frame = bounds
        glassContent.frame = glassSurface.bounds
        titleLabel.frame = NSRect(x: 16, y: bounds.height - 38, width: bounds.width - 32, height: 20)
        detailLabel.frame = NSRect(x: 16, y: 13, width: bounds.width - 32, height: bounds.height - 52)
    }

    var usesNativeLiquidGlassForTesting: Bool {
        if #available(macOS 26.0, *) {
            return glassSurface is NSGlassEffectView
        }
        return false
    }
}
