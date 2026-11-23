import Testing
import Foundation
@testable import REDDY

/// Plain HTTP stays allowed for the playlists people add themselves, but never for the services the apps talk to: every one of them must be an App Transport Security exception domain
/// that refuses insecure loads, on both the Mac and the iPhone.
@Suite("App Transport Security policy") struct ATSPolicyTests {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func ats(_ relative: String) throws -> (arbitrary: Bool, domains: [String: [String: Any]]) {
        let data = try Data(contentsOf: Self.repo.appendingPathComponent(relative))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let ats = try #require(plist["NSAppTransportSecurity"] as? [String: Any])
        return (ats["NSAllowsArbitraryLoads"] as? Bool ?? false, ats["NSExceptionDomains"] as? [String: [String: Any]] ?? [:])
    }

    /// Hosts of fixed https:// addresses written in the app's source: the services it contacts. Documentation links and examples are not services.
    private func serviceHosts() throws -> Set<String> {
        let notServices: Set<String> = ["example.com", "mpv.io", "ffmpeg.org", "nas.local", "host", "www.youtube.com", "youtube.com", "ai.google.dev", "www.apple.com", "creativecommons.org", "sparkle-project.org", "www.netflix.com", "netflix.com", "www.wikidata.org"]   // links opened in the browser (including licence texts in the legal screen), never fetched by the app
        var hosts = Set<String>()
        let e = try #require(FileManager.default.enumerator(at: Self.repo.appendingPathComponent("macos/Sources"), includingPropertiesForKeys: nil))
        let rx = try NSRegularExpression(pattern: #"https://([a-z0-9][a-z0-9.-]*\.[a-z]{2,})"#)
        for case let url as URL in e where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for m in rx.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { hosts.insert(String(text[r])) }
            }
        }
        return hosts.subtracting(notServices)
    }

    private func covered(_ host: String, by domains: Set<String>) -> Bool { domains.contains { host == $0 || host.hasSuffix("." + $0) } }

    @Test(arguments: ["macos/Configuration/Info.plist", "ios/StreamSetu/Info.plist"])
    func providersMayUseHTTPButEveryServiceIsHeldToHTTPS(plist: String) throws {
        let (arbitrary, domains) = try ats(plist)
        #expect(arbitrary, "plain HTTP stays possible for user-supplied provider addresses")
        for (domain, rules) in domains {
            #expect(rules["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == false, "\(domain) must refuse insecure loads")
            #expect(rules["NSIncludesSubdomains"] as? Bool == true, "\(domain) must include its subdomains")
        }
        let uncovered = try serviceHosts().filter { !covered($0, by: Set(domains.keys)) }.sorted()
        #expect(uncovered.isEmpty, "services without an HTTPS-only entry in \(plist): \(uncovered)")
    }

    @Test func bothPlatformsHoldTheSameServices() throws {
        let mac = Set(try ats("macos/Configuration/Info.plist").domains.keys), ios = Set(try ats("ios/StreamSetu/Info.plist").domains.keys)
        #expect(mac == ios, "difference: \(mac.symmetricDifference(ios).sorted())")
    }

    /// Every embedded service's address is held to HTTPS by its own exception entry, so a page of one can never be loaded over plain HTTP.
    @Test(arguments: ["macos/Configuration/Info.plist", "ios/StreamSetu/Info.plist"])
    func everyStreamingServiceHostIsHTTPSOnly(plist: String) throws {
        let (_, domains) = try ats(plist)
        for d in ProviderCatalog.all where d.id != .netflix {          // the original service keeps its existing arrangement
            let host = try #require(d.homeURL.host)
            let entry = domains.keys.first { host == $0 || host.hasSuffix("." + $0) }
            #expect(entry != nil, "\(d.id.rawValue): \(host) has no HTTPS-only entry in \(plist)")
            if let entry { #expect(domains[entry]?["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == false) }
        }
    }
}
