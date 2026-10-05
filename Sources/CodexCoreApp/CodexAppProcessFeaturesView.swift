import SwiftUI
import CodexCoreUI

struct CodexAppProcessFeaturesView: View {
    @Bindable var features: CodexAppProcessFeatures
    let workspacePath: String
    let threadID: String?
    @State private var mode: CodexAppProcessFeatures.Mode = .command
    @State private var arguments = ""
    @State private var cwd = ""
    @State private var tty = false
    @State private var stdin = ""
    @State private var rows = 30
    @State private var cols = 100
    @State private var draft: Draft?
    private struct Draft { let mode: CodexAppProcessFeatures.Mode; let arguments: [String]; let cwd: String; let tty: Bool; let threadID: String?; let context: Int }

    var body: some View {
        Form {
            Section("Run through Codex") {
                Picker("Execution", selection: $mode) { ForEach(CodexAppProcessFeatures.Mode.allCases) { Text($0.rawValue).tag($0) } }
                Text(mode == .shell ? "Enter one shell command. Its result appears in the chat." : "Enter the executable on the first line and one argument per following line.").foregroundStyle(.secondary)
                TextEditor(text: $arguments).font(.system(.body, design: .monospaced)).frame(height: 90)
                TextField("Working directory", text: $cwd)
                Toggle("Pseudo-terminal", isOn: $tty).disabled(mode == .shell)
                HStack {
                    Button("Run") { draft = .init(mode: mode, arguments: mode == .shell ? [arguments] : arguments.components(separatedBy: "\n"), cwd: cwd, tty: tty, threadID: threadID, context: features.contextVersion) }
                        .disabled(features.isRunning || features.isStarting)
                    Button("Stop") { Task { await features.stop() } }.disabled(!features.isRunning || mode == .shell)
                    if features.isRunning { ProgressView().controlSize(.small) }
                    if let code = features.exitCode { Text("Exit \(code)").foregroundStyle(.secondary) }
                }
                if let error = features.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if features.capReached { Text("Output was capped at 128 KiB per stream.").foregroundStyle(.secondary) }
            }
            Section("Input and terminal") {
                TextField("Standard input", text: $stdin)
                HStack {
                    Button("Send") { Task { await features.write(stdin, closeStdin: false) } }
                    Button("Close stdin") { Task { await features.write("", closeStdin: true) } }
                }
                HStack {
                    Stepper("Rows: \(rows)", value: $rows, in: 1...1000)
                    Stepper("Columns: \(cols)", value: $cols, in: 1...1000)
                    Button("Resize") { Task { await features.resize(rows: rows, cols: cols) } }
                }
            }.disabled(!features.isRunning || mode == .shell)
            Section("Standard output") { Text(features.stdout.isEmpty ? "No output" : features.stdout).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            Section("Standard error") { Text(features.stderr.isEmpty ? "No output" : features.stderr).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
        }.formStyle(.grouped)
            .onAppear { if cwd.isEmpty { cwd = workspacePath } }
            .onChange(of: features.contextVersion) { draft = nil }
            .confirmationDialog("Run this command?", isPresented: Binding(get: { draft != nil }, set: { if !$0 { draft = nil } }), presenting: draft) { value in
                Button("Run") {
                    draft = nil
                    guard value.context == features.contextVersion else { return }
                    Task { await features.start(mode: value.mode, arguments: value.arguments, cwd: value.cwd, tty: value.tty, threadID: value.threadID) }
                }
            } message: { value in Text("\(value.arguments.joined(separator: " "))\n\(value.cwd)") }
    }
}
