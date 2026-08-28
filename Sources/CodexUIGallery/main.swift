import AppKit
import CodexCore
@_spi(VisualTesting) import CodexCoreUI
import SwiftUI

// Renders component scenes to PNG for visual review.
//
// Why offscreen: `screencapture` needs Screen Recording permission, which a
// headless or CI run does not have.
//
// What this cannot show: Liquid Glass. It is composited by the window server
// from what is *behind* the window, so it does not appear in `ImageRenderer`,
// `NSView.cacheDisplay`, or `CALayer.render(in:)` — an app cannot capture its
// own glass. Scenes are therefore rendered with the theme's glass opt-out
// engaged, which is the same opaque path High Contrast and Reduce Transparency
// take. Typography, spacing, color and layout are faithful; glass fidelity has
// to be checked in the running app.
//
//   swift run codex-ui-gallery [--out DIR] [--theme NAME] [--scale N]

@MainActor
struct Gallery {
    struct Scene {
        let name: String
        let width: CGFloat
        let content: AnyView
    }

    static func scenes() -> [Scene] {
        [
            Scene(name: "typography", width: 720, content: AnyView(TypographySpecimen())),
            Scene(name: "spacing", width: 720, content: AnyView(SpacingSpecimen())),
            Scene(name: "glass-roles", width: 720, content: AnyView(GlassRoleSpecimen())),
            Scene(name: "palette", width: 720, content: AnyView(PaletteSpecimen())),
            Scene(name: "plan-panel", width: 420, content: AnyView(PlanPanelScene())),
            Scene(name: "summary-plan-and-changes", width: 420, content: AnyView(SummaryPlanAndChangesScene())),
            Scene(name: "agent-panel-completed", width: 668, content: AnyView(AgentPanelCompletedScene())),
            Scene(name: "transcript-turn-changes", width: 860, content: AnyView(TranscriptTurnChangesScene())),
            Scene(name: "review-workbench", width: 900, content: AnyView(ReviewWorkbenchScene())),
            Scene(name: "review-workbench-modified", width: 900, content: AnyView(
                CodexGitReviewWorkbenchGalleryFixture(
                    selectedPath: "Sources/CodexCoreUI/CodexGitReviewWorkbenchView.swift"
                )
            )),
            Scene(name: "mcp-sheet", width: 620, content: AnyView(MCPSheetScene())),
            Scene(name: "plugins-marketplace", width: 1180, content: AnyView(PluginsRouteScene(tab: .marketplace))),
            Scene(name: "plugins-skills", width: 1180, content: AnyView(PluginsRouteScene(tab: .skills))),
            Scene(name: "plugins-manage", width: 1180, content: AnyView(PluginsRouteScene(tab: .manage))),
            Scene(name: "plugins-manage-apps", width: 1180, content: AnyView(PluginsRouteScene(tab: .manage, manageTab: .apps))),
            Scene(name: "plugins-manage-mcps", width: 1180, content: AnyView(PluginsRouteScene(tab: .manage, manageTab: .mcps))),
            Scene(name: "plugins-manage-skills", width: 1180, content: AnyView(PluginsRouteScene(tab: .manage, manageTab: .skills))),
            Scene(name: "plugins-manage-marketplace", width: 1180, content: AnyView(PluginsRouteScene(tab: .manage, manageTab: .marketplace))),
            Scene(name: "chips", width: 720, content: AnyView(ChipSpecimen()))
        ]
    }

