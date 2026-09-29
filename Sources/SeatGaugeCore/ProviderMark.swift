import Foundation

/// Each provider's mark is its own site's icon, fetched on this machine and
/// kept in Application Support. No mark ships in the repository or the
/// bundle, so the source carries nobody's logo.
///
/// A provider is fetched once, when no icon is cached, with a short timeout
/// and no cookies. A failed fetch leaves no mark, so its card draws the name
/// alone, and the fetch is tried again at the next launch.
public struct MarkCache: Sendable {
    /// Hands back the body of a `200` reply, or nil for anything else. A
    /// parameter so no case reaches the network.
    public typealias Download = @Sendable (URL) async -> Data?

    let folder: URL
    let download: Download

    public init(folder: URL = AppPaths.support.appendingPathComponent("marks", isDirectory: true),
                download: @escaping Download = MarkCache.download) {
        self.folder = folder
        self.download = download
    }

    func icon(_ provider: Provider) -> URL { folder.appendingPathComponent("\(provider.rawValue).icon") }

    /// The provider's cached icon, or the one its site serves when none is
    /// cached yet.
    public func mark(for provider: Provider) async -> Data? {
        if let cached = FileManager.default.contents(atPath: icon(provider).path) { return cached }
        guard let fetched = await fetch(provider.site) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fetched.write(to: icon(provider), options: .atomic)
        return fetched
    }

    /// `/favicon.ico` first, then the icon the home page declares.
    func fetch(_ site: URL) async -> Data? {
        if let root = URL(string: "/favicon.ico", relativeTo: site)?.absoluteURL,
           let data = await download(root), Self.isImage(data) { return data }
        guard let page = await download(site),
              let declared = Self.declaredIcon(in: String(decoding: page, as: UTF8.self), site: site),
              let data = await download(declared), Self.isImage(data) else { return nil }
        return data
    }

    /// The first `<link rel="icon">` (or `shortcut icon`) with an https href.
    static func declaredIcon(in html: String, site: URL) -> URL? {
        let tags = html.matches(of: #/<link\b[^>]*>/#.ignoresCase())
        for tag in tags.map({ String($0.output) }) {
            guard let rel = attribute("rel", in: tag),
                  rel.lowercased().split(separator: " ").contains("icon"),
                  let href = attribute("href", in: tag),
                  let url = URL(string: href, relativeTo: site)?.absoluteURL,
                  url.scheme == "https" else { continue }
            return url
        }
        return nil
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = try? Regex<(Substring, Substring)>(#"\b"# + name + #"\s*=\s*["']([^"']*)["']"#)
        guard let pattern, let match = tag.firstMatch(of: pattern.ignoresCase()) else { return nil }
        return String(match.output.1)
    }

    /// ICO, PNG, GIF or JPEG by their first bytes. A challenge page served
    /// with a `200` is not an icon.
    static func isImage(_ data: Data) -> Bool {
        let magic: [[UInt8]] = [[0, 0, 1, 0], [0x89, 0x50, 0x4E, 0x47], [0x47, 0x49, 0x46, 0x38], [0xFF, 0xD8, 0xFF]]
        return magic.contains { data.starts(with: $0) }
    }

    /// The session every fetch goes through: ephemeral, no cookies sent or
    /// kept, no stored credentials, no cache, and five seconds to answer.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

    /// A plain GET over https. Anything but a `200` is no icon.
    public static let download: Download = { url in
        guard url.scheme == "https",
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

/// How much of each pixel of an icon is the mark, so the card can fill it in
/// its own ink. Pixels are RGBA, 8 bits each, premultiplied, as a bitmap
/// context draws them.
///
/// An icon drawn straight on transparency is its alpha. An icon drawn on a
/// plate of one colour (a white disc behind a black glyph) is how far each
/// pixel is from the plate, so the plate drops out and the glyph stays.
public enum MarkMask {
    public static func coverage(_ rgba: [UInt8]) -> [UInt8] {
        let count = rgba.count / 4
        var colours: [SIMD3<Double>] = []
        var alphas: [Double] = []
        colours.reserveCapacity(count)
        alphas.reserveCapacity(count)
        for index in 0..<count {
            let alpha = Double(rgba[index * 4 + 3]) / 255
            let straight = alpha > 0 ? (0..<3).map { Double(rgba[index * 4 + $0]) / 255 / alpha } : [0, 0, 0]
            colours.append(SIMD3(straight[0], straight[1], straight[2]))
            alphas.append(alpha)
        }
        let solid = colours.indices.filter { alphas[$0] > 0.5 }
        guard let plate = dominant(solid.map { colours[$0] }) else {
            return alphas.map { UInt8(($0 * 255).rounded()) }
        }
        let distance = colours.map { distanceBetween($0, plate) }
        let far = solid.filter { distance[$0] > 0.25 }
        // One colour and no glyph on it: the icon is its own shape.
        guard Double(far.count) >= Double(solid.count) * 0.05,
              let reach = far.map({ distance[$0] }).max() else {
            return alphas.map { UInt8(($0 * 255).rounded()) }
        }
        return colours.indices.map { index in
            UInt8((alphas[index] * min(1, distance[index] / reach) * 255).rounded())
        }
    }

    /// The most common colour, to an eighth of each channel, when it covers
    /// at least two fifths of the pixels given.
    static func dominant(_ colours: [SIMD3<Double>]) -> SIMD3<Double>? {
        var buckets: [SIMD3<Int>: (count: Int, sum: SIMD3<Double>)] = [:]
        for colour in colours {
            let key = SIMD3<Int>(Int(colour.x * 7.99), Int(colour.y * 7.99), Int(colour.z * 7.99))
            let was = buckets[key] ?? (0, .zero)
            buckets[key] = (was.count + 1, was.sum + colour)
        }
        guard let top = buckets.values.max(by: { $0.count < $1.count }),
              Double(top.count) >= Double(colours.count) * 0.4 else { return nil }
        return top.sum / Double(top.count)
    }

    static func distanceBetween(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return (d * d).sum().squareRoot() / 3.0.squareRoot()
    }
}
