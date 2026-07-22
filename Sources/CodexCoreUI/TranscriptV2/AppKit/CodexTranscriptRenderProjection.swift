import AppKit
import CodexCore
import Foundation

struct CodexTranscriptRenderItemID: Hashable, Sendable {
    var rawValue: String
}

struct CodexTranscriptColumnMetrics: Sendable, Equatable {
    static let horizontalMargin: CGFloat = 24
    static let flowLayoutHorizontalAllowance: CGFloat = 32
    static let turnGap: CGFloat = 16
    static let itemGap: CGFloat = 4
    static let userBubbleHorizontalPadding: CGFloat = 12
    static let userBubbleVerticalPadding: CGFloat = 8
    static let workHeaderHeight: CGFloat = 22
    static let footerHeight: CGFloat = 22
    static let actionCardHeight: CGFloat = 32
    static let actionCardRadius: CGFloat = 10
    static let interactiveBottomSpacing: CGFloat = 8
    static let scrollableOutputMaxHeight: CGFloat = 220
    static let diffPanelHeight: CGFloat = 240
    static let topContentInset: CGFloat = 0

    var viewportWidth: CGFloat

    // This is only an AppKit flow-layout constraint. Cells position visible
    // content against the preserved full `viewportWidth`, so it is not a gutter.
    var cellWidth: CGFloat { max(1, viewportWidth - Self.flowLayoutHorizontalAllowance) }

    func outerWidth(_ theme: CodexTranscriptAppKitTheme) -> CGFloat {
        min(
            max(1, viewportWidth - Self.horizontalMargin * 2),
            theme.transcriptOuterMaxWidth
        )
    }

    func contentWidth(
        for policy: CodexTranscriptContentWidthPolicy,
        theme: CodexTranscriptAppKitTheme
    ) -> CGFloat {
        let outerWidth = outerWidth(theme)
        return switch policy {
        case .full: outerWidth
        case .card: min(outerWidth, theme.cardMaxWidth)
        case .user: min(outerWidth * 0.77, theme.userBubbleMaxWidth)
        }
    }
}

enum CodexTranscriptContentWidthPolicy: Sendable, Equatable {
    case full
    case card
    case user
}

enum CodexTranscriptTextRole: Sendable, Equatable {
    case user
    case commentary
    case finalAnswer
    case notice
    case expandedOutput
    case liveTail
    case timestamp
}

enum CodexTranscriptRenderAction: Sendable, Equatable {
    case toggleWork(turnID: String)
    case toggleRow(rowID: String)
    case selectDiffFile(rowID: String, index: Int)
    case openSubagent(threadID: String)
    case openURL(String)
    case openFile(path: String, line: Int?)
    case resolveApproval(requestID: CodexServerRequestKey, approve: Bool)
}

struct CodexTranscriptApprovalRender: Sendable, Equatable {
    var requestID: CodexServerRequestKey
    var summary: String
}

struct CodexTranscriptDirectiveRender: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case createdThread(threadID: String?, pendingWorktreeID: String?)
        case gitAction(verb: String, branch: String?, cwd: String?)
        case pullRequest(url: String, branch: String?, isDraft: Bool)
        case codeComment(title: String, body: String, file: String, start: Int?, end: Int?, priority: Int?)
        case unknown(name: String)
    }

    var kind: Kind
    var raw: String
}

struct CodexTranscriptWorkHeaderRender: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case working(startedAt: Date, showsDuration: Bool)
        case done(durationMs: Int?, isExpanded: Bool)
        case failed(message: String)
    }

    var state: State
}

struct CodexTranscriptWorkRowRender: Sendable, Equatable {
    var kind: CodexWorkRowKind
    var label: String
    var status: CodexWorkItemStatusV2
    var durationMs: Int?
    var isExpanded: Bool
    var hasDetail: Bool
    var isSubagentLink: Bool
    var isActionable: Bool
}

struct CodexTranscriptAgentChipRender: Sendable, Equatable {
    var id: String
    var label: String
    var status: CodexAgentDisplayStatusV2
    var threadID: String?
    var taskSummary: String?
    var latestUpdate: String?
    var attachmentKind: CodexReferencedFile.Kind? = nil
}

struct CodexTranscriptDiffPanelRender: Sendable, Equatable {
    var rowID: String
    var files: [CodexDiffFile]
    var selectedFileIndex: Int

    var selectedFile: CodexDiffFile? {
        guard files.indices.contains(selectedFileIndex) else { return files.first }
        return files[selectedFileIndex]
    }
}

enum CodexWorkRowKind: Sendable, Equatable {
    case command, fileChange, mcp, webSearch, agent, other
}

struct CodexTranscriptCodeRender: Sendable, Equatable {
    var language: String?
    var code: String
}

struct CodexTranscriptFooterRender: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case user
        case finalAnswer
    }

    var kind: Kind
    var timestamp: String
    var isTurnStreaming: Bool
}

final class CodexPreparedTranscriptText: @unchecked Sendable {
    let attributedString: NSAttributedString

    init(_ attributedString: NSAttributedString) {
        self.attributedString = attributedString
    }
}

struct CodexTranscriptRenderItem: @unchecked Sendable {
    var id: CodexTranscriptRenderItemID
    var sectionID: String
    var turnID: String
    var revision: Int
    var textRole: CodexTranscriptTextRole?
    var preparedText: CodexPreparedTranscriptText?
    var workHeader: CodexTranscriptWorkHeaderRender?
    var workRow: CodexTranscriptWorkRowRender?
    var agentChips: [CodexTranscriptAgentChipRender]
    var diffPanel: CodexTranscriptDiffPanelRender?
    var code: CodexTranscriptCodeRender?
    var footer: CodexTranscriptFooterRender?
    var productTool: CodexProductToolCallV2?
    var directive: CodexTranscriptDirectiveRender?
    var approval: CodexTranscriptApprovalRender?
    var action: CodexTranscriptRenderAction?
    var copyText: String?
    var editUserText: String?
    var copyTurnText: String
    var allowsTextSelection: Bool
    var accessibilityLabel: String
    var indentation: CGFloat
    var isTrailingAligned: Bool
    var maxContentWidth: CGFloat
    var contentWidthPolicy: CodexTranscriptContentWidthPolicy
    var intrinsicContentWidth: CGFloat?
    var viewportWidth: CGFloat
    var measuredHeight: CGFloat
    var bottomSpacing: CGFloat
    var isScrollableOutput: Bool
}

struct CodexTranscriptRenderDiagnostics: Sendable, Equatable {
    var projectionCount = 0
    var projectedItemCount = 0
    var changedItemCount = 0
    var heightCacheHitCount = 0
    var heightCacheMissCount = 0
    var preparedTextCacheHitCount = 0
    var preparedTextCacheMissCount = 0
    var markdownProjectionCount = 0
    var projectionDurationMilliseconds: Double = 0
}

struct CodexTranscriptRenderSnapshot: @unchecked Sendable {
    var threadID: String
    var sectionIDs: [String]
    var itemIDsBySection: [String: [CodexTranscriptRenderItemID]]
    var itemsByID: [CodexTranscriptRenderItemID: CodexTranscriptRenderItem]
    var changedItemIDs: Set<CodexTranscriptRenderItemID>
    var diagnostics: CodexTranscriptRenderDiagnostics

    var orderedItemIDs: [CodexTranscriptRenderItemID] {
        sectionIDs.flatMap { itemIDsBySection[$0] ?? [] }
    }
}

struct CodexTranscriptAppKitTheme: @unchecked Sendable {
    var bodyFont: NSFont
    var codeFont: NSFont
    var captionFont: NSFont
    var microFont: NSFont
    var textPrimary: NSColor
    var textSecondary: NSColor
    var textTertiary: NSColor
    var userBubble: NSColor
    var userBubbleStroke: NSColor
    var codeBackground: NSColor
    var codeHeader: NSColor
    var codeText: NSColor
    var codeFaint: NSColor
    var surfaceSunken: NSColor
    var border: NSColor
    var success: NSColor
    var danger: NSColor
    var running: NSColor
    var warning: NSColor
    var accent: NSColor
    var codeKeyword: NSColor
    var codeString: NSColor
    var codeComment: NSColor
    var codeNumber: NSColor
    var bubbleRadius: CGFloat
    var cardRadius: CGFloat
    var lineSpacing: CGFloat
    var cardMaxWidth: CGFloat
    var userBubbleMaxWidth: CGFloat
    var transcriptOuterMaxWidth: CGFloat
    var fingerprint: String

