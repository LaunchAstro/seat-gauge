import AppKit
import ImageIO
import SeatGaugeCore
import Testing
import UniformTypeIdentifiers
@testable import SeatGauge

/// A fetched icon is untrusted: its size and frame count are read from its
/// header before anything is decoded, only one small thumbnail is made, and
/// an icon that fails is evicted from the cache.
@Suite @MainActor struct SeatMarkLimitsTests {
    /// A transparent square of `side` pixels with an opaque glyph in its middle.
    nonisolated static func image(side: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1))
        context.fill(CGRect(x: side / 4, y: side / 4, width: side / 2, height: side / 2))
        return context.makeImage()!
    }

    nonisolated static func encode(_ images: [CGImage], as type: UTType) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)!
        for image in images { CGImageDestinationAddImage(destination, image, nil) }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("an ordinary icon still makes a mark, at its own size")
    func ordinary() throws {
        let data = Self.encode([Self.image(side: 64), Self.image(side: 32), Self.image(side: 16)], as: .ico)
        let mark = try #require(SeatMark.template(from: data))
        #expect(mark.size.width == 64)
    }

    @Test("an image wider than the limit is refused before it is decoded")
    func tooWide() {
        let data = Self.encode([Self.image(side: SeatMark.largestSide + 476)], as: .png)
        #expect(SeatMark.template(from: data) == nil)
    }

    @Test("an icon with more frames than the limit is refused")
    func tooManyFrames() {
        let frame = Self.image(side: 16)
        let data = Self.encode(Array(repeating: frame, count: SeatMark.largestFrames + 8), as: .gif)
        #expect(SeatMark.template(from: data) == nil)
    }

    @Test("a large icon becomes one thumbnail no bigger than the drawn mark needs")
    func thumbnail() throws {
        let data = Self.encode([Self.image(side: 512)], as: .png)
        let mark = try #require(SeatMark.template(from: data))
        #expect(mark.size.width <= CGFloat(SeatMark.thumbnailSide))
    }

    @Test("a cached icon that fails is evicted, so the next launch fetches it again")
    func evicted() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-seatmark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bad = Self.encode([Self.image(side: SeatMark.largestSide + 476)], as: .png)
        try bad.write(to: folder.appendingPathComponent("claude.icon"))
        let cache = MarkCache(folder: folder, download: { _, _ in nil })
        let marks = await SeatMark.load(cache)
        #expect(marks[.claude] == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("claude.icon").path))
    }
}
