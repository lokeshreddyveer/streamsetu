import Foundation

// Server-driven adaptive streaming: instead of a media address per format, the player response carries one streaming address and a
// configuration blob; the client POSTs a small request saying what it wants and what it already has, and the server answers with a UMP body
// holding control parts and media segments. This file writes that request and reads what comes back. It does not decide whether the answer is
// worth playing: the stream-protection status says so, and without an accepted proof-of-origin token the server cuts delivery after a short
// start (a few seconds of audio).

enum YouTubeSabr {
    struct Format: Sendable, Equatable {
        var itag: Int
        var lastModified: Int64?
        var xtags: String?
    }

    struct ClientInfo: Sendable, Equatable {
        /// The numeric client id of the player response the address came from (mobile web is 2).
        var clientID: Int
        var clientVersion: String
        var hl = "en"
        var gl = "US"
    }

    struct Request: Sendable {
        var client: ClientInfo
        /// The base64url `videoPlaybackUstreamerConfig` from the player response.
        var ustreamerConfig: String
        var audio: Format
        var playerTimeMs = 0
        var poToken: [UInt8]?
        var playbackCookie: [UInt8]?
    }

    static func formatMessage(_ f: Format) -> [UInt8] {
        var m = YTMWire.field(1, varint: UInt64(f.itag))
        if let l = f.lastModified, l > 0 { m += YTMWire.field(2, varint: UInt64(l)) }
        if let x = f.xtags, !x.isEmpty { m += YTMWire.field(3, string: x) }
        return m
    }

    /// The request body (field numbers as the public documentation lists them). Audio only, normal speed.
    static func body(_ r: Request) -> [UInt8]? {
        guard let config = YouTubeAttestation.decodeWebsafe(r.ustreamerConfig) else { return nil }
        let state = YTMWire.field(28, varint: UInt64(r.playerTimeMs)) + YTMWire.field(34, varint: 1) + YTMWire.field(35, float: 1.0) + YTMWire.field(40, varint: 1)
        let info = YTMWire.field(1, string: r.client.hl) + YTMWire.field(2, string: r.client.gl)
            + YTMWire.field(16, varint: UInt64(r.client.clientID)) + YTMWire.field(17, string: r.client.clientVersion)
        var ctx = YTMWire.field(1, bytes: info)
        if let t = r.poToken { ctx += YTMWire.field(2, bytes: t) }
        if let c = r.playbackCookie { ctx += YTMWire.field(3, bytes: c) }
        var out = YTMWire.field(1, bytes: state)
        if r.playerTimeMs > 0 { out += YTMWire.field(4, varint: UInt64(r.playerTimeMs)) }
        out += YTMWire.field(5, bytes: config) + YTMWire.field(16, bytes: formatMessage(r.audio)) + YTMWire.field(19, bytes: ctx)
        return out
    }

    /// The address for one request: marks it as a long-running request, adds the client playback nonce and the running request number.
    static func requestURL(base: String, cpn: String, number: Int) -> URL? {
        guard var c = URLComponents(string: base), c.scheme == "https", let host = c.host, host.hasSuffix(".googlevideo.com") else { return nil }
        var items = (c.queryItems ?? []).filter { !["alr", "cpn", "rn"].contains($0.name) }
        items += [URLQueryItem(name: "alr", value: "yes"), URLQueryItem(name: "cpn", value: cpn), URLQueryItem(name: "rn", value: String(number))]
        c.queryItems = items
        return c.url
    }

    // MARK: answer

    struct Answer: Sendable, Equatable {
        /// Stream-protection status: 1 fine, 2 a token is required (short start only), 3 playback cannot continue.
        var protection: Int?
        var redirect: String?
        var playbackCookie: [UInt8]?
        var backoffMs: Int?
        var errorType: String?
        var reloadRequested = false
        var mediaBytes = 0
        var segments = 0
        var complete = true
        var needsToken: Bool { (protection ?? 1) >= 2 }
    }

    static func read(_ body: [UInt8]) -> Answer {
        let (parts, complete) = YouTubeUMP.parse(body)
        var a = Answer(complete: complete)
        for p in parts {
            switch p.type {
            case YouTubeUMP.PartType.streamProtectionStatus:
                if let f = YTMWire.parse(p.payload), case .varint(let v)? = f.first(where: { $0.number == 1 })?.value { a.protection = Int(v) }
            case YouTubeUMP.PartType.redirect:
                if let f = YTMWire.parse(p.payload), case .bytes(let b)? = f.first(where: { $0.number == 1 })?.value,
                   let s = String(bytes: b, encoding: .utf8), let u = URL(string: s), u.scheme == "https", u.host?.hasSuffix(".googlevideo.com") == true { a.redirect = s }
            case YouTubeUMP.PartType.nextRequestPolicy:
                if let f = YTMWire.parse(p.payload) {
                    if case .varint(let v)? = f.first(where: { $0.number == 4 })?.value { a.backoffMs = Int(v) }
                    if case .bytes(let b)? = f.first(where: { $0.number == 7 })?.value { a.playbackCookie = b }
                }
            case YouTubeUMP.PartType.error:
                if let f = YTMWire.parse(p.payload), case .bytes(let b)? = f.first(where: { $0.number == 1 })?.value { a.errorType = String(bytes: b, encoding: .utf8) }
            case YouTubeUMP.PartType.reloadPlayerResponse: a.reloadRequested = true
            case YouTubeUMP.PartType.media: a.mediaBytes += max(0, p.payload.count - 1)
            case YouTubeUMP.PartType.mediaEnd: a.segments += 1
            default: break
            }
        }
        return a
    }
}
