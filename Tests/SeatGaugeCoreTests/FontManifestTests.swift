import Foundation
import Testing

import SeatGaugeCore

@Test func theManifestNamesThreeFacesAndTheirFamilies() {
    #expect(FontManifest.fonts.count == 3)
    #expect(FontManifest.fonts.map(\.family) == ["Funnel Display", "Funnel Sans", "Chivo Mono"])
}

@Test func everyFontAndItsLicenceAreInTheTree() throws {
    let fonts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SeatGaugeCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the repository
        .appendingPathComponent("Resources/Fonts", isDirectory: true)
    #expect(FontManifest.missing(in: fonts).isEmpty)
    let licence = try String(contentsOf: fonts.appendingPathComponent("OFL.txt"), encoding: .utf8)
    #expect(licence.contains("SIL Open Font License"))
}

@Test func aMissingFontIsReportedAndItsFamilyFallsBack() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("seat-gauge-fonts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let present = FontManifest.fonts.dropLast()
    let absent = try #require(FontManifest.fonts.last)
    for font in present {
        try Data().write(to: directory.appendingPathComponent(font.file))
    }
    #expect(FontManifest.missing(in: directory).map(\.file) == [absent.file])

    // Nothing registered at all, and a directory that is not there: both are
    // answered, neither traps.
    #expect(FontManifest.missing(in: directory.appendingPathComponent("gone")).count
            == FontManifest.fonts.count)
    let registered = Set(present.map(\.family))
    #expect(FontManifest.familyName(absent.family, registered: registered) == nil)
    #expect(FontManifest.familyName(absent.family, registered: registered.union([absent.family]))
            == absent.family)
}
