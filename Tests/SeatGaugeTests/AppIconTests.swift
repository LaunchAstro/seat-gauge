import AppKit
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The app icon: drawn by its script and carried by the bundle. The script cases run the real `scripts/make-icon.swift` and the real
/// `scripts/build-app.sh`, the second in a copy of the repository's layout
/// with `swift` and `codesign` stubbed, so nothing here builds a release,
/// signs, or writes into the repository.
@Suite(.sharedMirror) @MainActor struct AppIconTests {

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SeatGaugeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the repository

    static let iconset = [
        "icon_16x16", "icon_16x16@2x", "icon_32x32", "icon_32x32@2x",
        "icon_128x128", "icon_128x128@2x", "icon_256x256", "icon_256x256@2x",
        "icon_512x512", "icon_512x512@2x",
    ]

    static func scratch(_ label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], path: String = "/usr/bin:/bin:/usr/sbin:/sbin",
                    in directory: URL? = nil) throws -> (status: Int32, out: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.environment = ["PATH": path, "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        if let directory { task.currentDirectoryURL = directory }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        return (task.terminationStatus, out)
    }

    static func makeIcon(_ icns: URL) throws -> (status: Int32, out: String) {
        try run("/usr/bin/env", ["swift", root.appendingPathComponent("scripts/make-icon.swift").path,
                                 icns.path], in: root)
    }

    /// The ten names an icns unpacks to, and its 1024 image.
    static func unpack(_ icns: URL) throws -> (names: Set<String>, face: NSBitmapImageRep) {
        let base = try scratch("iconset")
        defer { try? FileManager.default.removeItem(at: base) }
        let out = base.appendingPathComponent("AppIcon.iconset")
        let ran = try run("/usr/bin/iconutil", ["-c", "iconset", icns.path, "-o", out.path])
        #expect(ran.status == 0, "\(ran.out)")
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path)
            .filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) }
        let data = try Data(contentsOf: out.appendingPathComponent("icon_512x512@2x").appendingPathExtension("png"))
        return (Set(names), try #require(NSBitmapImageRep(data: data)))
    }

    static func rgba(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> [CGFloat] {
        let colour = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return [colour.redComponent, colour.greenComponent, colour.blueComponent, colour.alphaComponent]
    }

    struct Built {
        let status: Int32
        let out: String
        let app: URL
    }

    /// `build-app.sh` in a copy of the repository's layout: the script, the
    /// fonts, the version and, unless told not to, the icns, with a `swift`
    /// that writes the executable and a `codesign` that says yes.
    static func buildApp(icon: Bool = true) throws -> Built {
        let base = try scratch("build-app")
        let fm = FileManager.default
        for directory in ["scripts", "Resources", "bin"] {
            try fm.createDirectory(at: base.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try fm.copyItem(at: root.appendingPathComponent("scripts/build-app.sh"),
                        to: base.appendingPathComponent("scripts/build-app.sh"))
        try fm.copyItem(at: root.appendingPathComponent("VERSION"), to: base.appendingPathComponent("VERSION"))
        try fm.copyItem(at: root.appendingPathComponent("Resources/Fonts"),
                        to: base.appendingPathComponent("Resources/Fonts"))
        if icon {
            try fm.copyItem(at: root.appendingPathComponent("Resources/AppIcon.icns"),
                            to: base.appendingPathComponent("Resources/AppIcon.icns"))
        }
        let stubs = [
            "swift": "mkdir -p .build/release && printf built > .build/release/SeatGauge",
            "codesign": "exit 0",
        ]
        for (name, body) in stubs {
            let file = base.appendingPathComponent("bin/\(name)")
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let bin = base.appendingPathComponent("bin").path
        let ran = try run("/bin/bash", [base.appendingPathComponent("scripts/build-app.sh").path],
                          path: "\(bin):/usr/bin:/bin:/usr/sbin:/sbin")
        return Built(status: ran.status, out: ran.out, app: base.appendingPathComponent("dist/Seat Gauge.app"))
    }

    /// The icon file a bundle's plist names, beside it in `Contents/Resources`.
    static func iconFile(_ app: URL) throws -> URL {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any])
        let name = try #require(plist["CFBundleIconFile"] as? String)
        let file = name.hasSuffix(".icns") ? name : name + ".icns"
        return app.appendingPathComponent("Contents/Resources/\(file)")
    }

    // MARK: - The icns is drawn by the script

    @Test("make-icon.swift regenerates the committed icns")
    func iconRegeneratesFromTheScript() throws {
        let icns = Self.root.appendingPathComponent("Resources/AppIcon.icns")
        let made = try Self.scratch("make-icon")
        defer { try? FileManager.default.removeItem(at: made) }
        let out = made.appendingPathComponent("AppIcon.icns")
        let ran = try Self.makeIcon(out)
        #expect(ran.status == 0, "\(ran.out)")

        let committed = try Self.unpack(icns)
        let fresh = try Self.unpack(out)
        #expect(committed.names == Set(Self.iconset))
        #expect(fresh.names == Set(Self.iconset))

        // The same face: sampled across the whole 1024 image, the mean
        // difference per channel is under one step in a hundred.
        var total: CGFloat = 0
        var count: CGFloat = 0
        for y in stride(from: 0, to: 1024, by: 8) {
            for x in stride(from: 0, to: 1024, by: 8) {
                let a = try Self.rgba(committed.face, x, y), b = try Self.rgba(fresh.face, x, y)
                total += zip(a, b).map { abs($0 - $1) }.reduce(0, +)
                count += 4
            }
        }
        #expect(total / count < 0.01)

        // A dark tile with its rounded corners clear.
        let face = committed.face
        for (x, y) in [(0, 0), (1023, 0), (0, 1023), (1023, 1023), (110, 110), (913, 913)] {
            #expect(try Self.rgba(face, x, y)[3] == 0, "corner (\(x), \(y)) is not transparent")
        }
        let tile = try Self.rgba(face, 512, 880)
        #expect(tile[3] == 1 && tile[0] < 0.2)
    }

    // MARK: - The bundle carries it

    @Test("the built bundle names its icon and carries it beside the plist")
    func bundleCarriesTheIcon() throws {
        let built = try Self.buildApp()
        defer { try? FileManager.default.removeItem(at: built.app.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(built.status == 0, "\(built.out)")
        let icon = try Self.iconFile(built.app)
        #expect(icon.lastPathComponent == "AppIcon.icns")
        let repository = try Data(contentsOf: Self.root.appendingPathComponent("Resources/AppIcon.icns"))
        #expect(try Data(contentsOf: icon) == repository)

        // And a real build's bundle, when there is one to read.
        let dist = Self.root.appendingPathComponent("dist/Seat Gauge.app")
        if Self.exists(dist) { #expect(Self.exists(try Self.iconFile(dist))) }
    }

    // MARK: - Fails closed

    @Test("a run that cannot write leaves the icns alone, and no icns builds no plist")
    func failsClosed() throws {
        let base = try Self.scratch("fails-closed")
        let fm = FileManager.default
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.path)
            try? fm.removeItem(at: base)
        }
        let icns = base.appendingPathComponent("AppIcon.icns")
        let old = Data("the icns before".utf8)
        try old.write(to: icns)
        // The new icns is packed beside the old one, so a folder that takes no
        // writes fails the run before anything is swapped.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: base.path)
        let ran = try Self.makeIcon(icns)
        #expect(ran.status != 0)
        #expect(try Data(contentsOf: icns) == old)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.path)

        let built = try Self.buildApp(icon: false)
        defer { try? FileManager.default.removeItem(at: built.app.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(built.status != 0)
        #expect(!Self.exists(built.app.appendingPathComponent("Contents/Info.plist")))
    }
}
