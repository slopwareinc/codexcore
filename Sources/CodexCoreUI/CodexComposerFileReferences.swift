import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing
import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Compact, removable references shown above the composer text field.
public struct CodexComposerFileReferenceStrip: View {
    @Environment(\.codexAgentTheme) private var theme

    private let files: [CodexReferencedFile]
    private let onRemove: (CodexReferencedFile) -> Void

    public init(
        files: [CodexReferencedFile],
        onRemove: @escaping (CodexReferencedFile) -> Void
    ) {
        self.files = files
        self.onRemove = onRemove
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(files) { file in
                    HStack(spacing: 6) {
                        CodexReferencedFilePreview(file: file)
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                        Text(file.displayName)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textPrimary)
                            .lineLimit(1)

                        Button {
                            onRemove(file)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(theme.colors.textTertiary)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(file.displayName)")
                    }
                    .padding(.leading, 5)
                    .padding(.trailing, 2)
                    .padding(.vertical, 3)
                    .background(theme.colors.surfaceElevated.opacity(0.72), in: Capsule())
                    .overlay(Capsule().stroke(theme.colors.border.opacity(0.72), lineWidth: 1))
                    .help(file.path)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(minHeight: 30, maxHeight: 34)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Files attached to draft")
    }
}

struct CodexReferencedFilePreview: View {
    @Environment(\.codexAgentTheme) private var theme
    let file: CodexReferencedFile
    @State private var image: NSImage?

    var body: some View {
        #if canImport(AppKit)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: file.isImage ? "photo" : file.kind == .directory ? "folder" : "doc")
                    .font(theme.fonts.chipLabel)
                    .foregroundStyle(file.isImage ? theme.colors.accent : theme.colors.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.colors.surface.opacity(0.7))
            }
        }
        .task(id: file.path) {
            guard file.isImage else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: URL(fileURLWithPath: file.path),
                size: CGSize(width: 72, height: 72),
                scale: 2,
                representationTypes: .thumbnail
            )
            guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
                  !Task.isCancelled
            else { return }
            image = representation.nsImage
        }
        #else
        Image(systemName: file.isImage ? "photo" : "doc")
        #endif
    }
}

/// Adds Finder file drops without reading the dropped file contents. The callback receives only
/// file URLs; callers decide how those references belong to a thread's draft.
public struct CodexFileDropTargetModifier: ViewModifier {
    @Binding private var isTargeted: Bool
    private let isEnabled: Bool
    private let onDrop: @MainActor @Sendable ([URL]) -> Void

    public init(
        isTargeted: Binding<Bool>,
        isEnabled: Bool = true,
        onDrop: @escaping @MainActor @Sendable ([URL]) -> Void
    ) {
        self._isTargeted = isTargeted
        self.isEnabled = isEnabled
        self.onDrop = onDrop
    }

    public func body(content: Content) -> some View {
        Group {
            if isEnabled {
                content
                    .overlay {
                        if isTargeted {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                .allowsHitTesting(false)
                        }
                    }
                    .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $isTargeted) { providers in
                        guard !providers.isEmpty else { return false }
                        let batch = CodexFileDropBatch(count: providers.count, completion: onDrop)
                        for (index, provider) in providers.enumerated() {
                            let registeredTypes = provider.registeredTypeIdentifiers
                            let hasFileURL = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                            let suggestedName = provider.suggestedName
                            let imageType = registeredTypes.first { UTType($0)?.conforms(to: .image) == true }
                            let type = hasFileURL ? UTType.fileURL.identifier : imageType
                            guard let type else { batch.finish(index: index, url: nil); continue }
                            if hasFileURL {
                                provider.loadObject(ofClass: NSURL.self) { object, _ in
                                    let originalURL: URL? = if let nsURL = object as? NSURL, nsURL.isFileURL, let path = nsURL.path {
                                        URL(fileURLWithPath: path)
                                    } else {
                                        nil
                                    }
                                    if let originalURL {
                                        batch.finish(index: index, url: originalURL)
                                    } else {
                                        batch.finish(index: index, url: nil)
                                    }
                                }
                                continue
                            }
                            CodexFileDropProviderLoader(
                                provider: provider,
                                typeIdentifier: type,
                                suggestedName: suggestedName,
                                batch: batch,
                                index: index
                            ).load()
                        }
                        return true
                    }
            } else {
                content
            }
        }
    }
}

