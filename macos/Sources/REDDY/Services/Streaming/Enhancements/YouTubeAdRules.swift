import Foundation

/// What the ad skipping acts on, as plain data: names of fields to remove from the player's data, and page elements to hide or click.
/// It is data, never code: the file is checked name by name and cannot add anything that runs. The rules are bundled with the app
/// (`youtube-ads.json`); this version never downloads a newer file.
struct YouTubeAdRules: Codable, Equatable, Sendable {
    var version: Int
    /// Fields YouTube puts in a video's data that describe the ads to play. Removing them means the player has no ad to show.
    var stripKeys: [String]
    /// Page elements that are ads (banners, sponsored cards, empty ad slots).
    var hideSelectors: [String]
    /// Buttons that skip an ad that did start.
    var skipSelectors: [String]

    static let builtIn = YouTubeAdRules(
        version: 1,
        stripKeys: ["adPlacements", "playerAds", "adSlots", "adBreakHeartbeatParams"],
        hideSelectors: ["#masthead-ad", "#player-ads", ".ytp-ad-overlay-container", ".ytp-ad-text-overlay", ".video-ads.ytp-ad-module .ytp-ad-image-overlay",
                        "ytd-ad-slot-renderer", "ytd-display-ad-renderer", "ytd-promoted-sparkles-web-renderer", "ytd-promoted-video-renderer",
                        "ytd-in-feed-ad-layout-renderer", "ytd-banner-promo-renderer", "ytd-statement-banner-renderer", "#related ytd-ad-slot-renderer"],
        skipSelectors: [".ytp-skip-ad-button", ".ytp-ad-skip-button", ".ytp-ad-skip-button-modern", ".ytp-ad-skip-button-container button"])

    static let maxBytes = 64 * 1024
    private static let maxKeys = 40, maxSelectors = 120, maxLength = 200

    /// The bundled file when it is present and acceptable, otherwise the built-in copy (never a half-accepted file).
    static func bundled(_ bundle: Bundle = .main) -> YouTubeAdRules {
        guard let url = bundle.url(forResource: "youtube-ads", withExtension: "json"), let data = try? Data(contentsOf: url) else { return builtIn }
        return validated(data) ?? builtIn
    }

    /// A field name: letters, digits and underscores only.
    static func validKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.count <= 60, let first = key.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        return key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
    }

    /// A style selector: the characters a selector needs and nothing that could end the rule or start another (no braces, semicolons, escapes or functions).
    static func validSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count <= maxLength else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-#.[]=\"' :>,*~+^$|")
        guard selector.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let lowered = selector.lowercased()
        return !lowered.contains("url") && !lowered.contains("expression") && !lowered.contains("import")
    }

    /// The rules from a file's bytes, or nil when anything in it is not acceptable. A file is refused whole rather than partly used.
    static func validated(_ data: Data) -> YouTubeAdRules? {
        guard data.count <= maxBytes, let rules = try? JSONDecoder().decode(YouTubeAdRules.self, from: data),
              rules.version > 0, rules.version < 1_000_000,
              !rules.stripKeys.isEmpty, rules.stripKeys.count <= maxKeys, rules.stripKeys.allSatisfy(validKey),
              rules.hideSelectors.count <= maxSelectors, rules.hideSelectors.allSatisfy(validSelector),
              rules.skipSelectors.count <= maxSelectors, rules.skipSelectors.allSatisfy(validSelector) else { return nil }
        return rules
    }

    private func json<T: Encodable>(_ value: T) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "[]"
    }

    /// The page script. The rules are embedded as JSON data; the code around them is fixed. Runs in the page's own world at document start.
    var script: String {
        """
        (function () {
          var host = location.hostname.toLowerCase();
          if (host === 'accounts.youtube.com') return;          // Google's sign-in hand-back page: nothing of this runs there
          if (!/(^|\\.)youtube\\.com$/.test(host) && !/(^|\\.)youtube-nocookie\\.com$/.test(host)) return;
          var STRIP = \(json(stripKeys)), HIDE = \(json(hideSelectors)), SKIP = \(json(skipSelectors));
          // 1. The ad schedule is removed from the player's data before the player reads it, so there is no ad to play.
          function prune(o) {
            if (!o || typeof o !== 'object') return o;
            for (var i = 0; i < STRIP.length; i++) { if (STRIP[i] in o) { try { delete o[STRIP[i]]; } catch (e) {} } }
            return o;
          }
          function pruneAll(r) {
            if (!r || typeof r !== 'object') return r;
            if (Array.isArray(r)) { for (var i = 0; i < r.length && i < 6; i++) pruneAll(r[i]); return r; }
            prune(r); prune(r.playerResponse); if (r.response) prune(r.response.playerResponse);
            return r;
          }
          try {
            var parse = JSON.parse;
            JSON.parse = function () { var r = parse.apply(this, arguments); try { pruneAll(r); } catch (e) {} return r; };
            var rjson = Response.prototype.json;
            Response.prototype.json = function () { return rjson.apply(this, arguments).then(function (r) { try { pruneAll(r); } catch (e) {} return r; }); };
            var held;
            Object.defineProperty(window, 'ytInitialPlayerResponse', { configurable: true, get: function () { return held; }, set: function (v) { try { pruneAll(v); } catch (e) {} held = v; } });
          } catch (e) {}
          // 2. Page elements that are ads are hidden.
          function addStyle() { if (!HIDE.length) return; var s = document.createElement('style'); s.textContent = HIDE.join(',') + '{display:none!important}'; (document.head || document.documentElement).appendChild(s); }
          if (document.documentElement) addStyle(); else document.addEventListener('DOMContentLoaded', addStyle);
          // 3. An ad that got through is skipped when it can be, and otherwise muted and run to its end.
          var held2 = null;
          function tick() {
            var player = document.querySelector('#movie_player') || document.querySelector('.html5-video-player');
            var video = player && player.querySelector('video');
            var playing = !!(player && player.classList.contains('ad-showing'));
            if (!playing) {
              if (held2) { try { held2.video.muted = held2.muted; held2.video.playbackRate = held2.rate; } catch (e) {} held2 = null; }
              return;
            }
            var skip = SKIP.length ? document.querySelector(SKIP.join(',')) : null;
            if (skip) { try { skip.click(); } catch (e) {} }
            if (video && isFinite(video.duration) && video.duration > 0) {
              if (!held2) held2 = { video: video, muted: video.muted, rate: video.playbackRate || 1 };
              try { video.muted = true; video.playbackRate = 16; if (video.currentTime < video.duration - 0.1) video.currentTime = video.duration; } catch (e) {}
            }
          }
          setInterval(tick, 400);
          try { new MutationObserver(tick).observe(document.documentElement, { attributes: true, subtree: true, attributeFilter: ['class'] }); } catch (e) {}
        })();
        """
    }
}
