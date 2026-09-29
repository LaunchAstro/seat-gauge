import AppKit
import CoreText
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// How wide each card, meter and header is drawn. Nothing here opens a window. Every render goes through `ImageRenderer` into
/// a bitmap, and the header is read off a hosting view's fitting size.
@Suite(.serialized, .sharedMirror) @MainActor struct CardWidthTests {

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SeatGaugeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository

    nonisolated static let scale: CGFloat = 2

    static func card(_ seat: String, picked: Bool = false, used: Int = 40,
                     provider: String = "Codex", countdown: String = "4h 12m") -> CardModel {
        CardModel(id: SeatID(rawValue: seat), label: seat, isBest: picked,
                  lines: [WindowLine(kind: .fiveHour, usedPercent: used, countdown: countdown),
                          WindowLine(kind: .weekly, usedPercent: used / 2, countdown: "5d 3h")],
                  pace: nil, stale: nil, mark: provider == "Codex" ? .codex : .claude,
                  account: nil, plan: nil)
    }

    /// A card with one window line, so the only thing that differs between
    /// two used figures is the fill and the percent.
    static func oneLine(used: Int, countdown: String = "4h 12m") -> CardModel {
        CardModel(id: SeatID(rawValue: "work"), label: "work", isBest: false,
                  lines: [WindowLine(kind: .fiveHour, usedPercent: used, countdown: countdown)],
                  pace: nil, stale: nil, mark: .claude, account: nil, plan: nil)
    }

    static func cards(_ count: Int) -> [CardModel] {
        ["work", "team", "personal", "codex"].prefix(count).enumerated().map { index, seat in
            card(seat, picked: index == 0, used: 20 + index * 20,
                 provider: seat == "codex" ? "Codex" : "Claude")
        }
    }

    struct Bitmap: Equatable {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

        func pixel(_ x: Int, _ y: Int) -> ArraySlice<UInt8> {
            bytes[(y * width + x) * 4 ..< (y * width + x) * 4 + 4]
        }

        /// The runs of pixels with any alpha on one row, in points.
        func inked(row y: Int) -> [(start: CGFloat, end: CGFloat)] {
            var runs: [(start: CGFloat, end: CGFloat)] = []
            var start: Int?
            for x in 0...width {
                let on = x < width && alpha(x, y) > 0
                if on, start == nil { start = x }
                if !on, let begun = start {
                    runs.append((CGFloat(begun) / scale, CGFloat(x) / scale))
                    start = nil
                }
            }
            return runs
        }
    }

    static func render<V: View>(_ view: V, width: CGFloat, scale: CGFloat = scale) -> Bitmap? {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? Bitmap(width: image.width, height: image.height, bytes: bytes) : nil
    }

    static func registerBundledFaces() -> Set<String> {
        let folder = root.appendingPathComponent("Resources/Fonts")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
        return Set(NSFontManager.shared.availableFontFamilies).intersection(FontManifest.fonts.map(\.family))
    }

    /// The ordinary text step, with the size put back afterwards. The cases
    /// run at this one step: the others scale the same layout.
    static func atOrdinaryStep(_ body: (Int) throws -> Void) rethrows {
        let was = GaugeMirror.shared.textScale
        defer { GaugeMirror.shared.textScale = was }
        GaugeMirror.shared.textScale = .normal
        try body(TextScale.normal.step)
    }

    // MARK: - One module places the cards

    @Test func theCardRowPlacesEachCardWhereCardWidthsSays() throws {
        let inset = PanelLayout.boxInset
        Self.atOrdinaryStep { step in
            for count in 1...4 {
                let floor = PanelLayout.minimumContentWidth(cards: count)
                for width in [floor, floor + 137.5, floor + 611] {
                    guard let bitmap = Self.render(ComboLayout(cards: Self.cards(count)), width: width) else {
                        Issue.record("no render at step \(step), \(count) cards, \(width)")
                        continue
                    }
                    let runs = bitmap.inked(row: bitmap.height / 2)
                    #expect(runs.count == count, "step \(step), \(count) cards, \(width): \(runs)")
                    guard runs.count == count else { continue }
                    var x: CGFloat = 0
                    for (run, share) in zip(runs, PanelLayout.cardWidths(contentWidth: width, cards: count)) {
                        #expect(abs(run.start - (x + inset)) <= 1, "step \(step): \(run) from \(x)")
                        #expect(abs(run.end - (x + share - inset)) <= 1, "step \(step): \(run) to \(x + share)")
                        x += share + PanelLayout.ruleWidth
                    }
                    #expect(abs(runs[0].start - inset) <= 1)
                    #expect(abs(runs[count - 1].end - (width - inset)) <= 1, "step \(step), \(count) cards, \(width)")
                }
            }
        }
    }

