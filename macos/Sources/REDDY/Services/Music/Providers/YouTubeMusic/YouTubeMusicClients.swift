import Foundation
import CryptoKit

// The client identities YouTube Music's own apps use, the request context built from them, and the session seam that lets a signed-in
// account be plugged in later. Version strings rotate every few months, so they are data (`YTMClientTable`) and can be replaced from an
// override file without touching code. Older Android VR and iPhone app identities are deliberately absent: their stream URLs no longer
// serve whole tracks.

enum YTMClientKey: String, Sendable, CaseIterable {
    case webRemix = "WEB_REMIX", web = "WEB", webCreator = "WEB_CREATOR", tvhtml5 = "TVHTML5", tvhtml5Simply = "TVHTML5_SIMPLY"
    case visionOS = "VISIONOS", iosMusic = "IOS_MUSIC"
    /// Guest fallbacks for videos the main clients refuse. Their addresses are accepted only after the stream probe proves they serve a whole song.
    case ios = "IOS", androidVR = "ANDROID_VR"
    /// The creator-studio iPhone app: direct audio addresses that serve whole files, with or without a visitor id.
    case iosProducer = "IOS_PRODUCER"
    /// Smart-TV web app: answers without a PO token, but with ciphered addresses that need the player script.
    case tvSamsung = "TV_SAMSUNG"
}

struct YTMClientIdentity: Sendable, Equatable, Codable {
    var clientName: String
    var clientVersion: String
    var clientID: String
    var userAgent: String
    var osName: String? = nil
    var osVersion: String? = nil
    var deviceMake: String? = nil
    var deviceModel: String? = nil
    var androidSdkVersion: Int? = nil
    var loginSupported = false
    var loginRequired = false
    var useSignatureTimestamp = false
    var useWebPoTokens = false
    var isEmbedded = false

    /// Clients whose stream URLs need the `n` transform when they point at YouTube's own hosts.
    var needsWebTransforms: Bool {
        ["WEB", "WEB_REMIX", "WEB_CREATOR", "TVHTML5"].contains(clientName) || useWebPoTokens
    }
}

enum YTMClientTable {
    private static let firefox = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"
    private static let cobalt = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"
    private static let safariNew = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let tizen = "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1"
    private static let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static let builtIn: [YTMClientKey: YTMClientIdentity] = [
        .webRemix: YTMClientIdentity(clientName: "WEB_REMIX", clientVersion: "1.20260213.01.00", clientID: "67", userAgent: firefox,
                                     loginSupported: true, useSignatureTimestamp: true, useWebPoTokens: true),
        .web: YTMClientIdentity(clientName: "WEB", clientVersion: "2.20261101.01.00", clientID: "1", userAgent: firefox),
        .webCreator: YTMClientIdentity(clientName: "WEB_CREATOR", clientVersion: "1.20220726.00.00", clientID: "62", userAgent: firefox,
                                       loginSupported: true, loginRequired: true, useSignatureTimestamp: true, useWebPoTokens: true),
        .tvhtml5: YTMClientIdentity(clientName: "TVHTML5", clientVersion: "7.20260707.07.00", clientID: "7", userAgent: cobalt,
                                    loginSupported: true, useSignatureTimestamp: true),
        .tvhtml5Simply: YTMClientIdentity(clientName: "TVHTML5_SIMPLY", clientVersion: "1.0", clientID: "75", userAgent: cobalt,
                                          useSignatureTimestamp: true, useWebPoTokens: true),
        .visionOS: YTMClientIdentity(clientName: "VISIONOS", clientVersion: "1.02", clientID: "101", userAgent: safariNew,
                                     osName: "visionOS", osVersion: "26.5.23O471", deviceMake: "Apple", deviceModel: "RealityDevice17,1"),
        .iosProducer: YTMClientIdentity(clientName: "IOS_PRODUCER", clientVersion: "0.147.945", clientID: "92",
                                        userAgent: "com.google.ios.youtubeproducer/0.147.945 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
                                        osName: "iPhone", osVersion: "18.3.2.22D82", deviceMake: "Apple", deviceModel: "iPhone16,2"),
        .tvSamsung: YTMClientIdentity(clientName: "TVHTML5", clientVersion: "5.20260707", clientID: "7", userAgent: tizen,
                                      osName: "Tizen", osVersion: "2.4.0", deviceMake: "Samsung", deviceModel: "UKS9800",
                                      loginSupported: true, useSignatureTimestamp: true),
        .iosMusic: YTMClientIdentity(clientName: "IOS_MUSIC", clientVersion: "7.01.05", clientID: "26",
                                     userAgent: "com.google.ios.youtubemusic/7.01.05 (iPhone16,2; U; CPU iOS 18_2 like Mac OS X;)",
                                     osName: "iOS", osVersion: "18.2.22C152", deviceMake: "Apple", deviceModel: "iPhone16,2"),
        .ios: YTMClientIdentity(clientName: "IOS", clientVersion: "20.10.4", clientID: "5",
                                userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
                                osName: "iPhone", osVersion: "18.3.2.22D82", deviceMake: "Apple", deviceModel: "iPhone16,2"),
        .androidVR: YTMClientIdentity(clientName: "ANDROID_VR", clientVersion: "1.65.10", clientID: "28",
                                      userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                                      osName: "Android", osVersion: "12L", deviceMake: "Oculus", deviceModel: "Quest 3", androidSdkVersion: 32)
    ]

