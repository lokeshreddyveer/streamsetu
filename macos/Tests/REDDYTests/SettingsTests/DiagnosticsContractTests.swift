import Testing
import Foundation
@testable import REDDY

/// Stands in for the network: records the one request the uploader makes and answers 200. Nothing here reaches a real server.
private final class CaptureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var request: URLRequest?
    nonisolated(unsafe) static var body: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request = request
        if let data = request.httpBody { Self.body = data }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            Self.body = data
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The network contract of the problem report: exactly which fields leave the device, where they go, and what never does.
@Suite(.serialized) struct DiagnosticsContractTests {
    private func send(trigger: String = "manual", note: String = "") async throws -> (request: URLRequest, json: [String: Any]) {
        CaptureProtocol.request = nil; CaptureProtocol.body = nil
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CaptureProtocol.self]
        let uploader = DiagnosticsUploader(defaults: UserDefaults(suiteName: "diag-contract-\(UUID().uuidString)")!, session: URLSession(configuration: cfg))
        #expect(await uploader.send(trigger: trigger, note: note), "the stand-in server answered 200")
        let req = try #require(CaptureProtocol.request)
        let body = try #require(CaptureProtocol.body)
        return (req, try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any]))
    }

    @Test func theReportGoesToOneAddressAsOnePostWithNoAccountHeaders() async throws {
        let (req, _) = try await send()
        #expect(req.url == DiagnosticsUploader.endpoint)
        #expect(req.url?.scheme == "https" && req.url?.host?.hasSuffix(".supabase.co") == true)
        #expect(req.httpMethod == "POST")
        let headers = Set((req.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        #expect(headers.isDisjoint(with: ["authorization", "cookie", "x-api-key", "apikey"]), "no account, key or cookie travels with it")
    }

    @Test func exactlyTheseFieldsLeaveTheDevice() async throws {
        let (_, json) = try await send(trigger: "auto", note: "it fails")
        #expect(Set(json.keys) == ["install_id", "trigger", "platform", "app_version", "build", "os_version", "device", "note", "log"], "no field is added without this test changing")
        for key in ["install_id", "trigger", "platform", "app_version", "build", "os_version", "device", "note"] { #expect(json[key] is String, "\(key) is text") }
        #expect(json["log"] is [String], "the log is a list of lines")
        #expect(json["trigger"] as? String == "auto" && json["note"] as? String == "it fails")
        #expect(UUID(uuidString: json["install_id"] as? String ?? "") != nil, "the install number is a random UUID, nothing derived from the person or the device")
    }

    @Test func aLongNoteIsCutBeforeItLeaves() async throws {
        let (_, json) = try await send(note: String(repeating: "x", count: 5000))
        #expect((json["note"] as? String)?.count == 2000)
    }

    @Test func serverNamesLoginsAndStreamAddressesNeverLeaveInTheLog() async throws {
        PlaybackLog.shared.clear()
        PlaybackLog.shared.append("start live http://secret-provider.example:8080/live/myuser/mypass/12345.ts container=TS")
        PlaybackLog.shared.append("fetch https://secret-provider.example/get.php?username=myuser&password=hunter2&type=m3u")
        PlaybackLog.shared.append("relay from http://user:pw@secret-provider.example/path failed token=abc123")
        let (_, json) = try await send()
        let everything = ((json["log"] as? [String]) ?? []).joined(separator: "\n") + String(describing: json["note"] ?? "")
        for secret in ["secret-provider", "myuser", "mypass", "hunter2", "pw@", "abc123"] { #expect(!everything.contains(secret), "\(secret) must not leave the device") }
        #expect(everything.contains("server-1"), "the server is a numbered label")
        PlaybackLog.shared.clear()
    }

    @Test func theBodyIsTheSameTextThePersonCanReadInTheApp() async throws {
        // The feedback screens show `payload(...)`; what is sent must be exactly that, key for key.
        CaptureProtocol.request = nil; CaptureProtocol.body = nil
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [CaptureProtocol.self]
        let uploader = DiagnosticsUploader(defaults: UserDefaults(suiteName: "diag-contract-\(UUID().uuidString)")!, session: URLSession(configuration: cfg))
        let shown = uploader.payload(trigger: "manual", note: "n")
        #expect(await uploader.send(trigger: "manual", note: "n"))
        let body = try #require(CaptureProtocol.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(sent.keys) == Set(shown.keys))
        for k in shown.keys where k != "log" { #expect(String(describing: sent[k] ?? "") == String(describing: shown[k] ?? ""), "\(k)") }
    }
}
