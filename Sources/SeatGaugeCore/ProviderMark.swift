import Foundation

/// Each provider's mark is its own site's icon, fetched on this machine and
/// kept in Application Support. No mark ships in the repository or the
/// bundle, so the source carries nobody's logo.
///
/// A provider is fetched once, when no icon is cached, with a short timeout
/// and no cookies. A failed fetch leaves no mark, so its card draws the name
/// alone, and the fetch is tried again at the next launch.
///
/// What comes back is untrusted, so every part of it has a limit: bytes
/// while they arrive, the hosts a redirect or a declared icon may lead to
/// (`allows`), and, in the app, an image's size and frames before it is
/// decoded. An icon the app cannot use is evicted.
public struct MarkCache: Sendable {
    /// Hands back the body of a `200` reply of at most the given number of
    /// bytes, or nil for anything else. A parameter so no case reaches the
    /// network.
    public typealias Download = @Sendable (URL, Int) async -> Data?

    /// The most an icon may be. The real ones were 2.4 KB (Claude) and
    /// 32 KB (ChatGPT) in October 2026.
    public static let largestIcon = 1 << 20
    /// The most a home page may be, read only for its icon link. The real
    /// ones were 0.15 MB and 0.6 MB.
    public static let largestPage = 4 << 20

    let folder: URL
    let download: Download

    public init(folder: URL = AppPaths.support.appendingPathComponent("marks", isDirectory: true),
                download: @escaping Download = MarkCache.download) {
        self.folder = folder
        self.download = download
    }

    func icon(_ provider: Provider) -> URL { folder.appendingPathComponent("\(provider.rawValue).icon") }

    /// The provider's cached icon, or the one its site serves when none is
    /// cached yet. A cached file past the limit, or not an image, is
    /// dropped and fetched again rather than read.
    public func mark(for provider: Provider) async -> Data? {
        let file = icon(provider)
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int {
            if size <= Self.largestIcon, let cached = FileManager.default.contents(atPath: file.path),
               Self.isImage(cached) { return cached }
            evict(provider)
        }
        guard let fetched = await fetch(provider) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fetched.write(to: icon(provider), options: .atomic)
        return fetched
    }

    /// Removes a cached icon, so the next launch fetches it again. For an
    /// icon the app found it could not use.
    public func evict(_ provider: Provider) {
        try? FileManager.default.removeItem(at: icon(provider))
    }

    /// `/favicon.ico` first, then the icon the home page declares, when it
    /// is on the provider's own domains.
    func fetch(_ provider: Provider) async -> Data? {
        let site = provider.site
        if let root = URL(string: "/favicon.ico", relativeTo: site)?.absoluteURL,
           let data = await download(root, Self.largestIcon), Self.isImage(data) { return data }
        guard let page = await download(site, Self.largestPage),
              let declared = Self.declaredIcon(in: String(decoding: page, as: UTF8.self), site: site),
              Self.allows(declared, for: provider),
              let data = await download(declared, Self.largestIcon), Self.isImage(data) else { return nil }
        return data
    }

    /// The domains a provider's icon may come from, its own and the ones its
    /// pages serve their assets from, each with every subdomain.
    static func domains(_ provider: Provider) -> [String] {
        switch provider {
        case .claude: ["claude.ai", "anthropic.com"]
        case .codex: ["chatgpt.com", "openai.com", "oaistatic.com"]
        }
    }

    /// Whether a URL, the first one or any a redirect leads to, is https on
    /// one of the provider's domains.
    static func allows(_ url: URL, for provider: Provider) -> Bool {
        allows(url, within: domains(provider))
    }

    static func allows(_ url: URL, within domains: [String]) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The body, byte by byte as it arrives, or nil once it passes `limit`,
    /// so an endless or huge reply is never held whole.
    static func collect<S: AsyncSequence>(_ bytes: S, limit: Int) async -> Data? where S.Element == UInt8 {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }
            }
        } catch { return nil }
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

    /// Safari's own User-Agent, as every Mac sends it (Safari freezes the
    /// macOS version in it), in place of URLSession's, which names the app,
    /// its version, CFNetwork and Darwin. A bare `Mozilla/5.0` is turned away
    /// by chatgpt.com's bot check.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// The session every fetch goes through: ephemeral, no cookies sent or
    /// kept, no stored credentials, no cache, a neutral User-Agent, and five
    /// seconds to answer.
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
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: configuration)
    }()

    /// A plain GET over https, kept on the first URL's provider domains
    /// through any redirect, read to at most `limit` bytes. Anything but a
    /// `200` is no icon.
    public static let download: Download = download(through: session)

    /// The download over a given session, so a case can serve it from a
    /// stand-in protocol rather than the network. The task is cancelled
    /// whenever the read stops, so a refused body is not received on.
    static func download(through session: URLSession) -> Download {
        { url, limit in
            guard let provider = Provider.allCases.first(where: { allows(url, for: $0) }) else { return nil }
            let domains = domains(provider)
            guard let (bytes, response) = try? await session.bytes(from: url, delegate: Redirects(domains: domains))
            else { return nil }
            defer { bytes.task.cancel() }
            guard let reply = response as? HTTPURLResponse, reply.statusCode == 200,
                  let final = reply.url, allows(final, within: domains),
                  reply.expectedContentLength <= Int64(limit) else { return nil }
            return await collect(bytes, limit: limit)
        }
    }

    /// Refuses a redirect off https or off the provider's domains, so the
    /// reply is the redirect itself, which is no `200`.
    final class Redirects: NSObject, URLSessionTaskDelegate, Sendable {
        let domains: [String]
        init(domains: [String]) { self.domains = domains }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, MarkCache.allows(url, within: domains) else { return nil }
            return request
        }
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
