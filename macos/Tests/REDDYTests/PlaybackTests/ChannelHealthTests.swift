import Testing
import Foundation
import Network
@testable import REDDY

/// A tiny local HTTP server, so the checker is tested against real connections without touching any provider.
final class LocalTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-server")
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            func reply(_ status: String, _ type: String, _ body: Data) {
                let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + body, completion: NWConnection.SendCompletion.contentProcessed { _ in conn.cancel() })
            }
            switch path {
            case "/ok": reply("200 OK", "video/mp2t", Data(repeating: 0x47, count: 4096))
            case "/hls": reply("200 OK", "application/vnd.apple.mpegurl", Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8))
            case "/html": reply("200 OK", "text/html", Data("<html>error</html>".utf8))
            case "/empty": reply("200 OK", "video/mp2t", Data())
            case "/limit": reply("458 Limit", "text/plain", Data("limit".utf8))
            case "/hang": break                                         // accepts the connection and never answers
            default: reply("404 Not Found", "text/plain", Data("no".utf8))
            }
        }
    }

    deinit { listener.cancel() }
}

@Suite("Channel health check") struct ChannelHealthTests {
    func channel(_ n: Int) -> Channel {
        var c = TestSupport.channel(PlaylistSource(name: "T", type: .m3uRemote, baseURL: "http://x"), "c\(n)", "Channel \(n)")
        c.streamRef = "/p\(n)"; return c
    }

    @Test func rulesSeparateWorkingSlowAndBrokenAnswers() {
        let ts = Data(repeating: 0x47, count: 100)
        #expect(ChannelHealthService.classify(statusOK: true, head: ts, contentType: "video/mp2t", ms: 400) == .ok(ms: 400))
        #expect(ChannelHealthService.classify(statusOK: true, head: ts, contentType: nil, ms: 5000) == .slow(ms: 5000))
        #expect(ChannelHealthService.classify(statusOK: true, head: Data(), contentType: nil, ms: 10).isDead)
        #expect(ChannelHealthService.classify(statusOK: true, head: Data("<!DOCTYPE html><body>blocked".utf8), contentType: nil, ms: 10).isDead)
        #expect(ChannelHealthService.classify(statusOK: true, head: ts, contentType: "text/html; charset=utf-8", ms: 10).isDead)
        #expect(ChannelHealthService.reason(forStatus: 458).contains("limit") && ChannelHealthService.reason(forStatus: 404).contains("404"))
    }

    @Test func realConnectionsAreClassifiedAndNoAddressLeaks() async throws {
        let server = try LocalTestServer()
        #expect(server.port != 0)
        let base = "http://127.0.0.1:\(server.port)"
        let routes = ["/p1": "/ok", "/p2": "/hls", "/p3": "/html", "/p4": "/missing", "/p5": "/empty", "/p6": "/limit"]
        let svc = ChannelHealthService(resolveURL: { URL(string: base + (routes[$0.streamRef] ?? "/missing"))! })
        let results = await svc.check((1...6).map(channel), concurrency: 2) { _, _ in }
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0.health) })
        #expect(results.count == 6)
        if case .ok = byName["Channel 1"] {} else { Issue.record("ok stream: \(String(describing: byName["Channel 1"]))") }
        if case .ok = byName["Channel 2"] {} else { Issue.record("hls playlist: \(String(describing: byName["Channel 2"]))") }
        #expect(byName["Channel 3"]?.isDead == true && byName["Channel 4"]?.isDead == true && byName["Channel 5"]?.isDead == true && byName["Channel 6"]?.isDead == true)
        for r in results { #expect(!r.health.label.contains("127.0.0.1") && !r.health.label.contains("http"), "no address in \(r.health.label)") }
    }

    @Test func aSilentStreamIsNeverCalledDead() async throws {
        let server = try LocalTestServer()
        let svc = ChannelHealthService(resolveURL: { _ in URL(string: "http://127.0.0.1:\(server.port)/hang")! }, timeouts: (0.4, 0.8))
        let started = Date()
        let r = await svc.check([channel(1)], concurrency: 1) { _, _ in }
        #expect(r.first?.health == .silent, "silence is not proof the channel is gone: \(String(describing: r.first?.health))")
        #expect(r.first?.health.isDead == false)
        #expect(Date().timeIntervalSince(started) >= 1.0, "it asked a second time with the longer wait")
    }

    @Test func anUnreachableHostIsReportedNotHung() async {
        let svc = ChannelHealthService(resolveURL: { _ in URL(string: "http://127.0.0.1:1/never")! })
        let started = Date()
        let r = await svc.check([channel(1)], concurrency: 1) { _, _ in }
        #expect(r.first?.health.isDead == true)
        #expect(Date().timeIntervalSince(started) < 12)
    }

    @Test func cancellingStopsTheRun() async throws {
        let server = try LocalTestServer()
        let svc = ChannelHealthService(resolveURL: { _ in URL(string: "http://127.0.0.1:\(server.port)/ok")! })
        let task = Task { await svc.check((1...200).map(channel), concurrency: 2) { _, _ in } }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let r = await task.value
        #expect(r.count < 200, "stopped early: \(r.count)")
    }
}
