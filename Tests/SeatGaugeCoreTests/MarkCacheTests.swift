import Foundation
import Testing

@testable import SeatGaugeCore

/// A provider's mark is its site's icon, fetched here once, when none is
/// cached, and kept in Application Support. No case reaches the network: the download is
/// a stand-in that counts what it was asked for.
@Suite struct MarkCacheTests {

    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    static let ico = Data([0, 0, 1, 0, 1, 0, 16, 16])

    /// Answers from a table and remembers every URL asked for.
    final class Site: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: Data]
        private(set) var asked: [String] = []
        init(_ answers: [String: Data]) { self.answers = answers }
        var download: MarkCache.Download {
            { url in
                self.lock.withLock {
                    self.asked.append(url.absoluteString)
                    return self.answers[url.absoluteString]
                }
            }
        }
        func answer(_ url: String, with data: Data?) { lock.withLock { answers[url] = data } }
        var count: Int { lock.withLock { asked.count } }
    }

    static func folder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-marks-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func anIconIsFetchedOnceAndKept() async {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let site = Site(["https://claude.ai/favicon.ico": Self.ico])
        let cache = MarkCache(folder: folder, download: site.download)

        #expect(await cache.mark(for: .claude) == Self.ico)
        #expect(site.asked == ["https://claude.ai/favicon.ico"])
        // Cached: the icon, and never another request, whatever the site now serves.
        site.answer("https://claude.ai/favicon.ico", with: Self.png)
        #expect(await cache.mark(for: .claude) == Self.ico)
        #expect(await MarkCache(folder: folder, download: site.download).mark(for: .claude) == Self.ico)
        #expect(site.count == 1)
        #expect(FileManager.default.contents(atPath: cache.icon(.claude).path) == Self.ico)
    }

    @Test func aFailedFetchLeavesNoMarkAndIsTriedAgainAtTheNextLaunch() async {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let site = Site([:])

        // No cache and no answer: no mark, and the provider's name stands alone.
        #expect(await MarkCache(folder: folder, download: site.download).mark(for: .codex) == nil)
        #expect(site.count == 2, "the icon, then the page for a declared one")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "nothing is written for a failure")

        // The next launch tries again, and keeps what it gets.
        site.answer("https://chatgpt.com/favicon.ico", with: Self.png)
        let next = MarkCache(folder: folder, download: site.download)
        #expect(await next.mark(for: .codex) == Self.png)
        #expect(site.count == 3)
        #expect(FileManager.default.contents(atPath: next.icon(.codex).path) == Self.png)
    }

    @Test func aChallengePageIsNotAnIconAndTheDeclaredIconIsTried() async {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = #"<html><head><link rel="stylesheet" href="/a.css"><link href="/static/icon-32.png" rel="icon" sizes="32x32"></head></html>"#
        let site = Site(["https://chatgpt.com/favicon.ico": Data("<html>just a moment</html>".utf8),
                         "https://chatgpt.com/": Data(page.utf8),
                         "https://chatgpt.com/static/icon-32.png": Self.png])
        let cache = MarkCache(folder: folder, download: site.download)
        #expect(await cache.mark(for: .codex) == Self.png)
        #expect(site.asked == ["https://chatgpt.com/favicon.ico", "https://chatgpt.com/",
                               "https://chatgpt.com/static/icon-32.png"])
    }

    @Test func theDeclaredIconIsTheFirstHttpsIconLink() {
        let site = URL(string: "https://example.test/")!
        #expect(MarkCache.declaredIcon(in: #"<LINK REL='Shortcut Icon' HREF='/f.ico'>"#, site: site)?.absoluteString
            == "https://example.test/f.ico")
        #expect(MarkCache.declaredIcon(in: #"<link rel="apple-touch-icon" href="/t.png"><link rel="icon" href="//cdn.test/i.png">"#,
                                       site: site)?.absoluteString == "https://cdn.test/i.png")
        #expect(MarkCache.declaredIcon(in: #"<link rel="icon" href="http://plain.test/i.png">"#, site: site) == nil)
        #expect(MarkCache.declaredIcon(in: "<p>no links</p>", site: site) == nil)
    }

    @Test func theSessionSendsNoCookiesAndGivesUpQuickly() {
        let configuration = MarkCache.session.configuration
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.timeoutIntervalForRequest <= 5)
        #expect(configuration.timeoutIntervalForResource <= 10)
    }

    // MARK: - The mask

    /// Premultiplied RGBA from straight colours and alphas.
    static func pixels(_ list: [(r: Double, g: Double, b: Double, a: Double)]) -> [UInt8] {
        list.flatMap { p in [p.r * p.a, p.g * p.a, p.b * p.a, p.a].map { UInt8(($0 * 255).rounded()) } }
    }

    @Test func anIconOnTransparencyIsItsAlpha() {
        let orange = (r: 0.85, g: 0.47, b: 0.34)
        let icon = Self.pixels(Array(repeating: (orange.r, orange.g, orange.b, 1.0), count: 30)
                               + Array(repeating: (orange.r, orange.g, orange.b, 0.5), count: 10)
                               + Array(repeating: (0, 0, 0, 0), count: 60))
        let mask = MarkMask.coverage(icon)
        #expect(mask[0] == 255)
        #expect(mask[35] == 128)
        #expect(mask[99] == 0)
    }

    @Test func aPlateBehindTheGlyphDropsOut() {
        // A white disc behind a black glyph, on transparency.
        let icon = Self.pixels(Array(repeating: (1, 1, 1, 1), count: 60)
                               + Array(repeating: (0, 0, 0, 1), count: 20)
                               + Array(repeating: (0.5, 0.5, 0.5, 1), count: 5)
                               + Array(repeating: (0, 0, 0, 0), count: 15))
        let mask = MarkMask.coverage(icon)
        #expect(mask[0] == 0, "the plate")
        #expect(mask[60] == 255, "the glyph")
        #expect((100...155).contains(mask[80]), "an edge between them: \(mask[80])")
        #expect(mask[99] == 0, "the ground")
    }
}
