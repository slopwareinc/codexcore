import CodexCore
import SwiftUI

/// A drop-in SwiftUI monospaced terminal view that binds to a live `command/exec` session.
///
/// It listens to the standard output stream, decodes ANSI escape codes,
/// updates styled segments, and handles keyboard inputs natively.
@available(macOS 14.0, iOS 17.0, *)
public struct CodexTerminalView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let session: CodexCommandExecSession
    private let parser = ANSIParser()

    @State private var segments: [ANSISegment] = []
    @State private var rawText = ""
    @State private var copied = false
    @State private var wrapsOutput = false

    public init(session: CodexCommandExecSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("shell")
                    .font(theme.fonts.micro)
                    .foregroundStyle(theme.colors.codeFaint)
                Spacer(minLength: 0)
                Button {
                    wrapsOutput.toggle()
                } label: {
                    Image(systemName: wrapsOutput ? "text.line.first.and.arrowtriangle.forward" : "text.alignleft")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.codeFaint)
                }
                .buttonStyle(.plain)
                .help(wrapsOutput ? "Disable wrapping" : "Wrap output")
                CodexCopyButton(copied: $copied) { copyToPasteboard(rawText) }
                    .disabled(rawText.isEmpty)
                    .opacity(rawText.isEmpty ? 0.45 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(theme.colors.codeHeader)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        terminalText

                        Spacer()
                            .frame(height: 1)
                            .id("bottom-marker")
                    }
                    .padding(theme.spacing.rowGap)
                }
                .task {
                    // Listen to raw stdout/stderr delta chunks from the PTY session
                    for await delta in session.outputStream {
                        guard let text = String(data: delta.data, encoding: .utf8) else { continue }

                        // Append stream chunk to local text buffer
                        rawText.append(text)

                        // Keep buffer history bounded to prevent memory build-up (e.g. 50,000 characters)
                        if rawText.count > 50000 {
                            rawText = String(rawText.suffix(30000))
                        }

                        // Reparse styling segments
                        segments = parser.parse(rawText)

                        // Scroll to bottom marker
                        withAnimation(.easeOut(duration: theme.animations.defaultDuration)) {
                            proxy.scrollTo("bottom-marker", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(theme.colors.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border.opacity(0.78), lineWidth: 1)
        )
        .focusable()
        .onKeyPress { keyPress in
            let chars = keyPress.characters
            guard !chars.isEmpty else { return .ignored }

            if let data = chars.data(using: .utf8) {
                Task {
                    try? await session.write(data: data)
                }
                return .handled
            }
            return .ignored
        }
    }

    @ViewBuilder
    private var terminalText: some View {
        if wrapsOutput {
            Text(ANSITerminalStyle.makeAttributedString(from: segments))
                .font(theme.fonts.code)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(ANSITerminalStyle.makeAttributedString(from: segments))
                    .font(theme.fonts.code)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
    }
}
