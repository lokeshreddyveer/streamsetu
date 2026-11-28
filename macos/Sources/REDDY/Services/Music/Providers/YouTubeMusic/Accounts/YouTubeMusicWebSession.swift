import Foundation
import WebKit

// The web view that holds the Google session. It is persistent on purpose (so signing in again is one click and a silent refresh needs no
// password) and dedicated: it shares nothing with the rest of the app's web views. It has NO bridge into the app (no script message
// handler), so nothing that runs inside a page can call back into our code. It is read only through its cookie store.

@MainActor
enum YTMWebSession {
    static let storeIdentifier = UUID(uuidString: "5C7E0C1A-2B3D-4F6A-9A41-7D2E8B90C6F3") ?? UUID()
    static let dataStore: WKWebsiteDataStore = WKWebsiteDataStore(forIdentifier: storeIdentifier)

    /// Google blocks embedded browsers it does not recognise; a current desktop Safari string avoids that. This is the fragile knob.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"

    static let signInURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://music.youtube.com/")
    static let addAccountURL = URL(string: "https://accounts.google.com/AddSession?service=youtube&continue=https://music.youtube.com/")
    static let musicURL = URL(string: "https://music.youtube.com/")

    static func makeConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        return c
    }

    static func makeWebView(frame: CGRect = CGRect(x: 0, y: 0, width: 480, height: 720)) -> WKWebView {
        let w = WKWebView(frame: frame, configuration: makeConfiguration())
        w.customUserAgent = userAgent
        return w
    }

    /// Every cookie in the store. The store is read whole and filtered by hand: a lookup by URL compares the domain for equality on macOS,
    /// so `.youtube.com` would never match `music.youtube.com`.
    static func allCookies() async -> [YTMWebCookie] {
        await dataStore.httpCookieStore.allCookies().map { YTMWebCookie(name: $0.name, value: $0.value, domain: $0.domain) }
    }

    static func currentJar() async -> YTMCookieJar { YTMCookieJar.export(from: await allCookies()) }

    /// Reads the store up to `tries` times, `interval` apart, until the jar holds a login cookie.
    static func waitForLoginJar(tries: Int = 6, interval: TimeInterval = 0.5) async -> YTMCookieJar? {
        for i in 0..<tries {
            let jar = await currentJar()
            if jar.isSignedIn { return jar }
            if i < tries - 1 { try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
        }
        return nil
    }

    private static func isGoogleOrYouTube(_ domain: String) -> Bool {
        var d = domain.lowercased()
        if d.hasPrefix(".") { d.removeFirst() }
        return d == "google.com" || d.hasSuffix(".google.com") || d == "youtube.com" || d.hasSuffix(".youtube.com")
    }

    /// Deletes the google.com and youtube.com cookies so the next sign-in is a different account. False when any of them survived.
    static func clearGoogleSession() async -> Bool {
        let store = dataStore.httpCookieStore
        for c in await store.allCookies() where isGoogleOrYouTube(c.domain) { await store.deleteCookie(c) }
        return await store.allCookies().allSatisfy { !isGoogleOrYouTube($0.domain) }
    }
}

/// Re-mints a rejected session. It loads music.youtube.com in a hidden web view (1024 by 768, never shown, never focused) and takes the
/// rotated cookies, but only when the web view's Google session is the account being healed.
@MainActor
final class YouTubeSessionRefresher: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// The new cookie header, or nil when nothing usable appeared. Never changes any state itself.
    func refresh(expectedAccountKey: String, current: YTMCookieJar?, loadTimeout: TimeInterval = 45) async -> String? {
        guard let url = YTMWebSession.musicURL else { return nil }
        let w = YTMWebSession.makeWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        w.navigationDelegate = self
        webView = w
        defer { w.stopLoading(); w.navigationDelegate = nil; webView = nil }
        let loaded = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            continuation = c
            w.load(URLRequest(url: url))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(loadTimeout * 1_000_000_000))
                self?.finish(false)
            }
        }
        guard loaded else { return nil }
        for i in 0..<8 {
            // The live jar is read on every pass: the web view's session may belong to another account by now.
            let jar = await YTMWebSession.currentJar()
            if jar.isSignedIn, jar.accountKey != expectedAccountKey { return nil }
            if YTMHealRules.isUsable(webJar: jar, expectedAccountKey: expectedAccountKey, currentJar: current) { return jar.header }
            if i < 7 { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        return nil
    }

    private func finish(_ ok: Bool) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: ok)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
}