    // MARK: - The meter gets meterWidth

    @Test func theMeterIsAsWideAsMeterWidth() throws {
        // A countdown wider than its column takes its overflow off a meter with
        // room to give it, read off the countdown drawn on its own rather than
        // off the module. Nearer the floor the stack squeezes the countdown.
        let lines: [(String, CGFloat)] = [("4h 12m", 0), ("4h 12m", 90.5), ("4h 12m", 400), ("123456d 23h", 400)]
        Self.atOrdinaryStep { step in
            for (countdown, extra) in lines {
                let drawn = NSHostingView(rootView: Text(countdown).font(Type.display(12)).monospacedDigit()
                    .tracking(CardMetrics.digitTracking).fixedSize()).fittingSize.width
                let overflow = max(0, drawn - CardMetrics.countdownWidth)
                #expect((countdown == "4h 12m") == (overflow == 0), "step \(step), \(countdown): \(overflow)")
                let width = CardMetrics.minimumWidth + extra
                guard let a = Self.render(CardView(card: Self.oneLine(used: 100, countdown: countdown)), width: width),
                      let b = Self.render(CardView(card: Self.oneLine(used: 0, countdown: countdown)), width: width),
                      a.width == b.width, a.height == b.height else {
                    Issue.record("renders differ in size at step \(step)")
                    continue
                }
                var longest = 0
                for y in 0..<a.height {
                    var run = 0
                    for x in 0..<a.width {
                        run = a.pixel(x, y) == b.pixel(x, y) ? 0 : run + 1
                        longest = max(longest, run)
                    }
                }
                let fill = CGFloat(longest) / Self.scale
                let meter = CardMetrics.meterWidth(cardWidth: width, overflow: overflow)
                let left = width - CardMetrics.fixedColumns - overflow
                #expect(abs(fill - left) <= 1, "step \(step), \(countdown), card \(width): fill \(fill), left \(left)")
                #expect(abs(meter - left) < 0.01, "step \(step), \(countdown), card \(width): meter \(meter)")
            }
        }
    }

    // MARK: - The header copy matches the drawn header

    @Test func theHeaderCopyMatchesTheDrawnHeader() throws {
        let faces = Type.registered
        let marks = GaugeMirror.shared.marks
        defer {
            Type.registered = faces
            GaugeMirror.shared.marks = marks
        }
        let icon = try #require(SeatMark.template(from: ProviderHeaderTests.icon(plate: false)))
        for registered in [Set<String>(), Self.registerBundledFaces()] {
            Type.registered = registered
            // With the provider's icon and without it, which is the name alone.
            for marked in [true, false] {
                GaugeMirror.shared.marks = marked ? Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, icon) }) : [:]
                Self.atOrdinaryStep { step in
                    for seat in ["team", "personal", ""] {
                        for picked in [true, false] {
                            let card = Self.card(seat, picked: picked)
                            let header = CardHeader(card: card)
                                .padding(.horizontal, CardMetrics.horizontalPadding)
                                .fixedSize()
                            let drawn = NSHostingView(rootView: header).fittingSize.width + PanelLayout.boxInset * 2
                            let copy = CardMetrics.headerWidth(provider: card.provider, seat: seat, picked: picked,
                                                               marked: marked)
                            #expect(abs(drawn - copy) <= 5,
                                    "step \(step), faces \(registered), marked \(marked), \(seat), picked \(picked): drawn \(drawn), copy \(copy)")
                        }
                    }
                }
            }
        }
    }
}
