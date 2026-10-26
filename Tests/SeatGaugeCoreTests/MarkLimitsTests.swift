import Foundation
import Testing

@testable import SeatGaugeCore

/// The favicon fetch talks to the network, so everything it takes in has a
/// limit: bytes while they arrive, the hosts a redirect or a declared icon may
/// lead to, and what the request says about the app. No case reaches the
/// network.
@Suite struct MarkLimitsTests {
    static let ico = Data([0, 0, 1, 0, 1, 0, 16, 16])

    static func folder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-mark-limits-\(UUID().uuidString)", isDirectory: true)
    }

    static func bytes(_ count: Int) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for _ in 0 ..< count { continuation.yield(0x41) }
            continuation.finish()
        }
    }

    @Test("a body past the limit is refused while it arrives, and one under it is kept whole")
    func bytesAreCapped() async {
        #expect(await MarkCache.collect(Self.bytes(MarkCache.largestIcon + 1), limit: MarkCache.largestIcon) == nil)
        #expect(await MarkCache.collect(Self.bytes(1000), limit: MarkCache.largestIcon)?.count == 1000)
    }

    @Test("only https on the provider's own domains is followed",
          arguments: [("https://claude.ai/favicon.ico", true), ("https://assets-proxy.anthropic.com/i.png", true),
                      ("https://cdn.oaistatic.com/i.png", false), ("http://claude.ai/favicon.ico", false),
                      ("https://evilclaude.ai/i.png", false), ("https://claude.ai.example.com/i.png", false),
                      ("https://example.com/claude.ai", false)])
    func claudeHosts(_ url: String, _ allowed: Bool) {
        #expect(MarkCache.allows(URL(string: url)!, for: .claude) == allowed)
    }

    @Test("Codex's mark may come from chatgpt.com and OpenAI's own domains only")
    func codexHosts() {
        #expect(MarkCache.allows(URL(string: "https://chatgpt.com/favicon.ico")!, for: .codex))
        #expect(MarkCache.allows(URL(string: "https://cdn.oaistatic.com/i.png")!, for: .codex))
        #expect(!MarkCache.allows(URL(string: "https://claude.ai/favicon.ico")!, for: .codex))
    }

    @Test("a declared icon on another host is never asked for")
    func declaredIconElsewhere() async {
        let folder = Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let page = #"<link rel="icon" href="https://tracker.example/i.png">"#
        let site = MarkCacheTests.Site(["https://claude.ai/": Data(page.utf8),
                                        "https://tracker.example/i.png": Self.ico])
        #expect(await MarkCache(folder: folder, download: site.download).mark(for: .claude) == nil)
        #expect(site.asked == ["https://claude.ai/favicon.ico", "https://claude.ai/"])
    }

    @Test("each download is told its byte limit: an icon's, then the page's")
    func limitsArePassed() async {
        let folder = Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let limits = Limits()
        let cache = MarkCache(folder: folder, download: { url, limit in limits.add(url.lastPathComponent, limit); return nil })
        _ = await cache.mark(for: .codex)
        #expect(limits.seen == ["favicon.ico:\(MarkCache.largestIcon)", "/:\(MarkCache.largestPage)"])
    }

    final class Limits: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ name: String, _ limit: Int) { lock.withLock { list.append("\(name):\(limit)") } }
        var seen: [String] { lock.withLock { list } }
    }

    @Test("a cached icon past the limit is dropped and fetched again rather than read")
    func oversizedCacheIsEvicted() async throws {
        let folder = Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let site = MarkCacheTests.Site(["https://claude.ai/favicon.ico": Self.ico])
        let cache = MarkCache(folder: folder, download: site.download)
        try Data(count: MarkCache.largestIcon + 1).write(to: cache.icon(.claude))
        #expect(await cache.mark(for: .claude) == Self.ico)
        #expect(site.count == 1)
    }

    @Test("an icon the app could not use is evicted, so the next launch fetches it again")
    func evict() async throws {
        let folder = Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let site = MarkCacheTests.Site(["https://claude.ai/favicon.ico": Self.ico])
        let cache = MarkCache(folder: folder, download: site.download)
        _ = await cache.mark(for: .claude)
        cache.evict(.claude)
        #expect(!FileManager.default.fileExists(atPath: cache.icon(.claude).path))
        _ = await cache.mark(for: .claude)
        #expect(site.count == 2)
    }

    @Test("the request does not name the app, CFNetwork or the macOS version")
    func neutralUserAgent() throws {
        let agent = try #require(MarkCache.session.configuration.httpAdditionalHeaders?["User-Agent"] as? String)
        for word in ["SeatGauge", "Seat Gauge", "CFNetwork", "Darwin"] { #expect(!agent.contains(word)) }
    }
}