    static func run() throws {
        var outputDirectory = URL(fileURLWithPath: "build/gallery")
        var scale: CGFloat = 2
        var onlyTheme: String?

        var arguments = Array(CommandLine.arguments.dropFirst())
        while let flag = arguments.first {
            arguments.removeFirst()
            switch flag {
            case "--out":
                guard let value = arguments.first else { throw GalleryError.missingValue(flag) }
                arguments.removeFirst()
                outputDirectory = URL(fileURLWithPath: value)
            case "--scale":
                guard let value = arguments.first, let parsed = Double(value) else {
                    throw GalleryError.missingValue(flag)
                }
                arguments.removeFirst()
                scale = CGFloat(parsed)
            case "--theme":
                guard let value = arguments.first else { throw GalleryError.missingValue(flag) }
                arguments.removeFirst()
                onlyTheme = value
            default:
                throw GalleryError.unknownFlag(flag)
            }
        }

        let presets = CodexAgentThemePreset.allCases.filter {
            onlyTheme == nil || $0.rawValue == onlyTheme
        }
        guard !presets.isEmpty else { throw GalleryError.noSuchTheme(onlyTheme ?? "") }

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        var written = 0
        for preset in presets {
            for scheme in [ColorScheme.light, .dark] {
                // Resolved rather than adaptive: ImageRenderer has no window, so
                // an adaptive color would resolve against the process appearance
                // and both variants would come out identical.
                var theme = preset.theme(resolvedFor: scheme)
                theme.fonts = .official(baseTextSize: 14)
                // Engages the opaque fallback: real glass would render as
                // nothing at all offscreen.
                theme.effects.usesLiquidGlass = false

                for scene in scenes() {
                    let url = outputDirectory.appendingPathComponent(
                        "\(scene.name)-\(preset.rawValue)-\(scheme == .dark ? "dark" : "light").png"
                    )
                    try render(
                        scene: scene,
                        theme: theme,
                        scheme: scheme,
                        scale: scale,
                        to: url
                    )
                    written += 1
                }
            }
        }

        FileHandle.standardError.write(
            Data("Wrote \(written) images to \(outputDirectory.path)\n".utf8)
        )
    }

    private static func render(
        scene: Scene,
        theme: CodexAgentTheme,
        scheme: ColorScheme,
        scale: CGFloat,
        to url: URL
    ) throws {
        let root = scene.content
            .padding(24)
            .frame(width: scene.width, alignment: .leading)
            .background(theme.colors.canvas)
            .codexAgentTheme(theme)
            .environment(\.colorScheme, scheme)

        if scene.name.hasPrefix("plugins-") || scene.name == "agent-panel-completed" {
            try renderHosted(root, width: scene.width, height: 768, to: url)
            return
        }

        let renderer = ImageRenderer(content: root)
        renderer.scale = scale
        renderer.isOpaque = true

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
        else {
            throw GalleryError.renderFailed(scene.name)
        }
        try png.write(to: url)
    }

    private static func renderHosted<Content: View>(
        _ content: Content,
        width: CGFloat,
        height: CGFloat,
        to url: URL
    ) throws {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let view = NSHostingView(rootView: content)
        view.frame = bounds
        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded()
        realizeTableRows(in: view)
        view.displayIfNeeded()

        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw GalleryError.renderFailed("hosted scene")
        }
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw GalleryError.renderFailed("hosted scene")
        }
        try png.write(to: url)
    }

    private static func realizeTableRows(in view: NSView) {
        if let table = view as? NSTableView {
            table.reloadData()
            table.layoutSubtreeIfNeeded()
            for row in 0..<min(table.numberOfRows, 20) {
                _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
                _ = table.rowView(atRow: row, makeIfNecessary: true)
            }
            table.displayIfNeeded()
        }
        view.subviews.forEach(realizeTableRows)
    }

    enum GalleryError: Error, CustomStringConvertible {
        case missingValue(String)
        case unknownFlag(String)
        case noSuchTheme(String)
        case renderFailed(String)

        var description: String {
            switch self {
            case .missingValue(let flag): "Missing value for \(flag)"
            case .unknownFlag(let flag): "Unknown flag \(flag)"
            case .noSuchTheme(let name): "No theme named \(name)"
            case .renderFailed(let scene): "Could not render scene \(scene)"
            }
        }
    }
}

// MARK: - Scenes

private struct SpecimenSection<Content: View>: View {
    @Environment(\.codexAgentTheme) private var theme
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            Text(title.uppercased())
                .font(theme.fonts.micro)
                .foregroundStyle(theme.colors.textTertiary)
            content
        }
    }
}

