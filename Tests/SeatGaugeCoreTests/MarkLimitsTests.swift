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

    /// Bytes made only when asked for, counting how many were: a million in
    /// all, so a reader that buffers everything still ends.
    struct Endless: AsyncSequence {
        typealias Element = UInt8
        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() { lock.withLock { value += 1 } }
            var taken: Int { lock.withLock { value } }
        }
        let count = Count()
        struct AsyncIterator: AsyncIteratorProtocol {
            let count: Count
            mutating func next() async -> UInt8? {
                guard count.taken < 1_000_000 else { return nil }
                count.next()
                return 0x41
            }
        }
        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(count: count) }
    }

    @Test("Sol proof, criterion 8: an endless body is read only to one byte past the limit")
    func readingStopsAtTheLimit() async {
        let endless = Endless()
        #expect(await MarkCache.collect(endless, limit: 4096) == nil)
        #expect(endless.count.taken == 4097)
    }

    // MARK: - The real download, served by a stand-in protocol

    /// Serves fixed answers instead of the network: a redirect, an icon, or a
    /// body that keeps coming a chunk at a time until the task stops it.
    final class Stub: URLProtocol, @unchecked Sendable {
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var urls: [String] = []
            private var sentBytes = 0
            private var stops = 0
            func ask(_ url: String) { lock.withLock { urls.append(url) } }
            func sent(_ count: Int) { lock.withLock { sentBytes += count } }
            func stop() { lock.withLock { stops += 1 } }
            var asked: [String] { lock.withLock { urls } }
            var bytes: Int { lock.withLock { sentBytes } }
            var stopped: Int { lock.withLock { stops } }
        }
        nonisolated(unsafe) static var log = Log()
        private let halt = NSLock()
        private var halted = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url, let client else { return }
            Self.log.ask(url.absoluteString)
            switch url.path {
            case "/away", "/home":
                let target = URL(string: url.path == "/away" ? "https://tracker.example/i.ico"
                                                            : "https://assets-proxy.anthropic.com/i.ico")!
                let reply = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                            headerFields: ["Location": target.absoluteString])!
                client.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: reply)
                client.urlProtocolDidFinishLoading(self)
            case "/i.ico":
                let reply = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                client.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: MarkLimitsTests.ico)
                client.urlProtocolDidFinishLoading(self)
            default:
                let reply = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                client.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
                stream(client, left: 256)
            }
        }

        /// 16 KB every few milliseconds, 4 MB in all unless stopped first.
        private func stream(_ client: URLProtocolClient, left: Int) {
            guard left > 0, !halt.withLock({ halted }) else { return }
            client.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 16 << 10))
            Self.log.sent(16 << 10)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.002) { self.stream(client, left: left - 1) }
        }

        override func stopLoading() {
            halt.withLock { halted = true }
            Self.log.stop()
        }
    }

    static func stubbed() -> MarkCache.Download {
        Stub.log = Stub.Log()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return MarkCache.download(through: URLSession(configuration: configuration))
    }

    @Test("Sol proof, criterion 1: the real download stops receiving and cancels its task past the limit")
    func downloadStopsReceiving() async throws {
        let download = Self.stubbed()
        #expect(await download(URL(string: "https://claude.ai/endless")!, 64 << 10) == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(Stub.log.stopped >= 1)
        #expect(Stub.log.bytes < 1 << 20, "\(Stub.log.bytes) bytes were sent for a 64 KB limit")
    }

    @Test("Sol proof, criterion 2: a redirect off the provider's domains is refused, and one on them followed")
    func redirectsAreHeld() async {
        let download = Self.stubbed()
        #expect(await download(URL(string: "https://claude.ai/away")!, MarkCache.largestIcon) == nil)
        #expect(!Stub.log.asked.contains("https://tracker.example/i.ico"))
        #expect(await download(URL(string: "https://claude.ai/home")!, MarkCache.largestIcon) == Self.ico)
        #expect(Stub.log.asked.contains("https://assets-proxy.anthropic.com/i.ico"))
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
