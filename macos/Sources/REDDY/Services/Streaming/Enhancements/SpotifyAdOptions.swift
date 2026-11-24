import WebKit

/// The two Spotify page options, kept apart from the YouTube ones. Both are best effort, off by default and need an agreement; nothing here reads
/// the page's data, the account, cookies or tokens, changes the playback speed or position, touches a licence or a media request, or sends anything.
///
/// 1. `SpotifyAdRules`: a declarative content rule list (compiled by the system, public WebKit API) applied only to the Spotify web view. It hides
///    elements that are ads or upgrade prompts and blocks a short, fixed list of ad endpoints. It never matches the service's audio, licence or CDN
///    hosts for music, so it cannot interfere with what carries the music itself.
/// 2. `SpotifyMuteScript`: a small page script that mutes the page's media output only while the player says an ad is playing.
enum SpotifyAdRules {
    /// Stable name of the compiled list in WebKit's rule store; bump the number when the rules change.
    static let identifier = "setu.spotify.ads.v1"
    /// Pages the rules apply to (WebKit's `if-domain`: the host and its subdomains).
    static let domain = "*open.spotify.com"

    /// Ad endpoints that carry no music: the ad decision service, its ad paths, the ad creative hosts and third-party ad servers. Patterns use the
    /// subset WebKit accepts (anchors, `.*`, character classes, escaped dots). Telemetry endpoints are NOT blocked: that is not an ad function.
    static let blockedURLPatterns: [String] = [
        #"^https://[^/]*spotify\.com/ad-logic/"#,
        #"^https://[^/]*spotify\.com/ads/"#,
        #"^https://adstudio-assets\.scdn\.co/"#,
        #"^https://[^/]*scdn\.co/mp3-ad/"#,
        #"^https://[^/]*amillionads\.com/"#,
        #"^https://[^/]*adxcel\.com/"#,
        #"^https://[^/]*2mdn\.net/"#,
        #"^https://adclick\.g\.doubleclick\.net/"#,
    ]

    /// Elements that are ads or upgrade prompts. `aria-label` and `data-*` markers are the sturdier ones; class names are desktop-derived and fragile.
    static let hiddenSelectors: [String] = [
        #"div[aria-label="Advertisement"]"#,
        #"a[data-context-item-type="ad"]"#,
        "#leaderboard-ad-element",
        #"[href*="adclick.g.doubleclick.net/"]"#,
        ".main-leaderboardComponent-container",
        ".main-topBar-UpgradeButton",
        #"[aria-label="Upgrade to Premium"]"#,
        #"button[data-menu-item="upgrade-account"]"#,
        ".upgrade-button",
    ]

    /// The rules as WebKit's JSON. Built from the two tables above with JSONSerialization, so the text is always valid JSON.
    static var json: String {
        var rules: [[String: Any]] = blockedURLPatterns.map { ["trigger": ["url-filter": $0, "if-domain": [domain]], "action": ["type": "block"]] }
        rules.append(["trigger": ["url-filter": ".*", "if-domain": [domain]], "action": ["type": "css-display-none", "selector": hiddenSelectors.joined(separator: ", ")]])
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Compiles (or finds) the list in `store`. nil on any failure: the option then simply does nothing.
    @MainActor static func list(in store: WKContentRuleListStore) async -> WKContentRuleList? {
        if let existing = try? await store.contentRuleList(forIdentifier: identifier) { return existing }
        return try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
    }
}

enum SpotifyMuteScript {
    static let host = "open.spotify.com"

    /// Runs only in the top frame of the service's own https page. The ad signals are the page's own markers (the title starting with "Advertisement",
    /// the now-playing widget naming an advertisement). While one shows, every audio and video element of the page is muted, and each one's earlier
    /// muted state is put back when the ad ends. Playback speed, position and volume are never touched. Five script errors switch it off for the page.
    static var source: String {
        """
        (function () {
          if (window.top !== window || location.protocol !== 'https:' || location.hostname.toLowerCase() !== '\(host)') return;
          var saved = [], errors = 0, timer = 0;
          function adPlaying() {
            var title = (document.title || '').trim().toLowerCase();
            if (title.indexOf('advertisement') === 0) return true;
            var widget = document.querySelector('[data-testid="now-playing-widget"]');
            if (!widget) return false;
            if ((widget.getAttribute('aria-label') || '').toLowerCase().indexOf('advertisement') !== -1) return true;
            return !!widget.querySelector('a[data-context-item-type="ad"]');
          }
          function mute() {
            var els = document.querySelectorAll('audio, video');
            for (var i = 0; i < els.length; i++) {
              var el = els[i], known = false;
              for (var j = 0; j < saved.length; j++) { if (saved[j].el === el) known = true; }
              if (!known) saved.push({ el: el, muted: el.muted });
              if (!el.muted) el.muted = true;
            }
          }
          function restore() {
            for (var i = 0; i < saved.length; i++) { try { saved[i].el.muted = saved[i].muted; } catch (e) {} }
            saved = [];
          }
          function tick() {
            try { if (adPlaying()) mute(); else if (saved.length) restore(); }
            catch (e) { if (++errors >= 5) { clearInterval(timer); try { restore(); } catch (e2) {} } }
          }
          timer = setInterval(tick, 250);
        })();
        """
    }
}