    @MainActor
    init(_ theme: CodexAgentTheme) {
        bodyFont = theme.fonts.chatNSFont ?? .systemFont(ofSize: 15)
        codeFont = theme.fonts.codeNSFont ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        captionFont = .systemFont(ofSize: max(10, bodyFont.pointSize - 2))
        microFont = .monospacedSystemFont(ofSize: max(9, bodyFont.pointSize - 3), weight: .semibold)
        textPrimary = NSColor(theme.colors.textPrimary)
        textSecondary = NSColor(theme.colors.textSecondary)
        textTertiary = NSColor(theme.colors.textTertiary)
        userBubble = NSColor(theme.colors.userBubble)
        userBubbleStroke = NSColor(theme.colors.userBubbleStroke)
        codeBackground = NSColor(theme.colors.codeBackground)
        codeHeader = NSColor(theme.colors.codeHeader)
        codeText = NSColor(theme.colors.codeText)
        codeFaint = NSColor(theme.colors.codeFaint)
        surfaceSunken = NSColor(theme.colors.surfaceSunken)
        border = NSColor(theme.colors.border)
        success = NSColor(theme.colors.success)
        danger = NSColor(theme.colors.danger)
        running = NSColor(theme.colors.running)
        warning = NSColor(theme.colors.warning)
        accent = NSColor(theme.colors.accent)
        codeKeyword = NSColor(theme.colors.codeKeyword)
        codeString = NSColor(theme.colors.codeString)
        codeComment = NSColor(theme.colors.codeComment)
        codeNumber = NSColor(theme.colors.codeNumber)
        bubbleRadius = theme.radii.bubble
        cardRadius = theme.radii.medium
        lineSpacing = theme.spacing.chatLineSpacing
        cardMaxWidth = theme.spacing.cardMaxWidth
        userBubbleMaxWidth = theme.spacing.userBubbleMaxWidth
        transcriptOuterMaxWidth = theme.spacing.transcriptOuterMaxWidth
        fingerprint = [
            bodyFont.fontName, String(describing: bodyFont.pointSize), codeFont.fontName,
            String(describing: codeFont.pointSize), String(describing: textPrimary),
            String(describing: userBubble), String(describing: codeHeader),
            String(describing: codeKeyword), String(describing: codeString),
            String(describing: codeComment), String(describing: codeNumber),
            String(describing: accent), String(describing: warning), String(describing: lineSpacing)
        ].joined(separator: ":")
    }
}

