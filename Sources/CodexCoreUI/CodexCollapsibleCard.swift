import SwiftUI

@available(macOS 14.0, iOS 17.0, *)
struct CodexCollapsibleCard<Header: View, Body: View>: View {
    @Environment(\.codexAgentTheme) private var theme

    private let background: Color
    private let border: Color
    private let maxWidth: CGFloat
    private let animationDuration: Double
    private let isExpanded: Binding<Bool>
    private let header: (Bool, @escaping () -> Void) -> Header
    private let bodyContent: () -> Body

    init(
        isExpanded: Binding<Bool>,
        background: Color,
        border: Color,
        maxWidth: CGFloat,
        animationDuration: Double = 0.22,
        @ViewBuilder header: @escaping (Bool, @escaping () -> Void) -> Header,
        @ViewBuilder body: @escaping () -> Body
    ) {
        self.isExpanded = isExpanded
        self.background = background
        self.border = border
        self.maxWidth = maxWidth
        self.animationDuration = animationDuration
        self.header = header
        self.bodyContent = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(isExpanded.wrappedValue, { toggle() })
            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(theme.colors.border).frame(height: 1)
                    bodyContent()
                }
            }
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
        .frame(maxWidth: maxWidth, alignment: .leading)
    }

    private func toggle() {
        withAnimation(.snappy(duration: animationDuration)) { isExpanded.wrappedValue.toggle() }
    }
}