    /// Built-in table with entries from an override file (a JSON object of registry key to identity) laid on top. A bad file changes nothing.
    static func load(overrideFile: URL?) -> [YTMClientKey: YTMClientIdentity] {
        var table = builtIn
        guard let url = overrideFile, let data = try? Data(contentsOf: url),
              let over = try? JSONDecoder().decode([String: YTMClientIdentity].self, from: data) else { return table }
        for (k, v) in over { if let key = YTMClientKey(rawValue: k), !v.clientVersion.isEmpty, !v.userAgent.isEmpty { table[key] = v } }
        return table
    }
}

struct YTMLocale: Sendable, Equatable {
    var hl: String
    var gl: String
    init(hl: String = "en", gl: String = "US") {
        self.hl = YTMLocale.valid(hl) ? hl : "en"
        self.gl = gl
    }
    /// A language is accepted only when it is non-empty and made of ASCII letters, digits and dashes.
    static func valid(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }
    var acceptLanguage: String { hl == "en" ? "en-US,en;q=0.9" : "\(hl),en;q=0.5" }
}

// MARK: session seam

struct YouTubeMusicSessionSnapshot: Sendable, Equatable {
    var cookieHeader: String? = nil
    var visitorData: String? = nil
    /// The selected delegated identity (brand channel). Sent only together with a login cookie.
    var dataSyncID: String? = nil
    var pageID: String? = nil

    var sapisid: String? {
        guard let cookieHeader else { return nil }
        let pairs = cookieHeader.split(separator: ";").compactMap { part -> (String, String)? in
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        }
        return pairs.first { $0.0 == "SAPISID" }?.1 ?? pairs.first { $0.0 == "__Secure-3PAPISID" }?.1
    }
    var isSignedIn: Bool { sapisid != nil }
}

/// What an account layer plugs in. The default guest session has no cookie. All calls may be made from any thread.
protocol YouTubeMusicSession: Sendable {
    func snapshot() async -> YouTubeMusicSessionSnapshot
    /// Remembers an anonymous (or login-bound) visitor id so later requests reuse it.
    func updateVisitorData(_ value: String) async
    /// Cookie values YouTube rotated on a response. The session merges them into its stored jar.
    func merge(rotatedCookies: [(name: String, value: String)]) async
}

final class GuestYouTubeMusicSession: YouTubeMusicSession, @unchecked Sendable {
    private let lock = NSLock()
    private var visitor: String?
    init(visitorData: String? = nil) { visitor = visitorData }
    func snapshot() async -> YouTubeMusicSessionSnapshot { lock.withLock { YouTubeMusicSessionSnapshot(visitorData: visitor) } }
    func updateVisitorData(_ value: String) async { lock.withLock { visitor = value } }
    func merge(rotatedCookies: [(name: String, value: String)]) async {}
}

// MARK: context and headers

enum YTMRequestMode: Sendable { case normal, anonymous }

enum YTMContext {
    /// The `context` object sent in every body. `onBehalfOfUser` goes out only for login-capable clients that carry a login cookie.
    static func build(client c: YTMClientIdentity, locale: YTMLocale, session: YouTubeMusicSessionSnapshot, mode: YTMRequestMode = .normal,
                      embedVideoID: String? = nil, identityOverride: String? = nil) -> [String: Any] {
        var client: [String: Any] = ["clientName": c.clientName, "clientVersion": c.clientVersion, "gl": locale.gl, "hl": locale.hl]
        if let v = c.osName { client["osName"] = v }
        if let v = c.osVersion { client["osVersion"] = v }
        if let v = c.deviceMake { client["deviceMake"] = v }
        if let v = c.deviceModel { client["deviceModel"] = v }
        if let v = c.androidSdkVersion { client["androidSdkVersion"] = v }
        if let v = session.visitorData, !v.isEmpty { client["visitorData"] = v }
        var ctx: [String: Any] = [
            "client": client,
            "request": ["internalExperimentFlags": [Any](), "useSsl": true] as [String: Any]
        ]
        var user: [String: Any] = ["lockedSafetyMode": false]
        let withLogin = mode == .normal && c.loginSupported && session.isSignedIn
        if withLogin, let id = identityOverride ?? session.dataSyncID, !id.isEmpty { user["onBehalfOfUser"] = id }
        ctx["user"] = user
        if c.isEmbedded, let id = embedVideoID { ctx["thirdParty"] = ["embedUrl": "https://www.youtube.com/watch?v=\(id)"] }
        return ctx
    }

    static func headers(client c: YTMClientIdentity, locale: YTMLocale, session: YouTubeMusicSessionSnapshot, mode: YTMRequestMode = .normal,
                        now: Date = Date()) -> [String: String] {
        var h: [String: String] = [
            "content-type": "application/json", "accept": "application/json", "x-goog-api-format-version": "1",
            "x-youtube-client-name": c.clientID, "x-youtube-client-version": c.clientVersion,
            "x-origin": "https://music.youtube.com", "referer": "https://music.youtube.com/",
            "user-agent": c.userAgent, "accept-language": locale.acceptLanguage
        ]
        if let v = session.visitorData, !v.isEmpty { h["x-goog-visitor-id"] = v }
        if mode == .normal, c.loginSupported, let cookie = session.cookieHeader, let sapisid = session.sapisid {
            h["cookie"] = cookie
            h["authorization"] = sapisidHash(sapisid: sapisid, now: now)
        }
        return h
    }

    /// `SAPISIDHASH <epoch>_<sha1 hex of "<epoch> <sapisid> https://music.youtube.com">`.
    static func sapisidHash(sapisid: String, now: Date) -> String {
        let epoch = Int(now.timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(epoch) \(sapisid) https://music.youtube.com".utf8))
        return "SAPISIDHASH \(epoch)_" + MusicHash.hex(digest)
    }
}
