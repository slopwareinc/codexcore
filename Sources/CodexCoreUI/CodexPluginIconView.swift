#if canImport(AppKit)
import AppKit
import Foundation
import SwiftUI

@MainActor
enum CodexPluginImageRepository {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 128
        return cache
    }()
    private static var inFlight: [URL: Task<NSImage?, Never>] = [:]

    static func image(for url: URL) async -> NSImage? {
        if let cached = cachedImage(for: url) { return cached }
        if let task = inFlight[url] { return await task.value }
        let task = Task.detached(priority: .utility) {
            await loadImage(from: url)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        guard let image else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    static func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    nonisolated private static func loadImage(from url: URL) async -> NSImage? {
        if url.isFileURL { return NSImage(contentsOf: url) }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true else {
            return nil
        }
        return NSImage(data: data)
    }
}

struct CodexPluginIconView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.codexAgentTheme) private var theme
    @State private var image: NSImage?

    let reference: CodexPluginIconReference
    var size: CGFloat
    var fallbackSystemName = "puzzlepiece.extension"

    private var url: URL? {
        reference.url(prefersDark: colorScheme == .dark)
    }

    private var cachedImage: NSImage? {
        guard let url, url.isFileURL else { return nil }
        return CodexPluginImageRepository.cachedImage(for: url)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(7, size * 0.24), style: .continuous)
                .fill(theme.colors.accentSoft.opacity(0.55))
            if let image = image ?? cachedImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.12)
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(theme.colors.accentText)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await CodexPluginImageRepository.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
        .accessibilityHidden(true)
    }
}
#endif
