import Foundation

// Pure pieces of the proof-of-origin flow: the public constants of the attestation service, request bodies, and parsing of its answers.
// Nothing here runs a script; the page that does is in YouTubePoTokenProvider.

enum YouTubeAttestation {
    /// Public identifiers of the web attestation service, the same ones the site's own player and the open documentation use.
    static let requestKey = "O43z0dpjhgX20SCx4KAo"
    static let apiKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    static let generateURL = "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT"
    static let challengeURLs = ["https://www.youtube.com/youtubei/v1/att/get?prettyPrint=false", "https://music.youtube.com/youtubei/v1/att/get?prettyPrint=false"]

    struct Challenge: Sendable, Equatable {
        var interpreterURL: String
        var program: String
        var globalName: String
    }

    struct Integrity: Sendable, Equatable {
        var token: String
        var ttl: TimeInterval
        var refreshThreshold: TimeInterval
    }

    /// Body of the challenge request. The context carries the visitor id the token will be bound to.
    static func challengeBody(visitorData: String) -> Data {
        let ctx: [String: Any] = ["client": ["clientName": "WEB", "clientVersion": "2.20260708.00.00", "hl": "en", "gl": "US", "visitorData": visitorData]]
        return (try? JSONSerialization.data(withJSONObject: ["context": ctx, "engagementType": "ENGAGEMENT_TYPE_UNBOUND"])) ?? Data()
    }

    /// Reads `bgChallenge` out of the challenge answer. Only an https address on a Google host is accepted for the interpreter script.
    static func parseChallenge(_ data: Data) -> Challenge? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let bg = root["bgChallenge"] as? [String: Any],
              let program = bg["program"] as? String, !program.isEmpty, let name = bg["globalName"] as? String,
              name.range(of: "^[A-Za-z_$][A-Za-z0-9_$]{0,40}$", options: .regularExpression) != nil else { return nil }
        var raw: String?
        if let w = (bg["interpreterUrl"] as? [String: Any])?["privateDoNotAccessOrElseTrustedResourceUrlWrappedValue"] as? String { raw = w }
        else if let s = bg["interpreterUrl"] as? String { raw = s }
        guard var url = raw, !url.isEmpty else { return nil }
        if url.hasPrefix("//") { url = "https:" + url }
        guard let u = URL(string: url), u.scheme == "https", let host = u.host?.lowercased(), host == "google.com" || host.hasSuffix(".google.com") || host.hasSuffix(".gstatic.com") else { return nil }
        return Challenge(interpreterURL: url, program: program, globalName: name)
    }

    /// `[requestKey, botguardResponse]` as the service expects it.
    static func generateBody(botguardResponse: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: [requestKey, botguardResponse])) ?? Data()
    }

    /// `[integrityToken, ttlSeconds, refreshThresholdSeconds, fallback]`.
    static func parseIntegrity(_ data: Data) -> Integrity? {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any], let token = arr.first as? String, !token.isEmpty else { return nil }
        func num(_ i: Int, _ d: Double) -> Double { i < arr.count ? ((arr[i] as? Double) ?? (arr[i] as? Int).map(Double.init) ?? d) : d }
        return Integrity(token: token, ttl: max(60, num(1, 3600)), refreshThreshold: num(2, 600))
    }

    /// The visitor id as the attestation binds it: percent-escapes undone.
    static func visitorBinding(_ visitorData: String) -> String { visitorData.removingPercentEncoding ?? visitorData }

    /// URL-safe base64 without padding, the form tokens travel in.
    static func websafe(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Reverse of `websafe`; also accepts the standard alphabet and missing padding.
    static func decodeWebsafe(_ s: String) -> [UInt8]? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).map([UInt8].init)
    }
}