@MainActor
private final class CodexFileDropProviderLoader {
    private let provider: NSItemProvider
    private let typeIdentifier: String
    private let suggestedName: String?
    private let batch: CodexFileDropBatch
    private let index: Int

    init(
        provider: NSItemProvider,
        typeIdentifier: String,
        suggestedName: String?,
        batch: CodexFileDropBatch,
        index: Int
    ) {
        self.provider = provider
        self.typeIdentifier = typeIdentifier
        self.suggestedName = suggestedName
        self.batch = batch
        self.index = index
    }

    func load() {
        provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeIdentifier) { [self] url, isInPlace, _ in
            Task { @MainActor in
                handleInPlaceResult(url: url, isInPlace: isInPlace)
            }
        }
    }

    private func handleInPlaceResult(url: URL?, isInPlace: Bool) {
        if let url {
            let stableURL = isInPlace
                ? url
                : CodexDroppedFileMaterializer.materialize(
                    url,
                    suggestedName: suggestedName ?? url.lastPathComponent,
                    typeIdentifier: typeIdentifier
                )
            batch.finish(index: index, url: stableURL)
        } else {
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { [self] data, _ in
                Task { @MainActor in
                    finish(data: data)
                }
            }
        }
    }

    private func finish(data: Data?) {
        let stableURL: URL?
        if typeIdentifier == UTType.fileURL.identifier, let data,
           let fileURL = URL(dataRepresentation: data, relativeTo: nil) {
            stableURL = fileURL
        } else {
            stableURL = data.flatMap {
                CodexDroppedFileMaterializer.materialize(
                    $0,
                    suggestedName: suggestedName,
                    typeIdentifier: typeIdentifier
                )
            }
        }
        batch.finish(index: index, url: stableURL)
    }
}

enum CodexDroppedFileMaterializer {
    static func materialize(_ source: URL, suggestedName: String?, typeIdentifier: String) -> URL? {
        let destination = destinationURL(suggestedName: suggestedName, typeIdentifier: typeIdentifier)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    static func materialize(_ data: Data, suggestedName: String?, typeIdentifier: String) -> URL? {
        let destination = destinationURL(suggestedName: suggestedName, typeIdentifier: typeIdentifier)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    private static func destinationURL(suggestedName: String?, typeIdentifier: String) -> URL {
        let name = suggestedName.flatMap { $0.isEmpty ? nil : $0 } ?? "attachment"
        let ext = URL(fileURLWithPath: name).pathExtension.isEmpty
            ? (UTType(typeIdentifier)?.preferredFilenameExtension ?? "dat") : ""
        let filename = ext.isEmpty ? name : "\(name).\(ext)"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codexcore/attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }
}

final class CodexFileDropBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var urlsByIndex: [URL?]
    private let completion: @MainActor @Sendable ([URL]) -> Void

    init(count: Int, completion: @escaping @MainActor @Sendable ([URL]) -> Void) {
        self.remaining = count
        self.urlsByIndex = Array(repeating: nil, count: count)
        self.completion = completion
    }

    func finish(index: Int, url: URL?) {
        lock.lock()
        if urlsByIndex.indices.contains(index) {
            urlsByIndex[index] = url
        }
        remaining -= 1
        let result = remaining == 0 ? urlsByIndex.compactMap { $0 } : nil
        lock.unlock()

        guard let result else { return }
        Task { @MainActor in
            completion(result)
        }
    }
}

public extension View {
    func codexFileDropTarget(
        isTargeted: Binding<Bool>,
        isEnabled: Bool = true,
        onDrop: @escaping @MainActor @Sendable ([URL]) -> Void
    ) -> some View {
        modifier(CodexFileDropTargetModifier(isTargeted: isTargeted, isEnabled: isEnabled, onDrop: onDrop))
    }
}
