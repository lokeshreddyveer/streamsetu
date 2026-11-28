import Foundation
import CryptoKit

// The login credential is one `Cookie` header string. These helpers read it, merge the values Google rotates, export it from a web view's
// cookie store, and derive the stable account key. Cookie values are never logged anywhere in this file.

/// One cookie as a web view's store reports it.
struct YTMWebCookie: Sendable, Equatable {
    var name: String
    var value: String
    var domain: String
}

struct YTMCookieJar: Equatable, Sendable {
    struct Pair: Equatable, Sendable { var name: String; var value: String }
    private(set) var pairs: [Pair] = []

    init() {}

    /// Reads `a=b; c=d`. Pairs without a name or without an `=` are dropped; a repeated name keeps its last value in its first place.
    init(header: String) {
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !kv[0].isEmpty else { continue }
            set(kv[0], kv[1])
        }
    }

    var header: String { pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") }
    var isEmpty: Bool { pairs.isEmpty }
    var names: [String] { pairs.map(\.name) }

    func value(of name: String) -> String? { pairs.first { $0.name == name }?.value }

    /// The long-lived login value: `SAPISID`, else `__Secure-3PAPISID`.
    var sapisid: String? {
        let v = value(of: "SAPISID") ?? value(of: "__Secure-3PAPISID")
        return (v?.isEmpty ?? true) ? nil : v
    }
    var isSignedIn: Bool { sapisid != nil }

    private mutating func set(_ name: String, _ value: String) {
        if let i = pairs.firstIndex(where: { $0.name == name }) { pairs[i].value = value } else { pairs.append(Pair(name: name, value: value)) }
    }

    /// Merges values YouTube rotated on a response. An empty name or empty value is ignored (a deletion must never drop the login cookie).
    /// Returns true when anything changed.
    @discardableResult
    mutating func merge(_ rotated: [(name: String, value: String)]) -> Bool {
        var changed = false
        for r in rotated {
            let name = r.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !r.value.isEmpty else { continue }
            if let i = pairs.firstIndex(where: { $0.name == name }) {
                if pairs[i].value != r.value { pairs[i].value = r.value; changed = true }
            } else {
                pairs.append(Pair(name: name, value: r.value)); changed = true
            }
        }
        return changed
    }

    /// Same cookies, any order.
    func sameSet(as other: YTMCookieJar) -> Bool {
        Set(pairs.map { $0.name + "\u{0}" + $0.value }) == Set(other.pairs.map { $0.name + "\u{0}" + $0.value })
    }

    // MARK: export from a web view

    /// True for `youtube.com` and its subdomains. A leading dot is ignored. This is a manual suffix match on purpose: on macOS the web view's
    /// own lookup by URL compares the domain for equality, so `.youtube.com` never matches `music.youtube.com`.
    static func isYouTubeDomain(_ domain: String) -> Bool {
        var d = domain.lowercased()
        if d.hasPrefix(".") { d.removeFirst() }
        return d == "youtube.com" || d.hasSuffix(".youtube.com")
    }

    /// Keeps youtube.com cookies only (Google's own are excluded), the most specific domain wins when a name repeats, names sorted.
    static func export(from cookies: [YTMWebCookie]) -> YTMCookieJar {
        var best: [String: YTMWebCookie] = [:]
        for c in cookies where isYouTubeDomain(c.domain) && !c.name.isEmpty {
            if let old = best[c.name], old.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).count >= c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).count { continue }
            best[c.name] = c
        }
        var jar = YTMCookieJar()
        for name in best.keys.sorted() { if let c = best[name] { jar.set(c.name, c.value) } }
        return jar
    }

    // MARK: account key

    /// A stable, non-reversible key for a Google account: derived from the long-lived login value, so rotating the short-lived cookies never changes it.
    static func accountKey(forLoginValue v: String) -> String {
        return "ga-" + MusicHash.sha256("streamsetu.ytm.account.v1|" + v, prefix: 16)
    }

    var accountKey: String? { sapisid.map(Self.accountKey(forLoginValue:)) }
}
