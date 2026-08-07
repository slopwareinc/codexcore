#if canImport(AppKit)
import AppKit
import Foundation
import SwiftUI

@MainActor
enum CodexPluginImageRepository {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let image: NSImage?
        if url.isFileURL {
            image = NSImage(contentsOf: url)
        } else {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 20
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true else {
                return nil
            }
            image = NSImage(data: data)
        }
        guard let image else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    static func cachedOrLocalImage(for url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard url.isFileURL, let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
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

    private var localImage: NSImage? {
        guard let url, url.isFileURL else { return nil }
        return CodexPluginImageRepository.cachedOrLocalImage(for: url)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(7, size * 0.24), style: .continuous)
                .fill(theme.colors.accentSoft.opacity(0.55))
            if let image = image ?? localImage {
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
            // App-server local assets should render on the first frame. Remote marketplace
            // artwork continues through the shared asynchronous cache.
            if url.isFileURL { return }
            image = await CodexPluginImageRepository.image(for: url)
        }
        .accessibilityHidden(true)
    }
}
#endif
