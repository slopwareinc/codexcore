import AppKit
import ImageIO
import SwiftUI

struct CodexTranscriptDecodedThumbnail: @unchecked Sendable {
    let image: CGImage
    let decodedOnMainThread: Bool
}

actor CodexTranscriptAttachmentThumbnailLoader {
    static let shared = CodexTranscriptAttachmentThumbnailLoader()

    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 32
        return cache
    }()
    private var inFlight: [String: Task<CodexTranscriptDecodedThumbnail?, Never>] = [:]

    func thumbnail(
        at path: String,
        maxPixelSize: Int = 128
    ) async -> CodexTranscriptDecodedThumbnail? {
        let cacheKey = "\(path)#\(maxPixelSize)"
        let key = cacheKey as NSString
        if let cached = cache.object(forKey: key) {
            return CodexTranscriptDecodedThumbnail(image: cached, decodedOnMainThread: false)
        }
        if let task = inFlight[cacheKey] { return await task.value }
        let task = Task.detached(priority: .utility) {
            Self.downsample(path: path, maxPixelSize: maxPixelSize)
        }
        inFlight[cacheKey] = task
        let decoded = await task.value
        inFlight[cacheKey] = nil
        guard let decoded else { return nil }
        cache.setObject(decoded.image, forKey: key)
        return decoded
    }

    nonisolated private static func downsample(
        path: String,
        maxPixelSize: Int
    ) -> CodexTranscriptDecodedThumbnail? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return CodexTranscriptDecodedThumbnail(
            image: image,
            decodedOnMainThread: Thread.isMainThread
        )
    }
}

struct CodexTranscriptImageThumbnail: View {
    @Environment(\.codexAgentTheme) private var theme

    let path: String
    let label: String
    var side: CGFloat = 64

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: side > 64 ? .fit : .fill)
            } else {
                VStack(spacing: 3) {
                    Image(systemName: "photo")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.colors.textSecondary)
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(5)
                .background(theme.colors.surface.opacity(0.7))
            }
        }
        .frame(width: side, height: side)
        .background(theme.colors.surface.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: path) {
            image = nil
            guard let thumbnail = await CodexTranscriptAttachmentThumbnailLoader.shared.thumbnail(
                at: path,
                maxPixelSize: max(128, Int(ceil(side * 2)))
            ), !Task.isCancelled else { return }
            image = NSImage(cgImage: thumbnail.image, size: .zero)
        }
    }
}
