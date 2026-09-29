import AppKit
import CoreText
import OSLog
import SeatGaugeCore

/// Registers the faces that ship inside the bundle. `scripts/build-app.sh`
/// copies them to `Contents/Resources/Fonts` by hand: SwiftPM `resources:`
/// generates an accessor that looks beside the .app and at the absolute build
/// path, so an installed copy crashes on the first lookup.
enum FontLoader {
    static let log = Logger(subsystem: AppPaths.bundleID, category: "fonts")

    /// Never throws and never traps. A face that will not register is logged
    /// and left out of `Type.registered`, which draws it as the system font.
    @discardableResult
    static func registerBundledFonts() -> Int {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        var registered = 0
        for url in urls {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                registered += 1
            } else {
                log.error("font \(url.lastPathComponent, privacy: .public) did not register")
            }
        }
        if let folder = Bundle.main.url(forResource: "Fonts", withExtension: nil) {
            for face in FontManifest.missing(in: folder) {
                log.error("font \(face.file, privacy: .public) is missing from the bundle")
            }
        } else {
            log.error("the bundle carries no Fonts directory")
        }
        let families = Set(NSFontManager.shared.availableFontFamilies)
        Type.registered = families.intersection(FontManifest.fonts.map(\.family))
        let drawable = Type.registered.count
        log.notice("registered \(registered, privacy: .public) of \(urls.count, privacy: .public) bundled font files, \(drawable, privacy: .public) families drawable")
        return registered
    }
}
