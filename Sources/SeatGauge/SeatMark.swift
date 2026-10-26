import AppKit
import ImageIO
import SeatGaugeCore
import SwiftUI

/// The provider's mark beside its name: the site's own icon (`MarkCache`),
/// redrawn as a mask and filled in the ink, as the type is. A provider with
/// no icon has no mark, and the header reads its name alone.
enum SeatMark {
    /// The side at the ordinary text size, and the floor under it: the type
    /// keeps going down, the icon does not, because a favicon under this is
    /// a smudge.
    nonisolated static let baseSide: CGFloat = 14
    nonisolated static let minimumSide: CGFloat = 12

    /// The widest or tallest frame an icon may have, read from its header
    /// before anything is decoded. Real ones are 64 pixels at most.
    nonisolated static let largestSide = 1024
    /// The most frames an icon may hold. Real ones have three or four.
    nonisolated static let largestFrames = 32
    /// The one image decoded, at most this many pixels a side: past twice
    /// the largest side the mark is drawn at, on a Retina screen.
    nonisolated static let thumbnailSide = 128

    nonisolated static func side(_ scale: TextScale) -> CGFloat {
        max(minimumSide, CGFloat(scale.scaled(Double(baseSide))))
    }

    /// Every provider's cached icon, fetched first where none is cached. The
    /// fetch and the file reads run off the main actor, in the core, and so
    /// does the decode. An icon that makes no mark is evicted, so the next
    /// launch fetches it again rather than decoding it at every start.
    static func load(_ cache: MarkCache = MarkCache()) async -> [Provider: NSImage] {
        var marks: [Provider: NSImage] = [:]
        for provider in Provider.allCases {
            guard let data = await cache.mark(for: provider) else { continue }
            let masked = await Task.detached(priority: .utility) { mask(from: data) }.value
            if let masked { marks[provider] = template(masked) } else { cache.evict(provider) }
        }
        return marks
    }

    /// The icon's largest image as a template: black, with each pixel's alpha
    /// the share of it that is the mark (`MarkMask`). Nil for bytes that are
    /// not an image, an icon past the limits, or an image that is all plate.
    nonisolated static func template(from data: Data) -> NSImage? {
        mask(from: data).map(template)
    }

    nonisolated static func template(_ masked: CGImage) -> NSImage {
        let template = NSImage(cgImage: masked, size: NSSize(width: masked.width, height: masked.height))
        template.isTemplate = true
        return template
    }

    /// The mask itself. Every frame's size, and the number of frames, come
    /// from the header first, so a compact file that would decode to
    /// gigabytes is refused unread, and only the largest frame is decoded,
    /// as a thumbnail no bigger than `thumbnailSide`.
    nonisolated static func mask(from data: Data) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard (1 ... largestFrames).contains(count) else { return nil }
        var largest: (index: Int, side: Int)?
        for index in 0 ..< count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1 ... largestSide).contains(width), (1 ... largestSide).contains(height) else { return nil }
            if width > (largest?.side ?? 0) { largest = (index, width) }
        }
        let thumbnail = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                         kCGImageSourceCreateThumbnailWithTransform: true,
                         kCGImageSourceShouldCacheImmediately: true,
                         kCGImageSourceThumbnailMaxPixelSize: thumbnailSide] as CFDictionary
        guard let largest, let image = CGImageSourceCreateThumbnailAtIndex(source, largest.index, thumbnail)
        else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let drawn = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        drawn.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = drawn.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: pixels.bindMemory(to: UInt8.self, capacity: width * height * 4),
                                              count: width * height * 4))
        let coverage = MarkMask.coverage(bytes)
        guard coverage.contains(where: { $0 > 0 }) else { return nil }
        var mask = [UInt8](repeating: 0, count: width * height * 4)
        for (index, alpha) in coverage.enumerated() { mask[index * 4 + 3] = alpha }
        guard let out = CGContext(data: &mask, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let masked = out.makeImage() else { return nil }
        return masked
    }
}

/// The mark on a card at the header's size, in the ink of the appearance the
/// user chose, or nothing when the provider has no icon.
struct SeatMarkView: View {
    let provider: Provider

    var body: some View {
        if let image = GaugeMirror.shared.marks[provider] {
            let side = SeatMark.side(TextScale.current)
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Tone.ink)
                .frame(width: side, height: side)
                .accessibilityLabel(provider.name)
        }
    }
}

/// The ALL card's mark, where a provider's sits and at its size: sparkles drawn
/// here, in the accent, so it needs no asset and no fetch.
struct SummaryMarkView: View {
    var body: some View {
        let side = SeatMark.side(TextScale.current)
        Sparkles()
            .fill(Tone.accent)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// Two four-point stars with straight, sharp sides, one large and one
/// small, like the sparkles emoji. Two, and wide in the waist, because at
/// a favicon's size a third star or thinner arms blur into a smudge.
struct Sparkles: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height)
        var path = Path()
        for (x, y, radius) in [(0.40, 0.60, 0.40), (0.79, 0.21, 0.21)] {
            Self.star(&path, centre: CGPoint(x: rect.minX + unit * x, y: rect.minY + unit * y), radius: unit * radius)
        }
        return path
    }

    /// Points on the axes and inner corners on the diagonals.
    private static func star(_ path: inout Path, centre: CGPoint, radius: CGFloat) {
        let inner = radius * 0.34
        path.move(to: CGPoint(x: centre.x, y: centre.y - radius))
        for step in 1..<8 {
            let angle = CGFloat(step) * .pi / 4 - .pi / 2
            let length = step.isMultiple(of: 2) ? radius : inner
            path.addLine(to: CGPoint(x: centre.x + cos(angle) * length, y: centre.y + sin(angle) * length))
        }
        path.closeSubpath()
    }
}
