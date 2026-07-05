import SwiftUI

/// Shared loading spinner used across chips, sheets, patches, and overlays.
/// Replaces the bare `ProgressView()` that was previously dropped into 6×6
/// status chips, 14-point sheet rows and 18-point palette headers — the same
/// default Apple control was rendering at three visibly different sizes.
///
/// The spinner is a single stroked arc with a rounded cap that repeats a 360°
/// rotation. It scales through three explicit sizes (mini / small / medium)
/// corresponding to chip / row / overlay usage, and accepts an optional
/// color override for tinted contexts (status chips, subagent running tint).
public struct CodexSpinner: View {
    @Environment(\.codexAgentTheme) private var theme

    public enum Size: Sendable {
        case mini
        case small
        case medium
    }

    private let color: Color?
    private let size: Size
    @State private var rotation: Double = 0

    public init(color: Color? = nil, size: Size = .small) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(
                color ?? theme.colors.accent,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: edge, height: edge)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .accessibilityLabel("Loading")
    }

    private var edge: CGFloat {
        switch size {
        case .mini: return 10
        case .small: return 14
        case .medium: return 18
        }
    }

    private var lineWidth: CGFloat {
        switch size {
        case .mini: return 1.5
        case .small: return 1.75
        case .medium: return 2
        }
    }
}