import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Replaces the server names in a playback log with server-1, server-2… so a shared log says which servers behaved differently without saying
/// which provider the person uses. Addresses on this device (127.0.0.1, localhost) are left alone.
enum LogMasker {
    private static let patterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?<=://)[^/\s:?#@]+"#),
        try! NSRegularExpression(pattern: #"(?<=failingHost=)[^\s]+"#),
    ]

    static func mask(_ lines: [String]) -> [String] {
        var names: [String: String] = [:]
        func label(_ host: String) -> String {
            let h = host.lowercased()
            if h == "-" || h == "localhost" || h == "127.0.0.1" || h.hasPrefix("server-") { return host }
            if let known = names[h] { return known }
            let new = "server-\(names.count + 1)"
            names[h] = new
            return new
        }
        return lines.map { line in
            var out = line
            for re in patterns {
                let ns = out as NSString
                for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                    out = (out as NSString).replacingCharacters(in: m.range, with: label(ns.substring(with: m.range)))
                }
            }
            return out
        }
    }
}

/// Shares a playback log with the developer: after a stream fails for good (on unless the person switches it off, and the first launch tells
/// them so), or when they press Send My Log Now. What is sent is the playback log with server names masked, the app and system version and the device model.
/// Never a login, a playlist name, a title or a stream address. Sending runs at low priority and only after a failure, never during playback.
final class DiagnosticsUploader: @unchecked Sendable {
    static let shared = DiagnosticsUploader()

    static let endpoint = URL(string: "https://cpdhlqlpwmaqwgemiaod.supabase.co/functions/v1/submit-log")!
    private static let consentKey = "diagnostics.share"
    private static let installKey = "diagnostics.installID"
    private static let lastAutoKey = "diagnostics.lastAuto"
    private static let noticeKey = "diagnostics.noticeShown"
    /// At most one automatic report in this long, so a bad evening is one report and not fifty.
    static let autoInterval: TimeInterval = 3 * 3600

    private let defaults: UserDefaults
    private let session: URLSession

    init(defaults: UserDefaults = .standard, session: URLSession? = nil) {
        self.defaults = defaults
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15; cfg.timeoutIntervalForResource = 30; cfg.waitsForConnectivity = false
        self.session = session ?? URLSession(configuration: cfg)
    }

    /// Automatic sharing of the playback log after a failed stream. On unless the person turns it off (Settings > Send Feedback); the first
    /// launch tells them so. This device only, never synced.
    var isEnabled: Bool {
        get { defaults.object(forKey: Self.consentKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.consentKey) }
    }

    /// True once the first-launch notice has been shown, so it is shown once.
    var noticeShown: Bool {
        get { defaults.bool(forKey: Self.noticeKey) }
        set { defaults.set(newValue, forKey: Self.noticeKey) }
    }

    /// A random number made on this device the first time it is needed. It only groups one device's reports; it is not linked to any account.
    var installID: String {
        if let id = defaults.string(forKey: Self.installKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.installKey)
        return id
    }

    /// The exact body that would be sent. The feedback screens show it, so what is shared is what is read.
    func payload(trigger: String, note: String = "", logLines: Int = 300, now: Date = Date()) -> [String: Any] {
        let info = Bundle.main.infoDictionary
        return [
            "install_id": installID,
            "trigger": trigger,
            "platform": DiagnosticsService.platformName,
            "app_version": info?["CFBundleShortVersionString"] as? String ?? "dev",
            "build": info?["CFBundleVersion"] as? String ?? "0",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "device": Self.deviceModel,
            "note": String(note.prefix(2000)),
            "log": LogMasker.mask(PlaybackLog.shared.tail(lines: logLines).map { CredentialRedactor.redact($0) }),
        ]
    }

    /// Sends the log now. Returns whether the server accepted it.
    @discardableResult
    func send(trigger: String = "manual", note: String = "") async -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: payload(trigger: trigger, note: note)) else { return false }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Called when a stream has failed for good. Does nothing unless automatic sharing is on and nothing was sent in the last few hours.
    func playbackFailed(now: Date = Date()) {
        guard isEnabled else { return }
        let last = defaults.object(forKey: Self.lastAutoKey) as? Date
        guard Self.mayAutoSend(last: last, now: now) else { return }
        defaults.set(now, forKey: Self.lastAutoKey)
        Task.detached(priority: .utility) { [self] in await self.send(trigger: "auto") }
    }

    static func mayAutoSend(last: Date?, now: Date) -> Bool { last.map { now.timeIntervalSince($0) >= autoInterval } ?? true }

    static var deviceModel: String {
        var size = 0
        #if os(macOS)
        let name = "hw.model"
        #else
        let name = "hw.machine"
        #endif
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}
