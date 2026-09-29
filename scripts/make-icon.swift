// Draw the app icon and pack it into Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift [icns]
//
// The icon is a gauge on a dark rounded tile: a 240 degree track, a violet arc
// filled to about 60 percent, and a needle at the arc's end. AppKit draws it at
// the ten iconset sizes and `iconutil` packs them. The icns is written beside
// its target first and moved into place only once `iconutil` has succeeded, so
// a run that fails exits 1 and leaves the old icns where it was.
import AppKit

let args = CommandLine.arguments
let icns = URL(fileURLWithPath: args.count > 1 ? args[1] : "Resources/AppIcon.icns")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// The icon on a 1024 point canvas, origin bottom left. Every size is this
/// drawing scaled, so the proportions hold from 16 px to 1024 px.
func draw() {
    // The macOS icon grid: an 824 point tile, 100 in from each edge.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                            xRadius: 185, yRadius: 185)
    NSGradient(starting: colour(0x1c1c22), ending: colour(0x0b0b0e))!.draw(in: tile, angle: -90)

    let centre = NSPoint(x: 512, y: 470)
    let radius: CGFloat = 270
    let start: CGFloat = 210, end: CGFloat = -30, reading: CGFloat = 66

    func arc(from: CGFloat, to: CGFloat, width: CGFloat, in ink: NSColor) {
        let path = NSBezierPath()
        path.appendArc(withCenter: centre, radius: radius, startAngle: from, endAngle: to, clockwise: true)
        path.lineWidth = width
        path.lineCapStyle = .round
        ink.setStroke()
        path.stroke()
    }
    arc(from: start, to: end, width: 64, in: colour(0xffffff, 0.12))
    arc(from: start, to: reading, width: 64, in: colour(0x745cee))

    let angle = reading * .pi / 180
    let needle = NSBezierPath()
    needle.move(to: centre)
    needle.line(to: NSPoint(x: centre.x + cos(angle) * 210, y: centre.y + sin(angle) * 210))
    needle.lineWidth = 30
    needle.lineCapStyle = .round
    colour(0xf2f2f2).setStroke()
    needle.stroke()

    colour(0xf2f2f2).setFill()
    NSBezierPath(ovalIn: NSRect(x: centre.x - 48, y: centre.y - 48, width: 96, height: 96)).fill()
    colour(0x0b0b0e).setFill()
    NSBezierPath(ovalIn: NSRect(x: centre.x - 18, y: centre.y - 18, width: 36, height: 36)).fill()
}

let work = FileManager.default.temporaryDirectory
    .appendingPathComponent("make-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = work.appendingPathComponent("AppIcon.iconset", isDirectory: true)
defer { try? FileManager.default.removeItem(at: work) }
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
             ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
             ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
for (name, px) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(px) / 1024)
    scale.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("\(name) did not encode") }
    try png.write(to: iconset.appendingPathComponent("\(name).png"))
}

// Beside the target, so the swap below stays on one volume.
let packed = icns.deletingLastPathComponent().appendingPathComponent(".make-icon-\(UUID().uuidString).icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", packed.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    try? FileManager.default.removeItem(at: packed)
    fail("iconutil exited \(iconutil.terminationStatus)")
}

if FileManager.default.fileExists(atPath: icns.path) {
    _ = try FileManager.default.replaceItemAt(icns, withItemAt: packed)
} else {
    try FileManager.default.moveItem(at: packed, to: icns)
}
print("wrote \(icns.path)")
