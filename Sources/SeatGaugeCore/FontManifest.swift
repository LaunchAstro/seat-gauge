import Foundation

/// The three OFL faces the app ships, and the two questions the app asks about
/// them: which files a bundle is missing, and whether a family that never
/// registered has anything to draw with. Both answers are data, so the
/// fails-closed decision lives here, where a test can read it, rather than
/// inside AppKit where it cannot.
public enum FontManifest {
    public struct Face: Equatable, Sendable {
        public let file: String
        public let family: String
        public init(file: String, family: String) {
            self.file = file
            self.family = family
        }
    }

    public static let fonts: [Face] = [
        Face(file: "FunnelDisplay[wght].ttf", family: "Funnel Display"),
        Face(file: "FunnelSans[wght].ttf", family: "Funnel Sans"),
        Face(file: "ChivoMono[wght].ttf", family: "Chivo Mono"),
    ]

    /// The faces with no file in `directory`. A directory that is not there
    /// answers with all of them rather than trapping.
    public static func missing(in directory: URL, fileManager: FileManager = .default) -> [Face] {
        fonts.filter { face in
            !fileManager.fileExists(atPath: directory.appendingPathComponent(face.file).path)
        }
    }

    /// The family to draw with, or nil when nothing registered it, which
    /// `Type` reads as its system-font fallback.
    public static func familyName(_ family: String, registered: Set<String>) -> String? {
        registered.contains(family) ? family : nil
    }
}