private struct TypographySpecimen: View {
    @Environment(\.codexAgentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.lg) {
            SpecimenSection(title: "Headings") {
                VStack(alignment: .leading, spacing: theme.spacing.xs) {
                    Text("heroTitle — What should we work on?")
                        .font(theme.fonts.heroTitle)
                    Text("routeTitle — Plugins")
                        .font(theme.fonts.routeTitle)
                    Text("sheetTitle — Command menu")
                        .font(theme.fonts.sheetTitle)
                    Text("panelTitle — Approval needed")
                        .font(theme.fonts.panelTitle)
                }
                .foregroundStyle(theme.colors.textPrimary)
            }

            SpecimenSection(title: "Body and labels") {
                VStack(alignment: .leading, spacing: theme.spacing.xs) {
                    Text("chat — The quick brown fox jumps over the lazy dog.")
                        .font(theme.fonts.chat)
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("body — The quick brown fox jumps over the lazy dog.")
                        .font(theme.fonts.body)
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("label — Source folders")
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("caption — Codex runs in the primary folder.")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                    Text("chipLabel — gpt-5-codex")
                        .font(theme.fonts.chipLabel)
                        .foregroundStyle(theme.colors.textSecondary)
                }
            }

            SpecimenSection(title: "Monospace") {
                VStack(alignment: .leading, spacing: theme.spacing.xs) {
                    Text("code — let x = compute(42)")
                        .font(theme.fonts.code)
                        .foregroundStyle(theme.colors.codeText)
                    Text("micro — +128 −44")
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }

            SpecimenSection(title: "Accent roles") {
                HStack(spacing: theme.spacing.md) {
                    Text("accentText")
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.accentText)
                    Text("onAccent")
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.onAccent)
                        .padding(.horizontal, theme.spacing.sm)
                        .padding(.vertical, theme.spacing.xs)
                        .background(theme.colors.accent, in: Capsule())
                    Text("danger")
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.danger)
                    Text("success")
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.success)
                }
            }
        }
    }
}

private struct SpacingSpecimen: View {
    @Environment(\.codexAgentTheme) private var theme

    var body: some View {
        let ramp: [(String, CGFloat)] = [
            ("xxs", theme.spacing.xxs), ("xs", theme.spacing.xs),
            ("sm", theme.spacing.sm), ("md", theme.spacing.md),
            ("lg", theme.spacing.lg), ("xl", theme.spacing.xl),
            ("xxl", theme.spacing.xxl)
        ]
        let roles: [(String, CGFloat)] = [
            ("rowPadding", theme.spacing.rowPadding),
            ("panelPadding", theme.spacing.panelPadding),
            ("sectionGap", theme.spacing.sectionGap),
            ("sheetPadding", theme.spacing.sheetPadding)
        ]

        return VStack(alignment: .leading, spacing: theme.spacing.lg) {
            SpecimenSection(title: "Ramp") {
                VStack(alignment: .leading, spacing: theme.spacing.xs) {
                    ForEach(ramp, id: \.0) { bar($0.0, $0.1) }
                }
            }
            SpecimenSection(title: "Roles") {
                VStack(alignment: .leading, spacing: theme.spacing.xs) {
                    ForEach(roles, id: \.0) { bar($0.0, $0.1) }
                }
            }
            SpecimenSection(title: "Radii") {
                HStack(spacing: theme.spacing.md) {
                    radius("small", theme.radii.small)
                    radius("medium", theme.radii.medium)
                    radius("large", theme.radii.large)
                    radius("panel", theme.radii.panel)
                }
            }
        }
    }

    private func bar(_ label: String, _ value: CGFloat) -> some View {
        HStack(spacing: theme.spacing.sm) {
            Text(label)
                .font(theme.fonts.code)
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: 96, alignment: .leading)
            Rectangle()
                .fill(theme.colors.accent)
                .frame(width: max(value, 1), height: 10)
            Text("\(Int(value))")
                .font(theme.fonts.micro)
                .foregroundStyle(theme.colors.textTertiary)
        }
    }

    private func radius(_ label: String, _ value: CGFloat) -> some View {
        VStack(spacing: theme.spacing.xs) {
            RoundedRectangle(cornerRadius: value, style: .continuous)
                .fill(theme.colors.surfaceElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: value, style: .continuous)
                        .stroke(theme.colors.border, lineWidth: 1)
                }
                .frame(width: 76, height: 56)
            Text(label)
                .font(theme.fonts.micro)
                .foregroundStyle(theme.colors.textTertiary)
        }
    }
}

private struct GlassRoleSpecimen: View {
    @Environment(\.codexAgentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            Text("Rendered as the opaque fallback. Real Liquid Glass cannot be captured offscreen.")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)

