import SwiftUI
import CodexCore
import CodexCoreUI

struct CodexAppProjectFeaturesView: View {
    @Bindable var features: CodexAppProjectFeatures
    @Environment(\.codexAgentTheme) private var theme
    @State private var name = ""
    @State private var folders = ""
    @State private var importedThreads = ""
    @State private var isImport = false
    @State private var pendingDeletion: CodexSchemaProject?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Synced projects").font(.headline)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await features.refresh() } }
                }
                Text("Projects and their folder order are saved by Codex and shared across clients.")
                    .foregroundStyle(.secondary)
                if let error = features.error { Text(error).foregroundStyle(theme.colors.danger) }
                if features.projects.isEmpty && !features.isLoading { Text("No synced projects yet.").foregroundStyle(.secondary) }
                ForEach(features.projects, id: \.id) { project in
                    HStack {
                        Button { Task { await features.read(project.id) } } label: {
                            VStack(alignment: .leading) {
                                Text(project.name)
                                Text(project.roots.compactMap { path($0.path) }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Menu("Move") {
                            Button("To end") { Task { await features.move(id: project.id, beforeID: nil) } }
                            ForEach(features.projects.filter { $0.id != project.id }, id: \.id) { target in
                                Button("Before \(target.name)") { Task { await features.move(id: project.id, beforeID: target.id) } }
                            }
                        }
                        Button("Delete", role: .destructive) { pendingDeletion = project }
                    }
                }
            }
            Section(features.selectedProject == nil ? "Create a project" : "Edit project") {
                TextField("Name", text: $name)
                Text("Folders, one absolute path per line. The first folder is primary.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $folders).frame(minHeight: 76).font(.system(.body, design: .monospaced))
                if features.selectedProject == nil {
                    Toggle("Import existing chats", isOn: $isImport)
                    if isImport {
                        TextField("Chat IDs, one per line", text: $importedThreads, axis: .vertical)
                    }
                }
                HStack {
                    Button(features.selectedProject == nil ? "Create project" : "Save changes") {
                        Task {
                            let roots = folders.split(separator: "\n").map(String.init)
                            if let project = features.selectedProject {
                                await features.update(id: project.id, name: name, roots: roots)
                            } else {
                                await features.create(name: name, roots: roots,
                                    threadIDs: importedThreads.split(separator: "\n").map(String.init), isImport: isImport)
                            }
                        }
                    }.buttonStyle(.borderedProminent)
                    if features.selectedProject != nil {
                        Button("New project") { name = ""; folders = ""; features.clearSelection() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(features.isLoading)
        .overlay(alignment: .topTrailing) { if features.isLoading { ProgressView().padding() } }
        .onChange(of: features.selectedProject) { _, project in
            if let project { name = project.name; folders = project.roots.compactMap { path($0.path) }.joined(separator: "\n") }
        }
        .task { await features.refresh() }
        .alert("Delete project?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                guard let project = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await features.delete(id: project.id) }
            }
        } message: { Text("This removes the synced project. Its chats and files remain.") }
    }

    private func path(_ value: CodexSchemaAbsolutePathBuf) -> String? {
        if case .string(let path) = value.rawValue { return path }
        return nil
    }
}
