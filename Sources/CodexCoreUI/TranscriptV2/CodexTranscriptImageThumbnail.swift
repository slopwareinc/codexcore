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
        await thumbnail(source: path, maxPixelSize: maxPixelSize)
    }

    func thumbnail(
        source: String,
        maxPixelSize: Int = 128
    ) async -> CodexTranscriptDecodedThumbnail? {
        let cacheKey = "\(source.count):\(source.prefix(160)):\(source.suffix(80))#\(maxPixelSize)"
        let key = cacheKey as NSString
        if let cached = cache.object(forKey: key) {
            return CodexTranscriptDecodedThumbnail(image: cached, decodedOnMainThread: false)
        }
        if let task = inFlight[cacheKey] { return await task.value }
        let task = Task.detached(priority: .utility) {
            await Self.downsample(source: source, maxPixelSize: maxPixelSize)
        }
        inFlight[cacheKey] = task
        let decoded = await task.value
        inFlight[cacheKey] = nil
        guard let decoded else { return nil }
        cache.setObject(decoded.image, forKey: key)
        return decoded
    }

    nonisolated private static func downsample(
        source: String,
        maxPixelSize: Int
    ) async -> CodexTranscriptDecodedThumbnail? {
        let imageSource: CGImageSource?
        if let url = URL(string: source),
           url.scheme == "http" || url.scheme == "https" {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            imageSource = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary)
        } else if let data = CodexTranscriptImageSource.inlineData(source) {
            imageSource = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary)
        } else if let path = CodexTranscriptImageSource.localFilePath(source) {
            imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary)
        } else {
            imageSource = nil
        }
        guard let imageSource else { return nil }
        return makeThumbnail(imageSource, maxPixelSize: maxPixelSize)
    }

    nonisolated private static func makeThumbnail(
        _ imageSource: CGImageSource,
        maxPixelSize: Int
    ) -> CodexTranscriptDecodedThumbnail? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options) else { return nil }
        return CodexTranscriptDecodedThumbnail(
            image: image,
            decodedOnMainThread: Thread.isMainThread
        )
    }
}

enum CodexTranscriptImageSource {
    static func aspectRatio(_ source: String) -> CGFloat? {
        let imageSource: CGImageSource?
        if let data = inlineData(source) {
            imageSource = CGImageSourceCreateWithData(data as CFData, nil)
        } else if let path = localFilePath(source) {
            imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        } else {
            imageSource = nil
        }
        guard let imageSource,
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0,
              height > 0
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 && orientation <= 8
            ? CGFloat(height / width)
            : CGFloat(width / height)
    }

    static func localFilePath(_ source: String) -> String? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let url = URL(string: value), url.isFileURL { return url.path }
        guard !value.contains("://"), !value.hasPrefix("data:") else { return nil }
        return value.hasPrefix("/") ? value : nil
    }

    static func inlineData(_ source: String) -> Data? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("data:image/"),
           let comma = value.firstIndex(of: ","),
           value[..<comma].contains(";base64") {
            return Data(
                base64Encoded: String(value[value.index(after: comma)...]),
                options: .ignoreUnknownCharacters
            )
        }
        guard !value.contains("://"), !value.hasPrefix("/") else { return nil }
        return Data(base64Encoded: value, options: .ignoreUnknownCharacters)
    }
}

struct CodexTranscriptImageThumbnail: View {
    @Environment(\.codexAgentTheme) private var theme

    let source: String
    let label: String
    var side: CGFloat = 64
    var aspectRatio: CGFloat = 1

    @State private var image: NSImage?

    init(path: String, label: String, side: CGFloat = 64, aspectRatio: CGFloat = 1) {
        self.source = path
        self.label = label
        self.side = side
        self.aspectRatio = aspectRatio
    }

    init(source: String, label: String, side: CGFloat = 64, aspectRatio: CGFloat = 1) {
        self.source = source
        self.label = label
        self.side = side
        self.aspectRatio = aspectRatio
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
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
        .frame(width: side, height: previewHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: source) {
            image = nil
            guard let thumbnail = await CodexTranscriptAttachmentThumbnailLoader.shared.thumbnail(
                source: source,
                maxPixelSize: max(128, Int(ceil(side * 2)))
            ), !Task.isCancelled else { return }
            image = NSImage(cgImage: thumbnail.image, size: .zero)
        }
    }

    private var previewHeight: CGFloat {
        side / max(0.01, aspectRatio)
    }
}
