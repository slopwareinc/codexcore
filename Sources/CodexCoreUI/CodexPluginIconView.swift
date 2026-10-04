#if canImport(AppKit)
import AppKit
import Foundation
import ImageIO
import SwiftUI

@MainActor
enum CodexPluginImageRepository {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()
    private struct LoadedImage: @unchecked Sendable {
        let image: NSImage
        let cost: Int
    }

    private static var inFlight: [URL: Task<LoadedImage?, Never>] = [:]

    static func image(for url: URL) async -> NSImage? {
        if let cached = cachedImage(for: url) { return cached }
        if let task = inFlight[url] { return await task.value?.image }
        let task = Task.detached(priority: .utility) {
            await loadImage(from: url)
        }
        inFlight[url] = task
        let loaded = await task.value
        inFlight[url] = nil
        guard let loaded else { return nil }
        cache.setObject(loaded.image, forKey: url as NSURL, cost: loaded.cost)
        return loaded.image
    }

    static func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    nonisolated private static func loadImage(from url: URL) async -> LoadedImage? {
        let source: CGImageSource?
        let encodedData: Data?
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if url.isFileURL {
            source = CGImageSourceCreateWithURL(url as CFURL, options)
            encodedData = nil
        } else {
            guard let data = try? await CodexImageResourceLoader.shared.data(
                from: url, maximumBytes: 4 * 1_024 * 1_024
            ) else { return nil }
            source = CGImageSourceCreateWithData(data as CFData, options)
            encodedData = data
        }
        // AppKit also supports vector formats such as PDF that ImageIO does
        // not thumbnail. Keep that compatibility with a bounded source read.
        guard let source else {
            if let encodedData { return vectorImage(data: encodedData) }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 4 * 1_024 * 1_024 + 1),
                  data.count <= 4 * 1_024 * 1_024 else { return nil }
            return vectorImage(data: data)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ] as CFDictionary) else { return nil }
        return LoadedImage(image: NSImage(cgImage: image, size: .zero), cost: image.bytesPerRow * image.height)
    }

    nonisolated private static func vectorImage(data: Data) -> LoadedImage? {
        guard let image = NSImage(data: data) else { return nil }
        return LoadedImage(image: image, cost: 4 * 1_024 * 1_024)
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
