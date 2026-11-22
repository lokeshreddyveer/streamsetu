import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Another player app on this device that can take over a stream.
struct ExternalPlayerApp: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// The bundle identifier on the Mac, or the link scheme on iPhone and iPad.
    let handle: String
}

/// Hands the stream that is playing to another app (VLC, IINA, Infuse and the like). Our own player is paused first, so a provider that allows one connection is not asked twice.
/// The address goes only to the app the person picks, and is never shown.
@MainActor
enum ExternalPlayer {
    #if os(macOS)
    private static let candidates = [("vlc", "VLC", "org.videolan.vlc"), ("iina", "IINA", "com.colliderli.iina"), ("infuse", "Infuse", "com.firecore.infuse")]

    static func installed() -> [ExternalPlayerApp] {
        candidates.compactMap { id, name, bundle in NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) == nil ? nil : ExternalPlayerApp(id: id, name: name, handle: bundle) }
    }

    @discardableResult static func open(_ url: URL, with app: ExternalPlayerApp) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.handle) else { return false }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
    #else
    private static let candidates = [("vlc", "VLC", "vlc-x-callback"), ("infuse", "Infuse", "infuse"), ("nplayer", "nPlayer", "nplayer-http"), ("outplayer", "OutPlayer", "outplayer")]

    /// The apps that registered their link scheme and that the Info.plist lists as ones to look for.
    static func installed() -> [ExternalPlayerApp] {
        candidates.compactMap { id, name, scheme in
            guard let probe = URL(string: scheme + "://"), UIApplication.shared.canOpenURL(probe) else { return nil }
            return ExternalPlayerApp(id: id, name: name, handle: scheme)
        }
    }

    /// The link that makes each app start playing the address.
    static func link(for app: ExternalPlayerApp, url: URL) -> URL? {
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        switch app.id {
        case "vlc": return URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)")
        case "infuse": return URL(string: "infuse://x-callback-url/play?url=\(encoded)")
        case "nplayer": return URL(string: "nplayer-" + url.absoluteString)
        case "outplayer": return URL(string: "outplayer://" + url.absoluteString)
        default: return nil
        }
    }

    @discardableResult static func open(_ url: URL, with app: ExternalPlayerApp) -> Bool {
        guard let target = link(for: app, url: url) else { return false }
        UIApplication.shared.open(target)
        return true
    }
    #endif

    /// Whether the address can be given to another app: a saved copy on this device can't.
    static func shareableURL(_ request: PlaybackRequest?) -> URL? {
        guard let url = request?.url, url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }
}
