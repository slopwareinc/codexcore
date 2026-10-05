import SwiftUI
import CodexCoreUI

struct CodexAppFileFeaturesView: View {
    @Bindable var features: CodexAppFileFeatures
    let roots: [String]
    @Environment(\.codexAgentTheme) private var theme
    @State private var path = ""
    @State private var destination = ""
    @State private var query = ""
    @State private var pendingAction: PendingAction?

    private struct PendingAction {
        let action: Action
        let path: String
        let destination: String
        let contents: String
        let context: Int
    }

    private enum Action { case save, copy, remove, createDirectory }

    var body: some View {
        Form {
            Section("Runtime files") {
                Text("Read and manage files through the connected Codex runtime.").foregroundStyle(.secondary)
                TextField("Absolute path", text: $path).font(.system(.body, design: .monospaced))
                HStack {
                    Button("Browse folder") { Task { await features.browse(path) } }
                    Button("Open file") { Task { await features.open(path) } }
                    if features.watchingPath == nil {
                        Button("Watch folder") { Task { await features.startWatching(path) } }
                    } else {
                        Button("Stop watching") { Task { await features.stopWatching() } }
                    }
                }
                if let watching = features.watchingPath { Text("Watching \(watching)").font(.caption).foregroundStyle(.secondary) }
                if let error = features.error { Text(error).foregroundStyle(theme.colors.danger) }
                if let message = features.message { Text(message).foregroundStyle(.secondary) }
                ForEach(features.entries, id: \.fileName) { entry in
                    Button {
                        let target = URL(fileURLWithPath: features.directory).appendingPathComponent(entry.fileName).path
                        path = target
                        Task { if entry.isDirectory { await features.browse(target) } else { await features.open(target) } }
                    } label: {
                        Label(entry.fileName, systemImage: entry.isDirectory ? "folder" : "doc")
                    }.buttonStyle(.plain)
                }
            }
            Section("Text editor") {
                if let opened = features.openedPath { Text(opened).font(.caption).foregroundStyle(.secondary) }
                TextEditor(text: $features.text).font(.system(.body, design: .monospaced)).frame(minHeight: 180)
                Button("Save file…") { ask(.save) }.disabled(path.isEmpty)
            }
            Section("File actions") {
                TextField("Destination path for copy", text: $destination)
                HStack {
                    Button("Copy…") { ask(.copy) }.disabled(destination.isEmpty)
                    Button("Create folder…") { ask(.createDirectory) }
                    Button("Remove…", role: .destructive) { ask(.remove) }
                }.disabled(path.isEmpty)
            }
            Section("Search workspace files") {
                TextField("Search", text: $query).onSubmit { Task { await features.search(query: query, roots: roots) } }
                HStack {
                    Button("Search") { Task { await features.search(query: query, roots: roots) } }.disabled(query.isEmpty || roots.isEmpty)
                    Button("Stop search") { Task { await features.stopSearch() } }
                }
                ForEach(features.searchResults, id: \.path) { result in
                    Button(result.path) {
                        let target = result.path.hasPrefix("/") ? result.path : URL(fileURLWithPath: result.root).appendingPathComponent(result.path).path
                        path = target
                        Task { await features.open(target) }
                    }.buttonStyle(.plain).font(.caption)
                }
            }
        }
        .formStyle(.grouped).disabled(features.isLoading)
        .overlay(alignment: .topTrailing) { if features.isLoading { ProgressView().padding() } }
        .task { if path.isEmpty, let root = roots.first { path = root; await features.browse(root) } }
        .confirmationDialog("Confirm file operation", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
            Button(pendingAction?.action == .remove ? "Remove" : "Continue", role: pendingAction?.action == .remove ? .destructive : nil) {
                guard let pending = pendingAction else { return }
                pendingAction = nil
                guard pending.context == features.contextVersion else { return }
                let action = pending.action, path = pending.path, destination = pending.destination
                Task {
                    switch action {
                    case .save: await features.save(path: path, contents: pending.contents)
                    case .copy: await features.copy(from: path, to: destination, recursive: true)
                    case .remove: await features.remove(path, recursive: true)
                    case .createDirectory: await features.createDirectory(path)
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { Text(pendingAction?.path ?? "") }
    }

    private func ask(_ action: Action) {
        pendingAction = .init(action: action, path: path, destination: destination,
                              contents: features.text, context: features.contextVersion)
    }
}