            CodexGlassGroup(spacing: theme.spacing.md) {
                HStack(spacing: theme.spacing.md) {
                    ForEach(CodexGlassRole.allCases, id: \.self) { role in
                        Text(String(describing: role))
                            .font(theme.fonts.chipLabel)
                            .foregroundStyle(theme.colors.textPrimary)
                            .padding(.horizontal, theme.spacing.md)
                            .padding(.vertical, theme.spacing.sm)
                            .codexGlass(
                                RoundedRectangle(
                                    cornerRadius: theme.radii.medium,
                                    style: .continuous
                                ),
                                role: role
                            )
                    }
                }
            }

            SpecimenSection(title: "Interaction states") {
                HStack(spacing: theme.spacing.md) {
                    state("rest", theme.colors.hover.opacity(0))
                    state("hover", theme.colors.hover.opacity(theme.effects.hoverOpacity))
                    state("pressed", theme.colors.hover.opacity(theme.effects.pressedOpacity))
                    state("selected", theme.colors.selection.opacity(theme.effects.selectionOpacity))
                }
            }
        }
    }

    private func state(_ label: String, _ fill: Color) -> some View {
        Text(label)
            .font(theme.fonts.chipLabel)
            .foregroundStyle(theme.colors.textPrimary)
            .frame(width: 96, height: 34)
            .background(fill, in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            }
    }
}

private struct PaletteSpecimen: View {
    @Environment(\.codexAgentTheme) private var theme

    var body: some View {
        let groups: [(String, [(String, Color)])] = [
            ("Surfaces", [
                ("canvas", theme.colors.canvas),
                ("surface", theme.colors.surface),
                ("surfaceSunken", theme.colors.surfaceSunken),
                ("surfaceElevated", theme.colors.surfaceElevated)
            ]),
            ("Text", [
                ("textPrimary", theme.colors.textPrimary),
                ("textSecondary", theme.colors.textSecondary),
                ("textTertiary", theme.colors.textTertiary)
            ]),
            ("Accent", [
                ("accent", theme.colors.accent),
                ("accentStrong", theme.colors.accentStrong),
                ("accentText", theme.colors.accentText),
                ("accentSoft", theme.colors.accentSoft),
                ("onAccent", theme.colors.onAccent)
            ]),
            ("Status", [
                ("success", theme.colors.success),
                ("warning", theme.colors.warning),
                ("danger", theme.colors.danger),
                ("running", theme.colors.running),
                ("tool", theme.colors.tool)
            ]),
            ("Code", [
                ("codeBackground", theme.colors.codeBackground),
                ("codeText", theme.colors.codeText),
                ("codeKeyword", theme.colors.codeKeyword),
                ("codeString", theme.colors.codeString),
                ("codeComment", theme.colors.codeComment),
                ("codeNumber", theme.colors.codeNumber)
            ])
        ]

        return VStack(alignment: .leading, spacing: theme.spacing.md) {
            ForEach(groups, id: \.0) { group in
                SpecimenSection(title: group.0) {
                    HStack(spacing: theme.spacing.sm) {
                        ForEach(group.1, id: \.0) { swatch($0.0, $0.1) }
                    }
                }
            }
        }
    }

    private func swatch(_ label: String, _ color: Color) -> some View {
        VStack(spacing: theme.spacing.xxs) {
            RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                .fill(color)
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                        .stroke(theme.colors.border, lineWidth: 1)
                }
                .frame(height: 40)
            Text(label)
                .font(theme.fonts.micro)
                .foregroundStyle(theme.colors.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct ChipSpecimen: View {
    @Environment(\.codexAgentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            SpecimenSection(title: "Status") {
                HStack(spacing: theme.spacing.sm) {
                    chip("running", theme.colors.running)
                    chip("done", theme.colors.success)
                    chip("failed", theme.colors.danger)
                    chip("waiting", theme.colors.warning)
                    chip("tool", theme.colors.tool)
                }
            }
            SpecimenSection(title: "Diff counters") {
                HStack(spacing: theme.spacing.md) {
                    Text("+128")
                        .font(theme.fonts.micro.monospacedDigit())
                        .foregroundStyle(theme.colors.success)
                    Text("−44")
                        .font(theme.fonts.micro.monospacedDigit())
                        .foregroundStyle(theme.colors.danger)
                    Text("3 files")
                        .font(theme.fonts.micro.monospacedDigit())
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }
        }
    }

    private func chip(_ label: String, _ tint: Color) -> some View {
        HStack(spacing: theme.spacing.xs) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label)
                .font(theme.fonts.chipLabel)
                .foregroundStyle(theme.colors.textSecondary)
        }
        .padding(theme.spacing.chipPadding)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.3), lineWidth: 1))
    }
}

