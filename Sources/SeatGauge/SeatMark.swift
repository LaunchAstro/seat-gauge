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

    nonisolated static func side(_ scale: TextScale) -> CGFloat {
        max(minimumSide, CGFloat(scale.scaled(Double(baseSide))))
    }

    /// Every provider's cached icon, fetched first where none is cached. The
    /// fetch and the file reads run off the main actor, in the core.
    static func load(_ cache: MarkCache = MarkCache()) async -> [Provider: NSImage] {
        var marks: [Provider: NSImage] = [:]
        for provider in Provider.allCases {
            if let data = await cache.mark(for: provider), let image = template(from: data) {
                marks[provider] = image
            }
        }
        return marks
    }

    /// The icon's largest image as a template: black, with each pixel's alpha
    /// the share of it that is the mark (`MarkMask`). Nil for bytes that are
    /// not an image or an image that is all plate.
    nonisolated static func template(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let images = (0..<CGImageSourceGetCount(source)).compactMap {
            CGImageSourceCreateImageAtIndex(source, $0, nil)
        }
        guard let image = images.max(by: { $0.width < $1.width }) else { return nil }
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
        let template = NSImage(cgImage: masked, size: NSSize(width: width, height: height))
        template.isTemplate = true
        return template
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
