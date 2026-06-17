import SwiftUI

/// A drop-in SwiftUI monospaced terminal view that binds to a live `command/exec` session.
///
/// It listens to the standard output stream, decodes ANSI escape codes,
/// updates styled segments, and handles keyboard inputs natively.
@available(macOS 14.0, iOS 17.0, *)
public struct CodexTerminalView: View {
    private let session: CodexCommandExecSession
    private let parser = ANSIParser()

    @State private var segments: [ANSISegment] = []
    @State private var rawText = ""

    public init(session: CodexCommandExecSession) {
        self.session = session
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text(parser.makeAttributedString(from: segments))
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    Spacer()
                        .frame(height: 1)
                        .id("bottom-marker")
                }
                .padding(8)
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.05))
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
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom-marker", anchor: .bottom)
                    }
                }
            }
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
    }
}