actor CodexTranscriptRenderProjector {
    private struct RevisionState {
        var fingerprint: String
        var revision: Int
    }

    private struct HeightKey: Hashable {
        var id: CodexTranscriptRenderItemID
        var revision: Int
        var widthPixels: Int
        var theme: String
    }

    private var previousBlocksBySourceID: [String: [CodexBlock]] = [:]
    private var sourceTextBySourceID: [String: String] = [:]
    private var revisionByID: [CodexTranscriptRenderItemID: RevisionState] = [:]
    private var heightByKey: [HeightKey: CGFloat] = [:]
    private var preparedTextByKey: [String: CodexPreparedTranscriptText] = [:]
    private var preparedTextInsertionOrder: [String] = []
    private var projectionCount = 0
    private let codeHighlighter: any CodexCodeHighlighter = CodexRegexCodeHighlighter()

    func project(
        presentation: CodexThreadUIPresentation,
        availableWidth: CGFloat,
        theme: CodexTranscriptAppKitTheme
    ) throws -> CodexTranscriptRenderSnapshot {
        try Task.checkCancellation()
        let startedAt = ContinuousClock.now
        let contentWidth = CodexTranscriptColumnMetrics(viewportWidth: availableWidth).outerWidth(theme)
        var sections: [String] = []
        var itemIDsBySection: [String: [CodexTranscriptRenderItemID]] = [:]
        var itemsByID: [CodexTranscriptRenderItemID: CodexTranscriptRenderItem] = [:]
        var changedIDs: Set<CodexTranscriptRenderItemID> = []
        var liveIDs: Set<CodexTranscriptRenderItemID> = []
        var cacheHits = 0
        var cacheMisses = 0
        var preparedTextCacheHits = 0
        var preparedTextCacheMisses = 0
        var markdownProjections = 0

        for turn in presentation.transcript.turns {
            try Task.checkCancellation()
            let sectionID = "\(presentation.threadID):turn:\(turn.id)"
            sections.append(sectionID)
            var sectionItems: [CodexTranscriptRenderItemID] = []
            let copyTurnText = Self.copyText(for: turn)
            let presentedAt = presentation.presentedAtByTurnID[turn.id] ?? Date()
            let turnIsStreaming = Self.isStreaming(turn)

            func append(_ draft: ItemDraft) {
                let id = CodexTranscriptRenderItemID(rawValue: draft.id)
                let allowsTextSelection = draft.footer == nil
                    && (draft.preparedText != nil || draft.code != nil)
                let contentFingerprint = CodexBlockDigest.digest(draft.fingerprint)
                let previous = revisionByID[id]
                let revision: Int
                if previous?.fingerprint == contentFingerprint {
                    revision = previous?.revision ?? 0
                } else {
                    revision = (previous?.revision ?? -1) + 1
                    changedIDs.insert(id)
                }
                revisionByID[id] = RevisionState(fingerprint: contentFingerprint, revision: revision)
                let maxWidth = draft.maxWidth(contentWidth, theme)
                let heightKey = HeightKey(
                    id: id,
                    revision: revision,
                    widthPixels: Int((maxWidth * 2).rounded()),
                    theme: theme.fingerprint
                )
                let measuredHeight: CGFloat
                if let cached = heightByKey[heightKey] {
                    measuredHeight = cached
                    cacheHits += 1
                } else {
                    measuredHeight = Self.measure(draft: draft, width: maxWidth, theme: theme)
                    heightByKey[heightKey] = measuredHeight
                    cacheMisses += 1
                }
                let item = CodexTranscriptRenderItem(
                    id: id,
                    sectionID: sectionID,
                    turnID: turn.id,
                    revision: revision,
                    textRole: draft.textRole,
                    preparedText: draft.preparedText,
                    workHeader: draft.workHeader,
                    workRow: draft.workRow,
                    agentChips: draft.agentChips,
                    diffPanel: draft.diffPanel,
                    code: draft.code,
                    footer: draft.footer,
                    productTool: draft.productTool,
                    directive: draft.directive,
                    approval: draft.approval,
                    action: draft.action,
                    copyText: draft.copyText,
                    editUserText: draft.editUserText,
                    copyTurnText: copyTurnText,
                    allowsTextSelection: allowsTextSelection,
                    accessibilityLabel: draft.accessibilityLabel,
                    indentation: draft.indentation,
                    isTrailingAligned: draft.isTrailingAligned,
                    maxContentWidth: maxWidth,
                    contentWidthPolicy: draft.maxWidthKind,
                    intrinsicContentWidth: draft.intrinsicContentWidth,
                    viewportWidth: availableWidth,
                    measuredHeight: measuredHeight,
                    bottomSpacing: draft.bottomSpacing,
                    isScrollableOutput: draft.isScrollableOutput
                )
                sectionItems.append(id)
                itemsByID[id] = item
                liveIDs.insert(id)
            }

            if let user = turn.userMessage {
                for draft in userMessageDrafts(
                    user,
                    sectionID: sectionID,
                    contentWidth: contentWidth,
                    presentedAt: presentedAt,
                    turnIsStreaming: turnIsStreaming,
                    theme: theme,
                    cacheHits: &preparedTextCacheHits,
                    cacheMisses: &preparedTextCacheMisses
                ) { append(draft) }
            }

            let showsWork = Self.shouldRenderWork(turn)
            let tailMode = Self.isWorkTailMode(turn)
            let workExpanded = Self.workIsExpanded(turn, presentation: presentation)
            if showsWork {
                let header = Self.workHeader(turn, expanded: workExpanded, presentedAt: presentedAt)
                append(ItemDraft(
                    id: "\(sectionID):work-header",
                    fingerprint: "work:\(String(describing: header.state))",
                    workHeader: header,
                    action: Self.workHeaderIsActionable(header) ? .toggleWork(turnID: turn.id) : nil,
                    accessibilityLabel: Self.workHeaderAccessibilityLabel(header),
                    maxWidthKind: .card,
                    fixedHeight: CodexTranscriptColumnMetrics.workHeaderHeight
                ))
                if turn.id == presentation.transcript.turns.last?.id,
                   case .working = turn.status {
                    for prompt in presentation.pendingApprovals {
                        let summary = (prompt.primaryValue ?? prompt.detail)
                            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? prompt.title
                        append(ItemDraft(
                            id: "\(sectionID):approval:\(prompt.id.presentationID)",
                            fingerprint: "approval:\(prompt.id.presentationID):\(summary)",
                            approval: .init(requestID: prompt.id, summary: summary),
                            accessibilityLabel: "Approval needed — \(summary)",
                            maxWidthKind: .card,
                            fixedHeight: 74
                        ))
                    }
                }
            }

            if showsWork && workExpanded {
                for entry in turn.narrative {
                    try Task.checkCancellation()
                    switch entry {
                    case .prose(let prose):
                        if tailMode { continue }
                        let sourceID = "\(sectionID):commentary:\(prose.id)"
                        for draft in contentDrafts(
                            text: prose.text, streaming: prose.isStreaming, sourceID: sourceID,
                            role: .commentary, theme: theme, cacheHits: &preparedTextCacheHits,
                            cacheMisses: &preparedTextCacheMisses, markdownProjections: &markdownProjections
                        ) { append(draft) }
                    case .workGroup(let group):
                        let rows = tailMode ? group.rows.filter(\.isInProgress) : group.rows
                        if rows.isEmpty { continue }
                        let groupHeader = tailMode ? CodexWorkGroupHeaderV2.synthesize(rows: rows) : group.header
                        let headerText = Self.preparePlain(groupHeader, font: theme.captionFont, color: theme.textSecondary, theme: theme)
                        append(ItemDraft(
                            id: "\(sectionID):group:\(group.id):header",
                            fingerprint: "group-header:\(groupHeader)",
                            textRole: .commentary,
                            preparedText: headerText,
                            accessibilityLabel: groupHeader,
                            maxWidthKind: .card,
                            fixedHeight: 24
                        ))
                        let agentChips = rows.compactMap { row -> CodexTranscriptAgentChipRender? in
                            guard case .collabAgent(let agent) = row else { return nil }
                            let threadID = agent.agentThreadIDs.first
                            return .init(
                                id: agent.id,
                                label: threadID.flatMap { presentation.agentDisplayNameByThreadID[$0] }
                                    ?? Self.agentChipLabel(agent),
                                status: agent.displayStatus,
                                threadID: threadID,
                                taskSummary: agent.instructions?.codexAppKitNilIfEmpty,
                                latestUpdate: agent.agentMessages.values.first?.codexAppKitNilIfEmpty
                            )
                        }
                        if !agentChips.isEmpty {
                            append(ItemDraft(
                                id: "\(sectionID):group:\(group.id):agents",
                                fingerprint: "agent-chips:\(String(describing: agentChips))",
                                agentChips: agentChips,
                                accessibilityLabel: Self.agentClusterAccessibilityLabel(agentChips),
                                indentation: 0,
                                maxWidthKind: .card,
                                bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing
                            ))
                        }
                        for row in rows {
                            if case .collabAgent = row { continue }
                            let rowID = row.id
                            let detail = Self.detail(for: row)
                            let diffFiles: [CodexDiffFile]? = {
                                guard case .fileChange(let value) = row,
                                      let diff = value.diff?.codexAppKitNilIfEmpty else { return nil }
                                return CodexUnifiedDiffParser.parse(diff)
                            }()
                            let subagentThreadID = Self.subagentThreadID(for: row)
                            let rowRender = CodexTranscriptWorkRowRender(
                                kind: Self.kind(for: row),
                                label: Self.label(for: row, diffFiles: diffFiles),
                                status: Self.status(for: row),
                                durationMs: Self.duration(for: row),
                                isExpanded: presentation.expandedRowIDs.contains(rowID),
                                hasDetail: detail != nil,
                                isSubagentLink: subagentThreadID != nil,
                                isActionable: subagentThreadID != nil || detail != nil
                            )
                            append(ItemDraft(
                                id: "\(sectionID):row:\(rowID)",
                                fingerprint: "row:\(String(describing: rowRender))",
                                workRow: rowRender,
                                action: subagentThreadID.map(CodexTranscriptRenderAction.openSubagent)
                                    ?? (detail == nil ? nil : .toggleRow(rowID: rowID)),
                                copyText: detail,
                                accessibilityLabel: Self.accessibilityLabel(for: row, render: rowRender),
                                indentation: 0,
                                maxWidthKind: .card,
                                fixedHeight: 30,
                                bottomSpacing: rowRender.isExpanded
                                    ? 2
                                    : CodexTranscriptColumnMetrics.interactiveBottomSpacing
                            ))
                            if presentation.expandedRowIDs.contains(rowID),
                               let diffFiles,
                               !diffFiles.isEmpty {
                                let requestedIndex = presentation.selectedDiffFileIndexByRowID[rowID] ?? 0
                                let selectedIndex = min(max(0, requestedIndex), diffFiles.count - 1)
                                let selectedFile = diffFiles[selectedIndex]
                                let fullPatch = Self.patchText(for: selectedFile)
                                let displayPatch = Self.boundedLines(fullPatch, limit: 400)
                                let prepared = cachedPreparedText(
                                    content: displayPatch, style: "diff-file", theme: theme,
                                    cacheHits: &preparedTextCacheHits, cacheMisses: &preparedTextCacheMisses
                                ) { Self.prepareDiffFile(selectedFile, displayedPatch: displayPatch, theme: theme) }
                                append(ItemDraft(
                                    id: "\(sectionID):row:\(rowID):diff-panel",
                                    fingerprint: "diff-panel:\(selectedIndex):\(String(describing: diffFiles))",
                                    preparedText: prepared,
                                    diffPanel: .init(
                                        rowID: rowID,
                                        files: diffFiles,
                                        selectedFileIndex: selectedIndex
                                    ),
                                    copyText: Self.patchText(for: selectedFile),
                                    accessibilityLabel: "Patch for \(selectedFile.path), \(selectedFile.added) additions and \(selectedFile.removed) removals",
                                    indentation: 0,
                                    maxWidthKind: .card,
                                    fixedHeight: CodexTranscriptColumnMetrics.diffPanelHeight,
                                    bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing,
                                    isScrollableOutput: true
                                ))
                            } else if presentation.expandedRowIDs.contains(rowID), let detail {
                                let bounded = Self.bounded(detail, limit: 20_000)
                                append(ItemDraft(
                                    id: "\(sectionID):row:\(rowID):detail",
                                    fingerprint: "detail:\(bounded)",
                                    textRole: .expandedOutput,
                                    preparedText: Self.preparePlain(bounded, font: theme.codeFont, color: theme.textSecondary, theme: theme),
                                    copyText: detail,
                                    accessibilityLabel: "Expanded output: \(bounded)",
                                    indentation: 0,
                                    maxWidthKind: .card,
                                    bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing,
                                    isScrollableOutput: true
                                ))
                            }
                        }
                    case .productToolCall(let call):
                        if tailMode, call.status != .inProgress { continue }
                        append(ItemDraft(
                            id: "\(sectionID):product:\(call.id)",
                            fingerprint: "product:\(String(describing: call))",
                            productTool: call,
                            accessibilityLabel: "Tool \([call.namespace, call.tool].compactMap { $0 }.joined(separator: " "))",
                            maxWidthKind: .card,
                            fixedHeight: 44
                        ))
                    case .notice(let notice):
                        if tailMode { continue }
                        append(ItemDraft(
                            id: "\(sectionID):notice:\(notice.id)",
                            fingerprint: "notice:\(notice.message)",
                            textRole: .notice,
                            preparedText: Self.preparePlain(notice.message, font: theme.captionFont, color: theme.textTertiary, theme: theme),
                            copyText: notice.message,
                            accessibilityLabel: notice.message,
                            maxWidthKind: .card
                        ))
                    }
                }
                if case .working = turn.status,
                   let tail = turn.liveTail?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !tail.isEmpty,
                   !(tail == "Thinking" && turn.narrative.isEmpty) {
                    append(ItemDraft(
                        id: "\(sectionID):live-tail",
                        fingerprint: "tail:\(tail)",
                        textRole: .liveTail,
                        preparedText: Self.preparePlain(tail, font: theme.captionFont, color: theme.textTertiary, theme: theme),
                        accessibilityLabel: tail,
                        maxWidthKind: .card,
                        fixedHeight: 28
                    ))
                }
            }

            for user in turn.steeredMessages {
                for draft in userMessageDrafts(
                    user,
                    sectionID: sectionID,
                    contentWidth: contentWidth,
                    presentedAt: presentedAt,
                    turnIsStreaming: turnIsStreaming,
                    theme: theme,
                    cacheHits: &preparedTextCacheHits,
                    cacheMisses: &preparedTextCacheMisses
                ) { append(draft) }
            }

            if let answer = turn.finalAnswer, !answer.text.isEmpty {
                let sourceID = "\(sectionID):final:\(answer.id)"
                for draft in contentDrafts(
                    text: answer.text, streaming: answer.isStreaming, sourceID: sourceID,
                    role: .finalAnswer, theme: theme, cacheHits: &preparedTextCacheHits,
                    cacheMisses: &preparedTextCacheMisses, markdownProjections: &markdownProjections
                ) { append(draft) }
                append(timestampDraft(
                    id: "\(sectionID):final-timestamp",
                    date: presentedAt,
                    trailing: false,
                    kind: .finalAnswer,
                    isTurnStreaming: turnIsStreaming,
                    copyText: answer.text
                ))
            }
            itemIDsBySection[sectionID] = sectionItems
        }

        revisionByID = revisionByID.filter { liveIDs.contains($0.key) }
        heightByKey = heightByKey.filter { key, _ in
            liveIDs.contains(key.id) && revisionByID[key.id]?.revision == key.revision
        }
        let liveSourcePrefixes = Set(itemsByID.keys.map { id in
            id.rawValue.components(separatedBy: ":block:").first ?? id.rawValue
        })
        previousBlocksBySourceID = previousBlocksBySourceID.filter { liveSourcePrefixes.contains($0.key) }
        sourceTextBySourceID = sourceTextBySourceID.filter { liveSourcePrefixes.contains($0.key) }
        projectionCount += 1
        let elapsed = startedAt.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        let diagnostics = CodexTranscriptRenderDiagnostics(
            projectionCount: projectionCount,
            projectedItemCount: itemsByID.count,
            changedItemCount: changedIDs.count,
            heightCacheHitCount: cacheHits,
            heightCacheMissCount: cacheMisses,
            preparedTextCacheHitCount: preparedTextCacheHits,
            preparedTextCacheMissCount: preparedTextCacheMisses,
            markdownProjectionCount: markdownProjections,
            projectionDurationMilliseconds: milliseconds
        )
        return CodexTranscriptRenderSnapshot(
            threadID: presentation.threadID,
            sectionIDs: sections,
            itemIDsBySection: itemIDsBySection,
            itemsByID: itemsByID,
            changedItemIDs: changedIDs,
            diagnostics: diagnostics
        )
    }

    private func projectBlocks(
        _ text: String,
        streaming: Bool,
        sourceID: String
    ) -> [CodexBlock] {
        if sourceTextBySourceID[sourceID] == text,
           let previous = previousBlocksBySourceID[sourceID] {
            return previous
        }
        let blocks = CodexBlockProjector.project(
            text,
            previous: previousBlocksBySourceID[sourceID],
            streaming: streaming,
            cacheNamespace: sourceID
        )
        sourceTextBySourceID[sourceID] = text
        previousBlocksBySourceID[sourceID] = blocks
        return blocks
    }
}