private struct PlanPanelScene: View {
    var body: some View {
        CodexTurnPlanPanel(
            steps: [
                TurnPlanStep(step: "Audit the glass call sites", status: .completed),
                TurnPlanStep(step: "Add the typography scale", status: .completed),
                TurnPlanStep(step: "Make themes dual-appearance", status: .inProgress),
                TurnPlanStep(step: "Render the gallery", status: .pending)
            ],
            explanation: "Working through the visual glowup in commits."
        )
    }
}

private struct SummaryPlanAndChangesScene: View {
    private let plan = CodexPlanSummary(
        steps: [
            TurnPlanStep(step: "Inspect the official bundle", status: .completed),
            TurnPlanStep(step: "Unify Plan and Changes ownership", status: .inProgress),
            TurnPlanStep(step: "Validate controlled Git scenarios", status: .pending),
        ],
        explanation: "Review workbench parity"
    )

    private let review = CodexGitReviewSession(
        snapshot: CodexGitReviewSnapshot(
            branchName: "codex/review-workbench-170",
            files: [
                CodexGitReviewFileChange(
                    path: "Sources/ReviewWorkbench.swift",
                    status: .modified,
                    isStaged: false,
                    addedLines: 56,
                    removedLines: 11
                )
            ]
        )
    )

    var body: some View {
        CodexFloatingSummaryPanel(
            sideChat: nil,
            subagents: [],
            workspaceSummary: CodexWorkspaceSummaryContext(
                workspacePath: "/Users/person/Projects/CodexCore",
                gitBranch: "codex/review-workbench-170",
                plan: plan
            ),
            gitReviewSession: review,
            onSelectTab: { _ in }
        )
        .padding(24)
    }
}

private struct AgentPanelCompletedScene: View {
    @StateObject private var workspaceTabs = CodexWorkspaceTabs()
    @State private var panelWidth: CGFloat = 620

    private let review = CodexGitReviewSession(
        snapshot: CodexGitReviewSnapshot(
            branchName: "codex/fix-agent-panel-glitches",
            files: []
        )
    )

    var body: some View {
        CodexAgentSidePanel(
            tabs: [],
            workspaceTabs: workspaceTabs,
            width: $panelWidth,
            showsCloseButton: true,
            onClose: {}
        )
        .frame(height: 720)
        .onAppear {
            workspaceTabs.open(
                CodexReviewWorkspaceTabAdapter(
                    workspaceURL: URL(fileURLWithPath: "/tmp"),
                    session: review
                ),
                from: .summary
            )
        }
    }
}

private struct TranscriptTurnChangesScene: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CodexTranscriptTurnDiffGalleryFixture()
            Text("The Review workbench now keeps turn edits beside the final response.")
        }
    }
}

private struct ReviewWorkbenchScene: View {
    var body: some View {
        CodexGitReviewWorkbenchGalleryFixture()
    }
}

private struct MCPSheetScene: View {
    var body: some View {
        CodexMCPStatusSheet(
            servers: [
                CodexMCPServerStatus(
                    name: "filesystem",
                    displayName: "Filesystem",
                    version: "1.4.2",
                    authStatus: "connected",
                    startupStatus: "ready",
                    tools: [.init(name: "read_file"), .init(name: "write_file")]
                ),
                CodexMCPServerStatus(
                    name: "context7",
                    displayName: "Context7",
                    version: "0.9.0",
                    authStatus: "connected",
                    startupStatus: "ready",
                    tools: [.init(name: "query_docs")]
                ),
                CodexMCPServerStatus(
                    name: "linear",
                    displayName: "Linear",
                    authStatus: "needs auth",
                    startupStatus: "failed",
                    error: "Authorization required before tools are available."
                )
            ],
            isLoading: false,
            errorMessage: nil,
            onClose: {},
            onRefresh: {}
        )
        .fixedSize()
    }
}

private struct PluginsRouteScene: View {
    let tab: CodexPluginRoutePrimaryTab
    var manageTab: CodexPluginManageTab = .plugins

