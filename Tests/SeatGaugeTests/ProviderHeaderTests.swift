import AppKit
import CoreText
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

import SeatGaugeCore
@testable import SeatGauge

/// The provider-first header and its mark. Nothing here opens a window: the
/// card is read through `PanelModel.make`, the mark through `SeatMark` and the
/// bitmap it makes, and the widths through `CardMetrics`.
@Suite(.sharedMirror) @MainActor struct ProviderHeaderTests {

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SeatGaugeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository

    static let now = Date(timeIntervalSince1970: 1_758_500_100)

    static func claude(_ id: String, label: String? = nil, account: String? = nil,
                       plan: String? = nil) -> Seat {
        Seat(id: SeatID(rawValue: id), label: label ?? id, kind: .claude(profileDir: URL(fileURLWithPath: "/tmp/seat-gauge-profile")),
             account: account, plan: plan)
    }

    static func codex(_ id: String, label: String? = nil) -> Seat {
        Seat(id: SeatID(rawValue: id), label: label ?? id, kind: .codex)
    }

    /// One live reading per id, the first one emptier so it is the pick.
    static func panel(_ seats: [Seat], readings ids: [String]? = nil) -> PanelModel {
        let order = (ids ?? seats.map(\.id.rawValue)).map { SeatID(rawValue: $0) }
        var states: [SeatID: SeatState] = [:]
        for (index, id) in order.enumerated() {
            let window = SeatGaugeCore.Window(kind: .fiveHour, usedPercent: 20 + index * 30,
                                              resetsAt: now.addingTimeInterval(3600),
                                              length: .seconds(5 * 3600))
            states[id] = .live(Reading(seat: id, windows: [window], takenAt: now, plan: nil))
        }
        return PanelModel.make(snapshot: Snapshot(states: states, order: order), seats: seats, now: now)
    }

    /// A 32 point icon as a site might serve it: a square glyph in the
    /// middle, black on a white disc, or orange straight on transparency.
    static func icon(plate: Bool) -> Data {
        let side = 32
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if plate {
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        } else {
            context.setFillColor(CGColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1))
        }
        context.fill(CGRect(x: 10, y: 10, width: 12, height: 12))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Each pixel's alpha, top row first.
    static func alphas(_ image: NSImage) -> [UInt8] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let width = cg.width, height = cg.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return (0..<(width * height)).map { bytes[$0 * 4 + 3] }
    }

    /// The bundled faces, registered for this process as the app registers
    /// them, so a width is measured in the face the card is drawn in.
    static func registerBundledFaces() -> Set<String> {
        let folder = root.appendingPathComponent("Resources/Fonts")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
        return Set(NSFontManager.shared.availableFontFamilies).intersection(FontManifest.fonts.map(\.family))
    }

    // MARK: - The fetched icon, redrawn in ink

    @Test func aFetchedIconBecomesATemplateAndItsPlateDropsOut() {
        for plate in [true, false] {
            let image = SeatMark.template(from: Self.icon(plate: plate))
            #expect(image?.isTemplate == true, "plate \(plate)")
            let alpha = image.map(Self.alphas) ?? []
            #expect(alpha.count == 32 * 32)
            guard alpha.count == 32 * 32 else { continue }
            #expect(alpha[16 * 32 + 16] == 255, "the glyph is ink, plate \(plate)")
            #expect(alpha[16 * 32 + 4] == 0, "beside the glyph is clear, plate \(plate)")
            #expect(alpha[0] == 0, "the corner is clear, plate \(plate)")
        }
        // A challenge page, or nothing, is no mark.
        #expect(SeatMark.template(from: Data("<html>just a moment</html>".utf8)) == nil)
        #expect(SeatMark.template(from: Data()) == nil)
    }

    @Test func aProviderWithNoIconDrawsItsNameAlone() {
        let was = GaugeMirror.shared.marks
        defer { GaugeMirror.shared.marks = was }
        GaugeMirror.shared.marks = [:]
        #expect(NSHostingView(rootView: SeatMarkView(provider: .codex)).fittingSize.width == 0)
        GaugeMirror.shared.marks = [.codex: SeatMark.template(from: Self.icon(plate: true))!]
        let drawn = NSHostingView(rootView: SeatMarkView(provider: .codex)).fittingSize
        #expect(drawn.width == SeatMark.side(TextScale.current))
        #expect(NSHostingView(rootView: SeatMarkView(provider: .claude)).fittingSize.width == 0)
    }

    // MARK: - The header steps with the size and fits the narrowest card

    @Test func theHeaderStepsWithTheSizeAndFitsTheMinimumCard() {
        let was = GaugeMirror.shared.textScale
        let faces = Type.registered
        defer {
            GaugeMirror.shared.textScale = was
            Type.registered = faces
        }
        for registered in [Set<String>(), Self.registerBundledFaces()] {
            Type.registered = registered
            var widths: [CGFloat] = []
            for step in TextScale.steps {
                GaugeMirror.shared.textScale = TextScale(step: step)
                let widest = CardMetrics.headerWidth(provider: "Codex", seat: "desktop", picked: true)
                #expect(widest <= CardMetrics.minimumWidth,
                        "step \(step), faces \(registered): \(widest) over \(CardMetrics.minimumWidth)")
                #expect(widest > CardMetrics.headerWidth(provider: "Codex", seat: "one", picked: true))
                widths.append(widest)
            }
            #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 < $1 })
            // The header grows with the size as the rules do, not beside them.
            let growth = widths[TextScale.largest.step] / widths[TextScale.normal.step]
            let factor = CGFloat(TextScale.largest.factor / TextScale.normal.factor)
            #expect(abs(growth - factor) < factor * 0.1, "\(growth) against \(factor)")
        }
    }

    // MARK: - Fails closed

    @Test func aBadLabelOrAnUndeclaredSeatStillReadsProviderFirst() {
        let model = Self.panel([Self.claude("work", label: ""), Self.codex("codex", label: "Claude")],
                               readings: ["work", "codex", "stranger"])
        #expect(model.cards.count == 3)
        guard model.cards.count == 3 else { return }

        // An empty label is not a name: the id is drawn instead.
        #expect(model.cards[0].label == "work")
        #expect(model.cards[0].heading == "CLAUDE  work")
        // The provider is the kind's, whatever the label says.
        #expect(model.cards[1].provider == "Codex")
        #expect(model.cards[1].heading == "CODEX  Claude")
        // A reading nothing declares reads as Claude, as its mark does.
        #expect(model.cards[2].provider == "Claude")
        #expect(model.cards[2].mark == .claude)
        #expect(model.cards[2].label == "stranger")

        // What never truncates fits; an overlong label is what gives way.
        CardWidthTests.atOrdinaryStep { _ in
            for provider in ["Claude", "Codex"] {
                #expect(CardMetrics.headerWidth(provider: provider, seat: "", picked: true)
                    <= CardMetrics.minimumWidth)
            }
            let long = String(repeating: "w", count: 80)
            #expect(CardMetrics.headerWidth(provider: "Codex", seat: long, picked: true)
                > CardMetrics.minimumWidth)
        }
    }
}
