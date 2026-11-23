import Foundation

/// The sponsor skipping page script. It runs in its OWN isolated world (it only needs the page's elements, not the page's variables), so the
/// site cannot see or change it. It asks the app for the segments of the video being watched through ONE message handler that receives the
/// 11-character video identifier and nothing else; the app answers with checked numbers. Events, not polling: it listens to the video's own
/// play, pause, seek and speed events and sets one timer for the moment the next segment starts. It does nothing on a protected (DRM) video,
/// while an ad is showing, or for segments made for another video.
enum SponsorSkipScript {
    static let handlerName = "sponsorSkip"
    static let worldName = "StreamSetuSponsorSkip"
    /// What the page object answers, for tests.
    static let stats = "return window.__ssSponsor ? window.__ssSponsor.stats() : null;"

    static func source(skippedLabel: String, undoLabel: String) -> String {
        let config: [String: String] = ["skipped": skippedLabel, "undo": undoLabel]
        guard let data = try? JSONSerialization.data(withJSONObject: config), let json = String(data: data, encoding: .utf8) else { return "" }
        return template.replacingOccurrences(of: "__CONFIG__", with: json)
    }

    private static let template = #"""
    (function () {
      var cfg = __CONFIG__;
      var host = location.hostname.toLowerCase().replace(/^(www|m)\./, '');
      if (host !== 'youtube.com') return;
      var data = { id: null, segments: [] }, video = null, bound = null, timer = null, tries = 0, asked = null;
      var stats = { skipped: 0, seconds: 0 }, released = {}, ourSeek = false, lastSkip = null, box = null, hideTimer = null;

      function currentID() {
        var m = location.pathname.match(/^\/(?:shorts|embed|live)\/([A-Za-z0-9_-]{11})/);
        if (m) return m[1];
        var v = new URLSearchParams(location.search).get('v');
        return v && /^[A-Za-z0-9_-]{11}$/.test(v) ? v : null;
      }
      function findVideo() {
        return document.querySelector('#movie_player video.html5-main-video') || document.querySelector('#movie_player video') ||
               document.querySelector('video.html5-main-video') || document.querySelector('video');
      }
      function adShowing() { var p = document.querySelector('#movie_player') || document.querySelector('.html5-video-player'); return !!(p && p.classList.contains('ad-showing')); }
      function eligible() {
        if (!video || data.id !== currentID()) return false;
        if (video.mediaKeys) return false;
        if (adShowing()) return false;
        return isFinite(video.duration) && video.duration > 0;
      }
      function inside(t) {
        for (var i = 0; i < data.segments.length; i++) { var s = data.segments[i]; if (t >= s.start - 0.05 && t < s.end - 0.05) return s; }
        return null;
      }
      function nextAfter(t) {
        for (var i = 0; i < data.segments.length; i++) { if (data.segments[i].start > t) return data.segments[i]; }
        return null;
      }
      function clearTimer() { if (timer) { clearTimeout(timer); timer = null; } }

      function evaluate() {
        clearTimer();
        if (!video || !data.segments.length || !eligible()) return;
        var t = video.currentTime, seg = inside(t);
        if (seg && !released[seg.uuid]) { skip(seg); return; }
        if (video.paused || video.ended) return;
        var n = nextAfter(t);
        if (n) timer = setTimeout(evaluate, Math.min(Math.max(0, (n.start - t) / (video.playbackRate || 1) * 1000 - 20), 600000));
      }

      function parent() { return document.fullscreenElement || document.body || document.documentElement; }
      function makeBox() {
        if (box && box.isConnected && box.parentNode === parent()) return box;
        if (box && box.parentNode) box.parentNode.removeChild(box);
        box = document.createElement('div');
        box.setAttribute('data-ss-sponsor', '');
        box.setAttribute('role', 'status');
        box.style.cssText = 'position:fixed;right:16px;bottom:84px;z-index:2147483647;display:none;gap:8px;align-items:center;padding:8px 12px;border-radius:10px;' +
          'background:rgba(20,20,20,.88);color:#fff;font:600 13px -apple-system,system-ui,sans-serif;box-shadow:0 2px 10px rgba(0,0,0,.4)';
        parent().appendChild(box);
        return box;
      }
      function hideBox() { if (box) { box.style.display = 'none'; box.textContent = ''; } }
      function notice(seg) {
        var b = makeBox();
        b.textContent = ''; b.style.display = 'flex';
        var t = document.createElement('span'); t.textContent = cfg.skipped; b.appendChild(t);
        var u = document.createElement('button');
        u.textContent = cfg.undo; u.type = 'button';
        u.style.cssText = 'all:unset;cursor:pointer;padding:4px 10px;border-radius:7px;background:#fff;color:#111;font:600 13px -apple-system,system-ui,sans-serif';
        u.addEventListener('click', function (e) { e.stopPropagation(); released[seg.uuid] = true; ourSeek = true; try { video.currentTime = seg.start; } catch (x) {} hideBox(); });
        b.appendChild(u);
        if (hideTimer) clearTimeout(hideTimer);
        hideTimer = setTimeout(hideBox, 5000);
      }

      function skip(seg) {
        if (!video) return;
        var from = video.currentTime;
        ourSeek = true; lastSkip = { seg: seg, at: Date.now() };
        try { video.currentTime = Math.min(seg.end, video.duration); } catch (e) { ourSeek = false; return; }
        stats.skipped++; stats.seconds += Math.max(0, seg.end - from);
        notice(seg);
      }

      // Going back into a segment that was just skipped means the person wants to see it: it is not skipped again.
      function onSeeked() {
        if (ourSeek) { ourSeek = false; } else if (lastSkip && Date.now() - lastSkip.at < 15000 && video.currentTime < lastSkip.seg.end - 0.5) { released[lastSkip.seg.uuid] = true; }
        evaluate();
      }
      var EVENTS = ['playing', 'pause', 'ratechange', 'loadedmetadata', 'durationchange', 'emptied', 'ended'];
      function bind() {
        var v = findVideo();
        if (!v) { if (++tries < 12) setTimeout(bind, 500); return; }
        if (v === bound) { evaluate(); return; }
        if (bound) { EVENTS.forEach(function (n) { bound.removeEventListener(n, evaluate); }); bound.removeEventListener('seeked', onSeeked); }
        bound = video = v;
        EVENTS.forEach(function (n) { v.addEventListener(n, evaluate); });
        v.addEventListener('seeked', onSeeked);
        evaluate();
      }
      // Ask the app for this video's segments, once per video (the app decides whether anything is asked at all).
      function ask() {
        var id = currentID();
        if (!id || id === asked) return;
        asked = id; data = { id: null, segments: [] }; released = {};
        try { window.webkit.messageHandlers.sponsorSkip.postMessage(id); } catch (e) {}
      }
      function navigated() { tries = 0; ask(); bind(); }
      document.addEventListener('fullscreenchange', function () { if (box) { hideBox(); box = null; } });
      document.addEventListener('yt-navigate-finish', navigated);
      window.addEventListener('popstate', navigated);
      window.addEventListener('load', navigated);
      if (document.readyState !== 'loading') navigated(); else document.addEventListener('DOMContentLoaded', navigated);

      window.__ssSponsor = {
        set: function (id, segments) {
          if (id !== currentID() || !Array.isArray(segments)) return;
          var list = [];
          segments.forEach(function (s) {
            if (s && typeof s.start === 'number' && typeof s.end === 'number' && s.end > s.start && s.category === 'sponsor' && typeof s.uuid === 'string') list.push({ start: s.start, end: s.end, category: s.category, uuid: s.uuid });
          });
          list.sort(function (a, b) { return a.start - b.start; });
          data = { id: id, segments: list.slice(0, 100) }; released = {}; tries = 0; bind();
        },
        stats: function () { return JSON.stringify({ skipped: stats.skipped, seconds: Math.round(stats.seconds), count: data.segments.length, asked: asked }); }
      };
    })();
    """#
}