    private let plugins = [
        CodexPluginSummary(
            id: "openai:computer-use",
            protocolID: "computer-use@openai-bundled",
            name: "computer-use",
            displayName: "Computer Use",
            shortDescription: "Control Mac apps with Codex",
            marketplaceName: "openai-bundled",
            marketplaceDisplayName: "By OpenAI",
            category: "Featured",
            developerName: "OpenAI",
            installPolicy: "AVAILABLE",
            capabilities: ["Interactive", "Read", "Write"],
            isFeatured: true
        ),
        CodexPluginSummary(
            id: "openai:browser",
            protocolID: "browser@openai-bundled",
            name: "browser",
            displayName: "Browser",
            shortDescription: "Control the in-app browser with Codex",
            longDescription: "Open and control the in-app browser for local development pages and files.",
            marketplaceName: "openai-bundled",
            marketplaceDisplayName: "By OpenAI",
            category: "Engineering",
            developerName: "OpenAI",
            installed: true,
            enabled: true,
            installPolicy: "INSTALLED_BY_DEFAULT",
            localVersion: "26.616.81150",
            defaultPrompt: "Browser\nTest my checkout flow on localhost",
            websiteURL: "https://openai.com",
            privacyPolicyURL: "https://openai.com/privacy",
            termsOfServiceURL: "https://openai.com/terms",
            capabilities: ["Interactive", "Read", "Write"],
            isFeatured: true
        ),
        CodexPluginSummary(
            id: "openai:github",
            protocolID: "github@openai-curated",
            name: "github",
            displayName: "GitHub",
            shortDescription: "Triage repositories, issues, and pull requests",
            marketplaceName: "openai-curated",
            marketplaceDisplayName: "By OpenAI",
            category: "Developer tools",
            developerName: "OpenAI",
            installed: true,
            enabled: true,
            installPolicy: "AVAILABLE",
            sourceType: "remote",
            capabilities: ["apps", "skills"]
        )
    ]

    private let apps = [
        CodexAppSummary(
            id: "github-app",
            name: "GitHub",
            description: "Use GitHub tools from Codex.",
            isAccessible: true,
            isEnabled: true,
            isInstalled: true,
            runtimeName: "github",
            runtimeEnabled: true,
            runtimeCallable: true
        ),
        CodexAppSummary(
            id: "slack-app",
            name: "Slack",
            description: "Search and summarize Slack conversations.",
            isAccessible: true,
            isEnabled: nil,
            isInstalled: false
        )
    ]

    private let marketplaces = [
        CodexMarketplaceSummary(
            name: "openai-bundled",
            displayName: "OpenAI bundled",
            path: "/registered/openai-bundled/marketplace.json",
            pluginCount: 7
        ),
        CodexMarketplaceSummary(
            name: "team-tools",
            displayName: "Team tools",
            path: nil,
            pluginCount: 3
        )
    ]

    private let skills = [
        CodexSkillSummary(
            name: "browser:control-in-app-browser",
            displayName: "Browser: Control in-app browser",
            description: "Open, navigate, and inspect pages in Codex's in-app browser.",
            path: "/tmp/openai-bundled/browser/skills/control-in-app-browser/SKILL.md",
            scope: "user",
            enabled: true,
            defaultPrompt: "Open the in-app browser and inspect my local application."
        ),
        CodexSkillSummary(
            name: "agents-sdk",
            displayName: "Agents SDK",
            description: "Build AI agents on Cloudflare Workers using the Agents SDK.",
            path: "/tmp/skills/agents-sdk/SKILL.md",
            scope: "user",
            enabled: true
        ),
        CodexSkillSummary(
            name: "imagegen",
            displayName: "Image generation",
            description: "Generate and edit raster images.",
            path: "/tmp/system-skills/imagegen/SKILL.md",
            scope: "system",
            enabled: true
        )
    ]

    var body: some View {
        CodexPluginRouteView(
            plugins: plugins,
            marketplaces: marketplaces,
            apps: apps,
            skills: skills,
            mcpServers: [CodexMCPServerStatus(name: "filesystem", displayName: "Filesystem", startupStatus: "ready")],
            initialTab: tab,
            initialManageTab: manageTab,
            onRefresh: {},
            onAction: { _ in }
        )
        .frame(height: 720)
    }
}

do {
    try Gallery.run()
} catch {
    FileHandle.standardError.write(Data("codex-ui-gallery: \(error)\n".utf8))
    exit(1)
}
