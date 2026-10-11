import Foundation

/// A User-Agent and extra request headers chosen for one playlist. Some providers answer only certain players, or want a Referer;
/// this lets one playlist send what it needs without changing how every other one behaves.
struct SourceHeaders: Sendable, Hashable {
    var userAgent: String?
    var extra: [String: String] = [:]

    var isEmpty: Bool { userAgent == nil && extra.isEmpty }

    /// Headers that could carry a login. They are not accepted here, because these settings are stored in preferences, not the vault.
    static let blocked: Set<String> = ["authorization", "cookie", "proxy-authorization", "host", "content-length", "connection", "transfer-encoding"]

    static let presets: [(name: String, value: String)] = [
        ("VLC", "VLC/3.0.20 LibVLC/3.0.20"),
        ("Kodi", "Kodi/21.0 (Macintosh; Intel Mac OS X 14_0) App_Bitness/64 Version/21.0"),
        ("Safari on Mac", "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"),
        ("Chrome on Mac", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"),
        ("IPTV Smarters", "IPTVSmartersPro"),
        ("TiviMate", "TiviMate/5.1.1"),
    ]

    /// Parses "Name: value" lines. Returns the accepted headers and a message for each line that wasn't.
    static func parse(_ text: String) -> (headers: [String: String], problems: [String]) {
        var out: [String: String] = [:], problems: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let colon = line.firstIndex(of: ":") else { problems.append("“\(line.prefix(40))” has no colon (use Name: value)"); continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let validName = !name.isEmpty && name.unicodeScalars.allSatisfy { ($0.properties.isAlphabetic && $0.isASCII) || $0.properties.numericType != nil && $0.isASCII || "-_".unicodeScalars.contains($0) }
            guard validName else { problems.append("“\(name.prefix(30))” isn't a valid header name"); continue }
            guard !blocked.contains(name.lowercased()) else { problems.append("“\(name)” can't be set here"); continue }
            guard !value.isEmpty, !value.contains("\r"), !value.contains("\n"), value.count <= 500 else { problems.append("“\(name)” has no usable value"); continue }
            if name.lowercased() == "user-agent" { continue }          // the User-Agent has its own field
            out[name] = value
        }
        return (out, problems)
    }

    /// Adds the headers to a request. The User-Agent replaces `defaultUserAgent` only when one was chosen.
    func apply(to request: inout URLRequest) {
        if let userAgent, !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        for (k, v) in extra { request.setValue(v, forHTTPHeaderField: k) }
    }

    /// Everything as one dictionary, for players that take headers as a set.
    var fields: [String: String] {
        var f = extra
        if let userAgent, !userAgent.isEmpty { f["User-Agent"] = userAgent }
        return f
    }

    var text: String { extra.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n") }
}

/// Where each playlist's headers are kept (preferences; thread-safe).
final class SourceHeadersStore: @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ id: UUID, _ part: String) -> String { "playlist.\(id.uuidString.lowercased()).\(part)" }

    func headers(for id: UUID) -> SourceHeaders {
        let ua = defaults.string(forKey: key(id, "useragent"))
        let extra = defaults.string(forKey: key(id, "headers")).map { SourceHeaders.parse($0).headers } ?? [:]
        return SourceHeaders(userAgent: (ua?.isEmpty ?? true) ? nil : ua, extra: extra)
    }

    func set(userAgent: String?, extraText: String, for id: UUID) {
        if let ua = userAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !ua.isEmpty, !ua.contains("\n") { defaults.set(String(ua.prefix(300)), forKey: key(id, "useragent")) }
        else { defaults.removeObject(forKey: key(id, "useragent")) }
        let accepted = SourceHeaders.parse(extraText).headers
        if accepted.isEmpty { defaults.removeObject(forKey: key(id, "headers")) }
        else { defaults.set(SourceHeaders(userAgent: nil, extra: accepted).text, forKey: key(id, "headers")) }
    }

    func clear(for id: UUID) { defaults.removeObject(forKey: key(id, "useragent")); defaults.removeObject(forKey: key(id, "headers")) }
}
