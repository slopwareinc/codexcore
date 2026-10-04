import AppKit
import Testing
@testable import CodexCoreUI

struct CodexTranscriptThumbnailCacheTests {
    @Test func differentImagesWithMatchingSourceEdgesDoNotShareThumbnails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent(String(repeating: "p", count: 160))
        let filename = String(repeating: "s", count: 90) + ".png"
        let first = parent.appendingPathComponent("a").appendingPathComponent(filename)
        let second = parent.appendingPathComponent("b").appendingPathComponent(filename)
        try writeImage(height: 16, to: first)
        try writeImage(height: 32, to: second)
        #expect(first.path.count == second.path.count)
        #expect(first.path.prefix(160) == second.path.prefix(160))
        #expect(first.path.suffix(80) == second.path.suffix(80))
        let loader = CodexTranscriptAttachmentThumbnailLoader()
        let images = await (loader.thumbnail(at: first.path), loader.thumbnail(at: second.path))
        #expect(try #require(images.0).image.height == 16)
        #expect(try #require(images.1).image.height == 32)
    }

    @Test func replacingLocalImageRefreshesCachedPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png")
        let loader = CodexTranscriptAttachmentThumbnailLoader()
        try writeImage(height: 16, to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)
        #expect(try #require(await loader.thumbnail(at: file.path)).image.height == 16)
        try writeImage(height: 32, to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: file.path)
        #expect(try #require(await loader.thumbnail(at: file.path)).image.height == 32)
        #expect(await loader.thumbnail(at: file.path, maxPixelSize: 0) == nil)
    }

    private func writeImage(height: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32
        ))
        let pixels = try #require(bitmap.bitmapData)
        for offset in stride(from: 0, to: height * 128, by: 4) {
            pixels[offset] = 64
            pixels[offset + 1] = 128
            pixels[offset + 2] = 255
            pixels[offset + 3] = 255
        }
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