private extension CodexTranscriptRenderProjector {
    struct ItemDraft {
        var id: String
        var fingerprint: String
        var textRole: CodexTranscriptTextRole?
        var preparedText: CodexPreparedTranscriptText?
        var workHeader: CodexTranscriptWorkHeaderRender?
        var workRow: CodexTranscriptWorkRowRender?
        var agentChips: [CodexTranscriptAgentChipRender]
        var diffPanel: CodexTranscriptDiffPanelRender?
        var code: CodexTranscriptCodeRender?
        var footer: CodexTranscriptFooterRender?
        var productTool: CodexProductToolCallV2?
        var directive: CodexTranscriptDirectiveRender?
        var approval: CodexTranscriptApprovalRender?
        var action: CodexTranscriptRenderAction?
        var copyText: String?
        var editUserText: String?
        var accessibilityLabel: String
        var indentation: CGFloat
        var isTrailingAligned: Bool
        var maxWidthKind: CodexTranscriptContentWidthPolicy
        var fixedHeight: CGFloat?
        var intrinsicContentWidth: CGFloat?
        var bottomSpacing: CGFloat
        var isScrollableOutput: Bool

        init(
            id: String,
            fingerprint: String,
            textRole: CodexTranscriptTextRole? = nil,
            preparedText: CodexPreparedTranscriptText? = nil,
            workHeader: CodexTranscriptWorkHeaderRender? = nil,
            workRow: CodexTranscriptWorkRowRender? = nil,
            agentChips: [CodexTranscriptAgentChipRender] = [],
            diffPanel: CodexTranscriptDiffPanelRender? = nil,
            code: CodexTranscriptCodeRender? = nil,
            footer: CodexTranscriptFooterRender? = nil,
            productTool: CodexProductToolCallV2? = nil,
            directive: CodexTranscriptDirectiveRender? = nil,
            approval: CodexTranscriptApprovalRender? = nil,
            action: CodexTranscriptRenderAction? = nil,
            copyText: String? = nil,
            editUserText: String? = nil,
            accessibilityLabel: String,
            indentation: CGFloat = 0,
            isTrailingAligned: Bool = false,
            maxWidthKind: CodexTranscriptContentWidthPolicy = .full,
            fixedHeight: CGFloat? = nil,
            intrinsicContentWidth: CGFloat? = nil,
            bottomSpacing: CGFloat = 0,
            isScrollableOutput: Bool = false
        ) {
            self.id = id
            self.fingerprint = fingerprint
            self.textRole = textRole
            self.preparedText = preparedText
            self.workHeader = workHeader
            self.workRow = workRow
            self.agentChips = agentChips
            self.diffPanel = diffPanel
            self.code = code
            self.footer = footer
            self.productTool = productTool
            self.directive = directive
            self.approval = approval
            self.action = action
            self.copyText = copyText
            self.editUserText = editUserText
            self.accessibilityLabel = accessibilityLabel
            self.indentation = indentation
            self.isTrailingAligned = isTrailingAligned
            self.maxWidthKind = maxWidthKind
            self.fixedHeight = fixedHeight
            self.intrinsicContentWidth = intrinsicContentWidth
            self.bottomSpacing = bottomSpacing
            self.isScrollableOutput = isScrollableOutput
        }

        func maxWidth(_ contentWidth: CGFloat, _ theme: CodexTranscriptAppKitTheme) -> CGFloat {
            switch maxWidthKind {
            case .full: contentWidth
            case .card: min(contentWidth, theme.cardMaxWidth)
            case .user: min(contentWidth * 0.77, theme.userBubbleMaxWidth)
            }
        }
    }

