import SwiftUI

// Liquid Glass surface vocabulary.
//
// Every glass surface in the app goes through `codexGlass(_:role:tint:)` so the
// decisions Apple's material guidance makes for us stay in one place:
//
// - `.regular` is the default. It carries its own legibility, so it works over
//   arbitrary content. `.clear` is reserved for surfaces floating directly over
//   user content that we dim ourselves (`.hud`).
// - Glass renders its own edge highlight and its own shadow. Views must not add
//   a stroke or a drop shadow on top of a glass surface; doing so is what makes
//   glass read as a hand-drawn imitation of itself.
// - `interactive()` belongs to surfaces that *are* controls, and to nothing
//   else. A container that merely holds controls must not be interactive, or
//   the whole group flexes when any child is pressed.
// - Sibling glass surfaces belong in a `CodexGlassGroup` so the system can
//   merge and morph them as they move, and render them in a single pass.
//
// The effect degrades in two independent ways. `Effects.usesLiquidGlass` is the
// theme's own opt-out (High Contrast), and `accessibilityReduceTransparency` is
// the system's. Either one falls back to an opaque surface, because a
// half-transparent "compromise" satisfies neither.

/// What a glass surface *is*, rather than how it should look. The role picks the
/// variant, the interactivity, and the fallback treatment.
public enum CodexGlassRole: Sendable, Hashable, CaseIterable {
    /// Window chrome that frames content: sidebar, toolbar backgrounds.
    case chrome
    /// A panel floating above content: approval prompts, plan panels, popovers.
    case panel
    /// A modal sheet.
    case sheet
    /// A single control that should flex in response to pointer interaction.
    case control
    /// A capsule that groups multiple controls without flexing as one control.
    case controlGroup
    /// A small inline pill: composer chips, status pills.
    case chip
    /// A transient surface directly over user content, dimmed by us for legibility.
    case hud

    /// `.clear` only where we supply our own dimming; `.regular` everywhere else.
    var prefersClearVariant: Bool {
        self == .hud
    }

    /// Interactive glass flexes under a press. Only true controls want that.
    var isInteractive: Bool {
        switch self {
        case .control, .chip: true
        case .chrome, .panel, .sheet, .controlGroup, .hud: false
        }
    }

    /// Whether the opaque fallback should carry a shadow to stand in for the one
    /// real glass draws for itself. Chrome is flush with the window edge and
    /// never had one.
    var fallbackCastsShadow: Bool {
        switch self {
        case .panel, .sheet, .hud: true
        case .chrome, .control, .controlGroup, .chip: false
        }
    }

    /// Elevation the opaque fallback simulates, as a fraction of the theme's
    /// surface opacity. Chrome sits lowest, sheets highest.
    var fallbackElevation: Double {
        switch self {
        case .chrome: 0.88
        case .chip, .control, .controlGroup: 0.94
        case .panel, .hud: 0.97
        case .sheet: 1.0
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
private func codexGlassConfiguration(role: CodexGlassRole, tint: Color?) -> Glass {
    var glass: Glass = role.prefersClearVariant ? .clear : .regular
    if let tint {
        glass = glass.tint(tint)
    }
    if role.isInteractive {
        glass = glass.interactive()
    }
    return glass
}

public extension View {
    /// Applies Liquid Glass for a semantic role, falling back to an opaque
    /// themed surface when the theme opts out or the system asks for reduced
    /// transparency.
    ///
    /// - Parameters:
    ///   - shape: The surface outline. Prefer a `theme.radii` value.
    ///   - role: What the surface is. Drives variant, interactivity, fallback.
    ///   - tint: A *meaningful* tint — selection or emphasis. Pass `nil` for
    ///     ordinary surfaces. Tinting with a surface color to darken glass
    ///     turns it into smoked plastic; use `role` and the theme instead.
    func codexGlass<S: Shape>(
        _ shape: S,
        role: CodexGlassRole = .panel,
        tint: Color? = nil
    ) -> some View {
        modifier(CodexGlassModifier(shape: shape, role: role, tint: tint))
    }
}

private struct CodexGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let shape: S
    let role: CodexGlassRole
    let tint: Color?

    func body(content: Content) -> some View {
        if theme.effects.usesLiquidGlass, !reduceTransparency {
            // Real glass draws its own highlight and shadow. Nothing is layered
            // over or under it here, deliberately.
            content.glassEffect(
                codexGlassConfiguration(role: role, tint: tint),
                in: shape
            )
        } else {
            content
                .background(fallbackFill, in: shape)
                .overlay(shape.stroke(theme.colors.border, lineWidth: 1))
                .shadow(
                    color: role.fallbackCastsShadow
                        ? theme.effects.shadow.color(for: theme)
                        : .clear,
                    radius: role.fallbackCastsShadow ? theme.effects.shadow.radius : 0,
                    y: role.fallbackCastsShadow ? theme.effects.shadow.y : 0
                )
        }
    }

    /// An opaque stand-in. A material underlay would be invisible behind this
    /// and is omitted; the point of the fallback is that it is *not* see-through.
    private var fallbackFill: Color {
        // Chrome is part of the window frame, not content floating above it.
        // Keeping it on the recessed surface gives sidebars their intended
        // depth when glass is unavailable or transparency is reduced.
        let surface = role == .chrome
            ? theme.colors.surfaceSunken
            : theme.colors.surfaceElevated
        let base = surface
            .opacity(theme.effects.surfaceOpacity * role.fallbackElevation)
        guard let tint else { return base }
        return base.opacity(1).mix(with: tint, by: theme.effects.tintStrength)
    }
}

/// Groups sibling glass surfaces so the system merges and morphs them together
/// and renders them in one pass. Wrap adjacent glass elements — a row of
/// toolbar bubbles, a strip of composer chips — rather than leaving each to
/// sample the backdrop on its own.
///
/// Lays out nothing itself: the content keeps whatever stack it already had.
public struct CodexGlassGroup<Content: View>: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let spacing: CGFloat?
    private let content: Content

    /// - Parameter spacing: Distance within which sibling surfaces merge into
    ///   one another. `nil` uses the system default.
    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if theme.effects.usesLiquidGlass, !reduceTransparency {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

// MARK: - Button styles

public extension View {
    /// The standard glass treatment for a secondary control. Falls back to a
    /// bordered button when glass is unavailable, so the control never loses
    /// its affordance.
    @ViewBuilder
    func codexGlassButtonStyle(prominent: Bool = false) -> some View {
        modifier(CodexGlassButtonStyleModifier(prominent: prominent))
    }
}

private struct CodexGlassButtonStyleModifier: ViewModifier {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let prominent: Bool

    func body(content: Content) -> some View {
        if theme.effects.usesLiquidGlass, !reduceTransparency {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Scrim

public extension View {
    /// The dimming layer behind a modal surface, and beneath `.hud` glass.
    /// Themed rather than a fixed black, so it reads correctly on light canvases.
    func codexScrim(isPresented: Bool = true, onTap: (() -> Void)? = nil) -> some View {
        modifier(CodexScrimModifier(isPresented: isPresented, onTap: onTap))
    }
}

private struct CodexScrimModifier: ViewModifier {
    @Environment(\.codexAgentTheme) private var theme

    let isPresented: Bool
    let onTap: (() -> Void)?

    func body(content: Content) -> some View {
        content.background {
            if isPresented {
                let scrim = theme.colors.scrim.opacity(theme.effects.scrimOpacity)
                if let onTap {
                    scrim.ignoresSafeArea().onTapGesture(perform: onTap)
                } else {
                    scrim.ignoresSafeArea()
                }
            }
        }
    }
}
