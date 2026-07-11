import SwiftUI

public struct CodexEmptyTranscriptView: View {
    public struct Prompt: Equatable, Sendable {
        public var prompt: String
        public var detail: String?
        public init(prompt: String, detail: String? = nil) { self.prompt = prompt; self.detail = detail }
    }

    public static let defaultPrompts = [
        Prompt(prompt: "Debug an issue"), Prompt(prompt: "Plan implementation"),
        Prompt(prompt: "Write tests"), Prompt(prompt: "Connect your favorite apps to Codex")
    ]
    private let onSelect: (String) -> Void
    public init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.defaultPrompts, id: \.prompt) { item in
                Button(item.prompt) { onSelect(item.prompt) }.buttonStyle(.plain)
            }
        }.padding()
    }
}