    func contentDrafts(
        text: String,
        streaming: Bool,
        sourceID: String,
        role: CodexTranscriptTextRole,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int,
        markdownProjections: inout Int
    ) -> [ItemDraft] {
        let partitions = CodexInlineDirectiveParser.split(text: text)
        guard partitions.contains(where: { $0.directive != nil }) else {
            return ordinaryMessageDrafts(
                text: text, streaming: streaming, sourceID: sourceID, role: role, theme: theme,
                cacheHits: &cacheHits, cacheMisses: &cacheMisses,
                markdownProjections: &markdownProjections
            )
        }

        var result: [ItemDraft] = []
        var directiveIndex = 0
        for (partitionIndex, partition) in partitions.enumerated() {
            if let directive = partition.directive {
                result.append(directiveDraft(
                    directive, raw: partition.text,
                    itemID: "\(sourceID):directive:\(directiveIndex)", theme: theme,
                    cacheHits: &cacheHits, cacheMisses: &cacheMisses
                ))
                directiveIndex += 1
            } else if !partition.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(contentsOf: ordinaryMessageDrafts(
                    text: partition.text, streaming: streaming,
                    sourceID: "\(sourceID):segment:\(partitionIndex)", role: role, theme: theme,
                    cacheHits: &cacheHits, cacheMisses: &cacheMisses,
                    markdownProjections: &markdownProjections
                ))
            }
        }
        return result
    }

    func ordinaryMessageDrafts(
        text: String,
        streaming: Bool,
        sourceID: String,
        role: CodexTranscriptTextRole,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int,
        markdownProjections: inout Int
    ) -> [ItemDraft] {
        let blocks = projectBlocks(text, streaming: streaming, sourceID: sourceID)
        markdownProjections += 1
        if blocks.count == 1, let block = blocks.first {
            return [draft(
                block: block,
                itemID: block.isCodeV2 ? nil : "\(sourceID):selection-surface:0",
                role: role, theme: theme, cacheHits: &cacheHits, cacheMisses: &cacheMisses
            )]
        }
        return messageDrafts(
            blocks: blocks, sourceID: sourceID, role: role, theme: theme,
            cacheHits: &cacheHits, cacheMisses: &cacheMisses
        )
    }

    func directiveDraft(
        _ directive: CodexInlineDirective,
        raw: String,
        itemID: String,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int
    ) -> ItemDraft {
        let attributes = directive.attributes
        let render: CodexTranscriptDirectiveRender
        let action: CodexTranscriptRenderAction?
        let label: String
        var preparedText: CodexPreparedTranscriptText?
        var fixedHeight: CGFloat? = CodexTranscriptColumnMetrics.actionCardHeight

        switch directive.name {
        case "created-thread":
            let legacy = attributes["clientThreadId"]?.replacingOccurrences(of: "client-new-thread:", with: "")
            let threadID = attributes["threadId"] ?? attributes["threadID"] ?? legacy
            let pendingID = attributes["pendingWorktreeId"] ?? attributes["pendingWorktreeID"]
            render = .init(kind: .createdThread(threadID: threadID, pendingWorktreeID: pendingID), raw: raw)
            action = pendingID == nil ? threadID.map(CodexTranscriptRenderAction.openSubagent) : nil
            label = "Created thread · \(Self.shortIdentifier(threadID ?? pendingID ?? "pending"))"
        case "git-stage", "git-commit", "git-create-branch", "git-push":
            let verb = String(directive.name.dropFirst(4))
            let branch = attributes["branch"]
            render = .init(kind: .gitAction(verb: verb, branch: branch, cwd: attributes["cwd"]), raw: raw)
            action = nil
            label = switch verb {
            case "stage": "Staged changes"
            case "commit": "Committed"
            case "create-branch": "Created branch \(branch ?? "")".trimmingCharacters(in: .whitespaces)
            case "push": "Pushed \(branch ?? "")".trimmingCharacters(in: .whitespaces)
            default: "Git · \(verb)"
            }
        case "git-create-pr":
            let url = attributes["url"] ?? ""
            let branch = attributes["branch"]
            let isDraft = attributes["isDraft"] == "true"
            render = .init(kind: .pullRequest(url: url, branch: branch, isDraft: isDraft), raw: raw)
            action = url.isEmpty ? nil : .openURL(url)
            label = "PR" + (branch.map { " · \($0)" } ?? "") + (isDraft ? " · draft" : "")
        case "code-comment":
            let title = attributes["title"] ?? "Code comment"
            let body = attributes["body"] ?? ""
            let file = attributes["file"] ?? ""
            let start = attributes["start"].flatMap(Int.init)
            let end = attributes["end"].flatMap(Int.init)
            let priority = attributes["priority"].flatMap(Int.init)
            render = .init(kind: .codeComment(
                title: title, body: body, file: file, start: start, end: end, priority: priority
            ), raw: raw)
            action = file.isEmpty ? nil : .openFile(path: file, line: start)
            label = title
            preparedText = cachedPreparedText(
                content: body, style: "directive-code-comment", theme: theme,
                cacheHits: &cacheHits, cacheMisses: &cacheMisses
            ) { Self.prepareMarkdown(body, font: theme.bodyFont, color: theme.textSecondary, theme: theme) }
            fixedHeight = nil
        default:
            render = .init(kind: .unknown(name: directive.name), raw: raw)
            action = nil
            label = "<\(directive.name)>"
        }
        return ItemDraft(
            id: itemID, fingerprint: "directive:\(raw)", preparedText: preparedText,
            directive: render, action: action, copyText: raw, accessibilityLabel: label,
            maxWidthKind: .card, fixedHeight: fixedHeight
        )
    }

    static func shortIdentifier(_ value: String) -> String {
        let tail = value.split(separator: "-").last.map(String.init) ?? value
        return String(tail.prefix(8))
    }

    func messageDrafts(
        blocks: [CodexBlock],
        sourceID: String,
        role: CodexTranscriptTextRole,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int
    ) -> [ItemDraft] {
        var drafts: [ItemDraft] = []
        var textRun: [CodexBlock] = []
        var textRunIndex = 0

        for block in blocks {
            if case .code = block {
                if !textRun.isEmpty {
                    drafts.append(textRunDraft(
                        blocks: textRun,
                        sourceID: sourceID,
                        runIndex: textRunIndex,
                        role: role,
                        theme: theme,
                        cacheHits: &cacheHits,
                        cacheMisses: &cacheMisses
                    ))
                    textRun.removeAll(keepingCapacity: true)
                    textRunIndex += 1
                }
                drafts.append(draft(
                    block: block,
                    role: role,
                    theme: theme,
                    cacheHits: &cacheHits,
                    cacheMisses: &cacheMisses
                ))
            } else {
                textRun.append(block)
            }
        }

        if !textRun.isEmpty {
            drafts.append(textRunDraft(
                blocks: textRun,
                sourceID: sourceID,
                runIndex: textRunIndex,
                role: role,
                theme: theme,
                cacheHits: &cacheHits,
                cacheMisses: &cacheMisses
            ))
        }
        return drafts
    }

    func textRunDraft(
        blocks: [CodexBlock],
        sourceID: String,
        runIndex: Int,
        role: CodexTranscriptTextRole,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int
    ) -> ItemDraft {
        let runFingerprint = blocks.map { "\($0.id):\($0.contentDigest)" }.joined(separator: "|")
        let prepared: CodexPreparedTranscriptText
        if blocks.count == 1, let block = blocks.first {
            prepared = cachedPreparedText(
                content: block.contentDigest,
                style: "block-\(role)-\(block.id)",
                theme: theme,
                cacheHits: &cacheHits,
                cacheMisses: &cacheMisses
            ) {
                Self.prepare(block: block, role: role, theme: theme)
            }
        } else {
            var preparedBlocks: [NSAttributedString] = []
            preparedBlocks.reserveCapacity(blocks.count)
            for block in blocks {
                let blockText = cachedPreparedText(
                    content: block.contentDigest,
                    style: "block-\(role)-\(block.id)",
                    theme: theme,
                    cacheHits: &cacheHits,
                    cacheMisses: &cacheMisses
                ) {
                    Self.prepare(block: block, role: role, theme: theme)
                }
                preparedBlocks.append(blockText.attributedString)
            }
            prepared = cachedPreparedText(
                content: runFingerprint,
                style: "selection-surface-\(role)-\(sourceID)-\(runIndex)",
                theme: theme,
                cacheHits: &cacheHits,
                cacheMisses: &cacheMisses
            ) {
                Self.combine(preparedBlocks, role: role, theme: theme)
            }
        }
        let text = prepared.attributedString.string
        return ItemDraft(
            id: "\(sourceID):selection-surface:\(runIndex)",
            fingerprint: "selection-surface:\(role):\(runFingerprint)",
            textRole: role,
            preparedText: prepared,
            copyText: text,
            accessibilityLabel: "\(role == .finalAnswer ? "Assistant" : "Commentary"): \(text)",
            maxWidthKind: .card
        )
    }

    func draft(
        block: CodexBlock,
        itemID: String? = nil,
        role: CodexTranscriptTextRole,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int
    ) -> ItemDraft {
        switch block {
        case .code(let id, let language, let code, let complete):
            let displayCode = code.count > 40_000 ? Self.bounded(code, limit: 40_000) : code
            let prepared = cachedPreparedText(
                content: displayCode,
                style: "code-\(language ?? "plain")-\(complete ? "stable" : "streaming")",
                theme: theme,
                cacheHits: &cacheHits,
                cacheMisses: &cacheMisses
            ) { [codeHighlighter] in
                if complete,
                   code.count <= 40_000,
                   let highlighted = codeHighlighter.highlight(code, language: language, theme: theme) {
                    return CodexPreparedTranscriptText(highlighted)
                }
                return Self.preparePlain(displayCode, font: theme.codeFont, color: theme.codeText, theme: theme)
            }
            return ItemDraft(
                id: itemID ?? id,
                fingerprint: "code:\(complete):\(language ?? ""):\(code)",
                preparedText: prepared,
                code: CodexTranscriptCodeRender(language: language, code: displayCode),
                copyText: code,
                accessibilityLabel: "Code block \(language ?? "code"): \(code)",
                maxWidthKind: .card
            )
        default:
            let prepared = cachedPreparedText(
                content: block.contentDigest,
                style: "block-\(role)-\(block.id)",
                theme: theme,
                cacheHits: &cacheHits,
                cacheMisses: &cacheMisses
            ) {
                Self.prepare(block: block, role: role, theme: theme)
            }
            return ItemDraft(
                id: itemID ?? block.id,
                fingerprint: "text:\(role):\(block.contentDigest)",
                textRole: role,
                preparedText: prepared,
                copyText: prepared.attributedString.string,
                accessibilityLabel: "\(role == .finalAnswer ? "Assistant" : "Commentary"): \(prepared.attributedString.string)",
                maxWidthKind: .card
            )
        }
    }

    func timestampDraft(
        id: String,
        date: Date,
        trailing: Bool,
        kind: CodexTranscriptFooterRender.Kind,
        isTurnStreaming: Bool,
        copyText: String
    ) -> ItemDraft {
        let label = date.formatted(date: .omitted, time: .shortened)
        return ItemDraft(
            id: id,
            fingerprint: "timestamp:\(label):streaming:\(isTurnStreaming)",
            textRole: .timestamp,
            footer: .init(kind: kind, timestamp: label, isTurnStreaming: isTurnStreaming),
            copyText: copyText,
            accessibilityLabel: "Presented at \(label)",
            isTrailingAligned: trailing,
            maxWidthKind: trailing ? .user : .card,
            fixedHeight: CodexTranscriptColumnMetrics.footerHeight
        )
    }

    func userMessageDrafts(
        _ user: CodexUserMessageV2,
        sectionID: String,
        contentWidth: CGFloat,
        presentedAt: Date,
        turnIsStreaming: Bool,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int
    ) -> [ItemDraft] {
        // Trailing whitespace/newlines would measure as phantom empty lines
        // and inflate the bubble; display trimmed, keep the raw text for copy.
        let displayText = user.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleUserText = displayText.isEmpty && !user.referencedFiles.isEmpty
            ? "Attached files"
            : displayText
        let prepared = cachedPreparedText(
            content: user.displayText,
            style: "user-plain",
            theme: theme,
            cacheHits: &cacheHits,
            cacheMisses: &cacheMisses
        ) {
            Self.prepareUserMessage(
                user,
                text: visibleUserText,
                font: theme.bodyFont,
                color: theme.textPrimary,
                theme: theme
            )
        }
        let userMaxWidth = min(contentWidth * 0.77, theme.userBubbleMaxWidth)
        let horizontalPadding = CodexTranscriptColumnMetrics.userBubbleHorizontalPadding * 2
        let textBounds = prepared.attributedString.boundingRect(
            with: NSSize(
                width: max(1, userMaxWidth - horizontalPadding),
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        var drafts: [ItemDraft] = []
        if !user.referencedFiles.isEmpty {
            let attachmentChips = user.referencedFiles.map {
                CodexTranscriptAgentChipRender(
                    id: "\(user.id):attachment:\($0.id)",
                    label: $0.displayName,
                    status: .done,
                    threadID: nil,
                    taskSummary: $0.path,
                    latestUpdate: nil,
                    attachmentKind: $0.kind
                )
            }
            let attachmentWidth = min(
                userMaxWidth,
                attachmentChips.reduce(CGFloat.zero) { total, chip in
                    let width = chip.attachmentKind == .image
                        ? 64
                        : ceil((chip.label as NSString).size(
                            withAttributes: [.font: theme.captionFont]
                        ).width) + 34
                    return total + width
                } + CGFloat(max(0, attachmentChips.count - 1) * 6)
            )
            drafts.append(ItemDraft(
                id: "\(sectionID):user:\(user.id):attachments",
                fingerprint: "attachments:\(user.referencedFiles.map(\.path).joined(separator: "|"))",
                agentChips: attachmentChips,
                accessibilityLabel: "Attached files: \(user.referencedFiles.map(\.displayName).joined(separator: ", "))",
                isTrailingAligned: true,
                maxWidthKind: .user,
                intrinsicContentWidth: attachmentWidth,
                bottomSpacing: CodexTranscriptColumnMetrics.interactiveBottomSpacing
            ))
        }
        drafts.append(ItemDraft(
            id: "\(sectionID):user:\(user.id)",
            fingerprint: "user:\(user.rawText):\(user.isOptimistic)",
            textRole: .user,
            preparedText: prepared,
            copyText: user.text.isEmpty ? user.displayText : user.text,
            editUserText: user.rawText,
            accessibilityLabel: "You: \(visibleUserText)",
            isTrailingAligned: true,
            maxWidthKind: .user,
            intrinsicContentWidth: min(userMaxWidth, ceil(textBounds.width) + horizontalPadding)
        ))
        drafts.append(timestampDraft(
            id: "\(sectionID):user-timestamp:\(user.id)",
            date: presentedAt,
            trailing: true,
            kind: .user,
            isTurnStreaming: turnIsStreaming,
            copyText: user.text.isEmpty ? user.displayText : user.text
        ))
        return drafts
    }

    func cachedPreparedText(
        content: String,
        style: String,
        theme: CodexTranscriptAppKitTheme,
        cacheHits: inout Int,
        cacheMisses: inout Int,
        make: () -> CodexPreparedTranscriptText
    ) -> CodexPreparedTranscriptText {
        let key = theme.fingerprint + ":" + style + ":" + CodexBlockDigest.digest(content)
        if let cached = preparedTextByKey[key] {
            cacheHits += 1
            return cached
        }
        let prepared = make()
        preparedTextByKey[key] = prepared
        preparedTextInsertionOrder.append(key)
        cacheMisses += 1
        if preparedTextInsertionOrder.count > 8_192 {
            let expired = Array(preparedTextInsertionOrder.prefix(1_024))
            preparedTextInsertionOrder.removeFirst(1_024)
            for key in expired { preparedTextByKey.removeValue(forKey: key) }
        }
        return prepared
    }

    static func measure(
        draft: ItemDraft,
        width: CGFloat,
        theme: CodexTranscriptAppKitTheme
    ) -> CGFloat {
        if let fixedHeight = draft.fixedHeight { return fixedHeight + draft.bottomSpacing }
        if !draft.agentChips.isEmpty {
            return agentChipClusterHeight(
                draft.agentChips,
                width: max(80, width - draft.indentation),
                font: theme.captionFont
            ) + draft.bottomSpacing
        }
        if let code = draft.code {
            let text = draft.preparedText?.attributedString
                ?? preparePlain(code.code, font: theme.codeFont, color: theme.codeText, theme: theme).attributedString
            let bounds = text.boundingRect(
                with: NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let height = max(76, ceil(bounds.height) + 52)
            let measured = draft.isScrollableOutput
                ? min(CodexTranscriptColumnMetrics.scrollableOutputMaxHeight, height)
                : height
            return measured + draft.bottomSpacing
        }
        let horizontalPadding: CGFloat = draft.textRole == .user
            ? CodexTranscriptColumnMetrics.userBubbleHorizontalPadding * 2
            : (draft.textRole == .expandedOutput ? 24 : 0)
        if let text = draft.preparedText?.attributedString {
            let measurementWidth = draft.textRole == .expandedOutput
                ? 1_000_000
                : max(80, width - horizontalPadding - draft.indentation)
            let bounds = text.boundingRect(
                with: NSSize(width: measurementWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let isCodeComment: Bool
            if case .codeComment = draft.directive?.kind { isCodeComment = true } else { isCodeComment = false }
            let verticalPadding: CGFloat = isCodeComment
                ? 64
                : (draft.textRole == .user
                    ? CodexTranscriptColumnMetrics.userBubbleVerticalPadding * 2
                    : (draft.textRole == .expandedOutput
                        ? 16
                        : CodexTranscriptColumnMetrics.itemGap + 2))
            let height = max(18, ceil(bounds.height) + verticalPadding)
            let measured = draft.isScrollableOutput
                ? min(CodexTranscriptColumnMetrics.scrollableOutputMaxHeight, height)
                : height
            return measured + draft.bottomSpacing
        }
        return 36 + draft.bottomSpacing
    }

    static func agentChipClusterHeight(
        _ chips: [CodexTranscriptAgentChipRender],
        width: CGFloat,
        font: NSFont
    ) -> CGFloat {
        let height: CGFloat = chips.contains(where: { $0.attachmentKind == .image }) ? 64 : 26
        let gap: CGFloat = 6
        var x: CGFloat = 0
        var rows: CGFloat = 1
        for chip in chips {
            let isAttachmentImage = chip.attachmentKind == .image
            let title = chip.threadID == nil ? chip.label : "\(chip.label) · \(agentStatusTitle(chip.status).lowercased())"
            let labelWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
            let chipWidth = isAttachmentImage ? 64 : min(width, max(74, labelWidth + 28))
            if x > 0, x + chipWidth > width {
                rows += 1
                x = 0
            }
            x += chipWidth + gap
        }
        return rows * height + max(0, rows - 1) * gap
    }

    static func agentChipLabel(_ agent: CodexCollabAgentRowV2) -> String {
        guard let raw = agent.agentNames.first, !raw.isEmpty else { return "Agent" }
        let leaf = raw.split(separator: "/").last.map(String.init) ?? raw
        return leaf.capitalized
    }

    static func agentClusterAccessibilityLabel(
        _ chips: [CodexTranscriptAgentChipRender]
    ) -> String {
        chips.map { chip in
            let status = switch chip.status {
            case .starting: "starting"
            case .working: "working"
            case .done: "done"
            case .failed: "failed"
            case .closed: "closed"
            }
            return "\(chip.label), \(status)"
        }.joined(separator: "; ")
    }

    static func agentStatusTitle(_ status: CodexAgentDisplayStatusV2) -> String {
        switch status {
        case .starting: "Starting"
        case .working: "Working"
        case .done: "Done"
        case .failed: "Failed"
        case .closed: "Closed"
        }
    }

    static func prepare(block: CodexBlock, role: CodexTranscriptTextRole, theme: CodexTranscriptAppKitTheme) -> CodexPreparedTranscriptText {
        switch block {
        case .prose(_, let text, _), .htmlFallback(_, let text):
            return prepareMarkdown(text, font: theme.bodyFont, color: color(for: role, theme: theme), theme: theme)
        case .heading(_, let level, let text, _):
            let size: CGFloat = switch level { case 1: 20; case 2: 17; case 3: 15; default: 14 }
            let font = NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .boldFontMask)
            return preparePlain(text, font: font, color: theme.textPrimary, theme: theme)
        case .list(_, let ordered, let items):
            let result = NSMutableAttributedString()
            var counters: [Int: Int] = [:]
            for item in items {
                counters.keys.filter { $0 > item.depth }.forEach { counters.removeValue(forKey: $0) }
                counters[item.depth, default: 0] += 1
                let marker = ordered ? "\(counters[item.depth]!).\t" : "•\t"
                let style = NSMutableParagraphStyle()
                style.lineSpacing = theme.lineSpacing
                style.paragraphSpacing = 4
                let indent = CGFloat(item.depth) * 24
                style.firstLineHeadIndent = indent
                style.headIndent = indent + 24
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 24)]
                let line = NSMutableAttributedString(string: marker, attributes: [
                    .font: theme.bodyFont,
                    .foregroundColor: color(for: role, theme: theme),
                    .paragraphStyle: style
                ])
                let content = NSMutableAttributedString(attributedString: prepareMarkdown(
                    item.text,
                    font: theme.bodyFont,
                    color: color(for: role, theme: theme),
                    theme: theme
                ).attributedString)
                if content.length > 0 {
                    content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: content.length))
                }
                line.append(content)
                line.append(NSAttributedString(string: "\n", attributes: [
                    .font: theme.bodyFont,
                    .foregroundColor: color(for: role, theme: theme),
                    .paragraphStyle: style
                ]))
                result.append(line)
            }
            return CodexPreparedTranscriptText(result)
        case .table(_, let model):
            return prepareTable(model, role: role, theme: theme)
        case .code:
            return preparePlain("", font: theme.codeFont, color: theme.codeText, theme: theme)
        }
    }

    static func combine(
        _ blocks: [NSAttributedString],
        role: CodexTranscriptTextRole,
        theme: CodexTranscriptAppKitTheme
    ) -> CodexPreparedTranscriptText {
        let result = NSMutableAttributedString()
        let separatorAttributes: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: color(for: role, theme: theme),
            .paragraphStyle: paragraphStyle(theme)
        ]
        for block in blocks where block.length > 0 {
            if result.length > 0 {
                let separator = "\n"
                result.append(NSAttributedString(string: separator, attributes: separatorAttributes))
            }
            result.append(block)
        }
        return CodexPreparedTranscriptText(result)
    }

    static func prepareMarkdown(
        _ markdown: String,
        font: NSFont,
        color: NSColor,
        theme: CodexTranscriptAppKitTheme
    ) -> CodexPreparedTranscriptText {
        let parsed = (try? NSAttributedString(markdown: Data(markdown.utf8), options: .init(), baseURL: nil))
            ?? NSAttributedString(string: markdown)
        let result = NSMutableAttributedString(attributedString: parsed)
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttributes([
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle(theme)
        ], range: fullRange)
        parsed.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, range, _ in
            let raw = (value as? NSNumber)?.uintValue ?? (value as? UInt)
            guard let raw else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            var resolved = font
            if intent.contains(.code) {
                resolved = theme.codeFont
                result.addAttribute(.backgroundColor, value: theme.surfaceSunken, range: range)
            } else {
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty { resolved = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            }
            result.addAttribute(.font, value: resolved, range: range)
        }
        parsed.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            result.addAttributes([
                .foregroundColor: theme.accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: range)
        }
        return CodexPreparedTranscriptText(result)
    }

    static func preparePlain(
        _ text: String,
        font: NSFont,
        color: NSColor,
        theme: CodexTranscriptAppKitTheme
    ) -> CodexPreparedTranscriptText {
        // Plain text treats every newline as a paragraph break; markdown paragraph
        // spacing would add 10pt per line, so plain runs use line spacing only.
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing
        return CodexPreparedTranscriptText(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]))
    }

    static func prepareUserMessage(
        _ user: CodexUserMessageV2,
        text: String,
        font: NSFont,
        color: NSColor,
        theme: CodexTranscriptAppKitTheme
    ) -> CodexPreparedTranscriptText {
        let result = NSMutableAttributedString(attributedString: preparePlain(text, font: font, color: color, theme: theme).attributedString)
        return CodexPreparedTranscriptText(result)
    }

    static func prepareTable(
        _ model: CodexTableModel,
        role: CodexTranscriptTextRole,
        theme: CodexTranscriptAppKitTheme
    ) -> CodexPreparedTranscriptText {
        guard !model.columns.isEmpty else {
            return preparePlain("", font: theme.bodyFont, color: color(for: role, theme: theme), theme: theme)
        }
        let table = NSTextTable()
        table.numberOfColumns = model.columns.count
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        let rows = [model.columns.map(\.header)] + model.rows
        let result = NSMutableAttributedString()
        for (rowIndex, row) in rows.enumerated() {
            for columnIndex in model.columns.indices {
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(theme.border)
                if rowIndex == 0 { block.backgroundColor = theme.surfaceSunken }
                let style = NSMutableParagraphStyle()
                style.lineSpacing = theme.lineSpacing
                style.textBlocks = [block]
                switch model.columns[columnIndex].alignment {
                case .leading: style.alignment = .left
                case .center: style.alignment = .center
                case .trailing: style.alignment = .right
                }
                let text = columnIndex < row.count ? row[columnIndex] : ""
                let prepared = NSMutableAttributedString(attributedString: prepareMarkdown(
                    text,
                    font: theme.bodyFont,
                    color: color(for: role, theme: theme),
                    theme: theme
                ).attributedString)
                if prepared.length > 0 {
                    prepared.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: prepared.length))
                    if rowIndex == 0 {
                        prepared.addAttribute(
                            .font,
                            value: NSFontManager.shared.convert(theme.bodyFont, toHaveTrait: .boldFontMask),
                            range: NSRange(location: 0, length: prepared.length)
                        )
                    }
                }
                prepared.append(NSAttributedString(string: "\n", attributes: [
                    .font: theme.bodyFont,
                    .foregroundColor: color(for: role, theme: theme),
                    .paragraphStyle: style
                ]))
                result.append(prepared)
            }
        }
        return CodexPreparedTranscriptText(result)
    }

    static func paragraphStyle(_ theme: CodexTranscriptAppKitTheme) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing
        style.paragraphSpacing = 10
        return style
    }

    static func color(for role: CodexTranscriptTextRole, theme: CodexTranscriptAppKitTheme) -> NSColor {
        theme.textPrimary
    }

    static func isStreaming(_ turn: CodexTurnV2) -> Bool {
        if case .working = turn.status { return true }
        if turn.finalAnswer?.isStreaming == true { return true }
        return turn.narrative.contains { entry in
            if case .prose(let prose) = entry { return prose.isStreaming }
            return false
        }
    }

    static func shouldRenderWork(_ turn: CodexTurnV2) -> Bool {
        switch turn.status {
        case .working:
            return turn.finalAnswer?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                || hasInProgressWork(turn)
        case .done, .failed:
            return !turn.narrative.isEmpty || turn.liveTail != nil
        }
    }

    static func isWorkTailMode(_ turn: CodexTurnV2) -> Bool {
        guard case .working = turn.status else { return false }
        return turn.finalAnswer?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func hasInProgressWork(_ turn: CodexTurnV2) -> Bool {
        turn.narrative.contains { entry in
            switch entry {
            case .workGroup(let group): group.rows.contains(where: \.isInProgress)
            case .productToolCall(let call): call.status == .inProgress
            default: false
            }
        }
    }

    static func kind(for row: CodexWorkRowV2) -> CodexWorkRowKind {
        switch row {
        case .command: .command
        case .fileChange: .fileChange
        case .mcpToolCall: .mcp
        case .webSearch: .webSearch
        case .collabAgent: .agent
        case .other: .other
        }
    }

    static func workIsExpanded(_ turn: CodexTurnV2, presentation: CodexThreadUIPresentation) -> Bool {
        switch turn.status {
        case .working: true
        case .done: presentation.expandedWorkTurnIDs.contains(turn.id)
        case .failed: false
        }
    }

    static func workHeader(_ turn: CodexTurnV2, expanded: Bool, presentedAt: Date) -> CodexTranscriptWorkHeaderRender {
        switch turn.status {
        case .working(let since):
            let start = since.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? presentedAt
            return .init(state: .working(
                startedAt: start,
                showsDuration: CodexWorkBlockViewV2.showsWorkingDuration(narrative: turn.narrative, liveTail: turn.liveTail)
            ))
        case .done(let durationMs):
            return .init(state: .done(durationMs: durationMs, isExpanded: expanded))
        case .failed(let message):
            return .init(state: .failed(message: message))
        }
    }

    static func workHeaderIsActionable(_ header: CodexTranscriptWorkHeaderRender) -> Bool {
        if case .done = header.state { return true }
        return false
    }

    static func workHeaderAccessibilityLabel(_ header: CodexTranscriptWorkHeaderRender) -> String {
        switch header.state {
        case .working(_, let showsDuration): return showsDuration ? "Working" : "Thinking"
        case .done(let duration, let expanded):
            return "\(CodexWorkBlockViewV2.completedLabel(duration)), \(expanded ? "expanded" : "collapsed")"
        case .failed(let message): return message.isEmpty ? "Work failed" : message
        }
    }

    static func label(for row: CodexWorkRowV2, diffFiles: [CodexDiffFile]? = nil) -> String {
        switch row {
        case .command(let value):
            return (value.status == .inProgress ? "Running " : "Ran ") + value.command.codexAppKitDisplayPrefix(limit: 280)
        case .fileChange(let value):
            guard let diffFiles else { return "Edited " + value.files.joined(separator: " · ") }
            let added = diffFiles.reduce(0) { $0 + $1.added }
            let removed = diffFiles.reduce(0) { $0 + $1.removed }
            let count = max(value.files.count, diffFiles.count)
            return "Edited \(count) \(count == 1 ? "file" : "files") · +\(added) −\(removed)"
        case .mcpToolCall(let value):
            let app = value.appName.isEmpty ? value.server : value.appName
            let base = "Called \(app) · \(value.tool)"
            return value.errorFirstLine.map { base + " — " + $0 } ?? base
        case .webSearch(let value): return "Searched \(value.query)"
        case .collabAgent(let value): return value.label
        case .other(let value): return value.label
        }
    }

    static func status(for row: CodexWorkRowV2) -> CodexWorkItemStatusV2 {
        switch row {
        case .command(let value): value.status
        case .fileChange(let value): value.status
        case .mcpToolCall(let value): value.status
        case .webSearch(let value): value.status
        case .collabAgent(let value): value.status
        case .other(let value): value.status
        }
    }

    static func duration(for row: CodexWorkRowV2) -> Int? {
        switch row {
        case .command(let value): value.durationMs
        case .fileChange(let value): value.durationMs
        case .mcpToolCall(let value): value.durationMs
        default: nil
        }
    }

    static func detail(for row: CodexWorkRowV2) -> String? {
        switch row {
        case .command(let value): return value.output?.codexAppKitNilIfEmpty
        case .fileChange(let value): return value.diff?.codexAppKitNilIfEmpty
        case .mcpToolCall(let value):
            let parts = [
                value.arguments.map { "Arguments\n\($0.description)" },
                value.result.map { "Result\n\($0.description)" }
            ].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        case .collabAgent(let value):
            guard value.action == .waited || value.action == .sentInput else { return nil }
            let ordered = value.agentNames.filter { value.agentMessages[$0] != nil }
                + value.agentMessages.keys.filter { !value.agentNames.contains($0) }.sorted()
            let replies = ordered.compactMap { agent in
                value.agentMessages[agent].map { "\(agent)\n\($0)" }
            }.joined(separator: "\n\n")
            let parts = [value.action == .sentInput ? value.instructions?.codexAppKitNilIfEmpty : nil, replies.codexAppKitNilIfEmpty].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        default: return nil
        }
    }

    static func patchText(for file: CodexDiffFile) -> String {
        var lines = ["\(file.path) · +\(file.added) −\(file.removed)"]
        for hunk in file.hunks {
            if !hunk.header.isEmpty { lines.append(hunk.header) }
            lines.append(contentsOf: hunk.lines.map(\.text))
        }
        return lines.joined(separator: "\n")
    }

    static func boundedLines(_ text: String, limit: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > limit else { return text }
        return lines.prefix(limit).joined(separator: "\n") + "\n… \(lines.count - limit) more lines"
    }

    static func prepareDiffFile(
        _ file: CodexDiffFile,
        displayedPatch: String,
        theme: CodexTranscriptAppKitTheme
    ) -> CodexPreparedTranscriptText {
        let result = NSMutableAttributedString()
        let lines = displayedPatch.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, lineValue) in lines.enumerated() {
            let line = String(lineValue)
            let color: NSColor
            if index == 0 { color = theme.textPrimary }
            else if line.hasPrefix("+") && !line.hasPrefix("+++") { color = theme.success }
            else if line.hasPrefix("-") && !line.hasPrefix("---") { color = theme.danger }
            else if line.hasPrefix("@@") || line.hasPrefix("… ") { color = theme.textTertiary }
            else { color = theme.codeText }
            let font = index == 0
                ? NSFontManager.shared.convert(theme.codeFont, toHaveTrait: .boldFontMask)
                : theme.codeFont
            result.append(NSAttributedString(
                string: line + (index == lines.count - 1 ? "" : "\n"),
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle(theme)]
            ))
        }
        return CodexPreparedTranscriptText(result)
    }

    static func subagentThreadID(for row: CodexWorkRowV2) -> String? {
        guard case .collabAgent(let value) = row else { return nil }
        return value.agentThreadIDs.first
    }

    static func accessibilityLabel(for row: CodexWorkRowV2, render: CodexTranscriptWorkRowRender) -> String {
        let state = switch render.status { case .inProgress: "in progress"; case .completed: "completed"; case .failed: "failed" }
        return "\(render.label), \(state)"
    }

    static func bounded(_ text: String, limit: Int) -> String {
        text.codexAppKitDisplayPrefix(limit: limit)
    }

    static func copyText(for turn: CodexTurnV2) -> String {
        var parts: [String] = []
        if let user = turn.userMessage?.displayText.codexAppKitNilIfEmpty { parts.append("You\n" + user) }
        var work: [String] = []
        for entry in turn.narrative {
            switch entry {
            case .prose(let prose): if !prose.text.isEmpty { work.append(prose.text) }
            case .workGroup(let group):
                work.append(group.header)
                work.append(contentsOf: group.rows.map { row in
                    [label(for: row), detail(for: row)].compactMap { $0 }.joined(separator: "\n")
                })
            case .productToolCall(let call):
                let label = [call.namespace, call.tool].compactMap { $0 }.joined(separator: " · ")
                let payload = [call.arguments.map(\.description), call.contentItems.isEmpty ? nil : call.contentItems.map(\.description).joined(separator: "\n")]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                work.append([label, payload.codexAppKitNilIfEmpty].compactMap { $0 }.joined(separator: "\n"))
            case .notice(let notice): work.append(notice.message)
            }
        }
        if !work.isEmpty { parts.append("Work\n" + work.joined(separator: "\n")) }
        for user in turn.steeredMessages {
            if let text = user.displayText.codexAppKitNilIfEmpty {
                parts.append("You\n" + text)
            }
        }
        if let answer = turn.finalAnswer?.text.codexAppKitNilIfEmpty { parts.append("Assistant\n" + answer) }
        return parts.joined(separator: "\n\n")
    }
}

private extension CodexBlock {
    var isCodeV2: Bool {
        if case .code = self { return true }
        return false
    }
}

private extension String {
    var codexAppKitNilIfEmpty: String? { isEmpty ? nil : self }

    func codexAppKitDisplayPrefix(limit: Int) -> String {
        guard let boundary = index(startIndex, offsetBy: limit, limitedBy: endIndex), boundary != endIndex else { return self }
        return String(self[..<boundary]) + "\n… Output truncated for display"
    }
}
