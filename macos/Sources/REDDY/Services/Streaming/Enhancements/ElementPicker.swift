import WebKit

/// "Hide This Element": the right-click item of a service page. Nothing here is a persistent script: each call runs ONE one-off script in the
/// service's main frame, started by the person's click, and the script is not kept anywhere. The first script only READS the element under the
/// click point and builds a conservative selector (tag + stable class / id / test-id / role, never text); the second hides what that selector matches;
/// a third undoes it. Only the selector is ever kept (see `TidyStore`): no page text, address, cookie or credential is read or stored.
enum ElementPicker {
    /// Matches allowed for one selector: it should name a small number of elements, not a whole class of the page.
    static let maxMatches = 5

    enum Outcome: Equatable { case hidden(String), nothingSuitable, refused(Refusal), limitReached, scriptFailed, cancelled }

    /// Why the picker was not offered or refused to start. Each has a notice the person reads; nothing fails without one.
    enum Refusal: String, Equatable, Sendable {
        case signInPage, restricted, unsupported
        var notice: String {
            switch self {
            case .signInPage: "Not available on sign-in pages"
            case .restricted: "Not available while locked or in a kids profile"
            case .unsupported: "Hiding elements isn't available for this service"
            }
        }
    }

    /// The reason the picker may not run here, or nil when it may. `restricted` wins (locked or kids), then a service without hosts, then any other page.
    static func refusal(definition: ProviderDefinition, pageURL: URL?, restricted: Bool) -> Refusal? {
        if restricted { return .restricted }
        if !TidyRules.supports(definition.id) { return .unsupported }
        return TidyRules.isTidyHost(pageURL?.host, scheme: pageURL?.scheme, for: definition.id) ? nil : .signInPage
    }

    /// The item is offered only on the service's own https page (never a sign-in or account host, never Google's sign-in window, which is not a
    /// service web view), while nothing restricts the app (not locked, not a kids profile) and the service has page hosts.
    static func isAllowed(definition: ProviderDefinition, pageURL: URL?, restricted: Bool) -> Bool {
        !restricted && TidyRules.isTidyHost(pageURL?.host, scheme: pageURL?.scheme, for: definition.id)
    }

    /// Finds the element at `point` (CSS pixels from the page's top-left), keeps the selector and hides it now.
    @MainActor static func hide(at point: CGPoint, in web: WKWebView, definition: ProviderDefinition, store: TidyStore,
                                restricted: Bool = EnhancementRuntime.shared.isRestricted()) async -> Outcome {
        if let r = refusal(definition: definition, pageURL: web.url, restricted: restricted) { return .refused(r) }
        guard store.hidden(definition.id).count < HiddenSelector.maxPerService else { return .limitReached }
        let read = await runChecked(pickScript, ["x": Double(point.x), "y": Double(point.y), "max": maxMatches], in: web)
        if read.failed { return .scriptFailed }
        guard let selector = selector(fromJSON: read.value), HiddenSelector.isValid(selector) else { return .nothingSuitable }
        return await keep(selector, definition: definition, store: store, in: web)
    }

    /// Pick mode: a temporary overlay on the page (crosshair, outline on hover, a click selects, Escape cancels), then the same keep-and-hide as the
    /// right-click route. The overlay and its listeners remove themselves; nothing stays in the page.
    @MainActor static func pickInteractively(in web: WKWebView, definition: ProviderDefinition, store: TidyStore, hint: String,
                                             restricted: Bool = EnhancementRuntime.shared.isRestricted()) async -> Outcome {
        if let r = refusal(definition: definition, pageURL: web.url, restricted: restricted) { return .refused(r) }
        guard store.hidden(definition.id).count < HiddenSelector.maxPerService else { return .limitReached }
        var args: [String: Any] = ["max": maxMatches, "hint": hint, "timeout": 60_000]
        for (k, v) in themeCSS() { args[k] = v }
        let read = await runChecked(pickModeScript, args, in: web)
        if read.failed { return .scriptFailed }
        guard let json = read.value as? String, let data = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .scriptFailed }
        if o["cancelled"] as? Bool == true { return .cancelled }
        if o["error"] as? Bool == true { return .scriptFailed }
        guard let selector = o["selector"] as? String, HiddenSelector.isValid(selector) else { return .nothingSuitable }
        // the page may have moved to a sign-in page while the person was choosing
        if let r = refusal(definition: definition, pageURL: web.url, restricted: restricted) { return .refused(r) }
        return await keep(selector, definition: definition, store: store, in: web)
    }

    /// Ends pick mode from the app's side (the person left the page or pressed Escape in the app).
    @MainActor static func cancelPickMode(in web: WKWebView?) async {
        guard let web else { return }
        _ = await runChecked("if (window.__ssPick) { window.__ssPick(); } return true;", [:], in: web)
    }

    @MainActor private static func keep(_ selector: String, definition: ProviderDefinition, store: TidyStore, in web: WKWebView) async -> Outcome {
        switch store.addHidden(selector, for: definition.id) {
        case .added, .alreadyThere:
            let applied = await runChecked(applyScript, ["sel": selector], in: web)
            return applied.failed ? .scriptFailed : .hidden(selector)
        case .limitReached: return .limitReached
        case .invalid, .unsupported: return .nothingSuitable
        }
    }

    static func selector(fromJSON value: Any?) -> String? {
        guard let json = value as? String, let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["selector"] as? String
    }

    /// Shows what was hidden again on the open page and forgets the selector.
    @MainActor static func undo(_ selector: String, in web: WKWebView?, definition: ProviderDefinition, store: TidyStore) async {
        store.removeHidden(selector, for: definition.id)
        guard let web, HiddenSelector.isValid(selector), isAllowed(definition: definition, pageURL: web.url, restricted: false) else { return }
        _ = await runChecked(undoScript, ["sel": selector], in: web)
    }

    /// Reads only: returns a selector or nil.
    @MainActor static func pick(at point: CGPoint, in web: WKWebView) async -> String? {
        guard let json = await run(pickScript, ["x": Double(point.x), "y": Double(point.y), "max": maxMatches], in: web) as? String,
              let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["selector"] as? String
    }

    @MainActor private static func run(_ body: String, _ arguments: [String: Any], in web: WKWebView) async -> Any? {
        await runChecked(body, arguments, in: web).value
    }

    /// Like `run`, but says whether the script could not run at all (a page that refused it, a closed view), which is different from "found nothing".
    @MainActor private static func runChecked(_ body: String, _ arguments: [String: Any], in web: WKWebView) async -> (value: Any?, failed: Bool) {
        // main frame, page world; the body is fixed text and everything variable travels as an argument, never inside the script text
        do { return (try await web.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page), false) } catch { return (nil, true) }
    }

    /// The reading script. Climbs from the clicked element a few levels and takes the first selector that (a) matches the candidate itself,
    /// (b) matches between one and `max` elements, (c) matches nothing that is the page, its body or main area, a very large part of the window, or
    /// something containing media or a password field.
    /// The selector builder, shared by the right-click route and pick mode. `selectorFor(el)` returns { selector, node } or null. Reads only.
    static let selectorCore = #"""
      var FORBID = /^(HTML|BODY|MAIN|HEAD|VIDEO|AUDIO|IFRAME|OBJECT|EMBED)$/;
      var STATE = /^(active|selected|open|opened|show|shown|hidden|visible|loading|loaded|disabled|enabled|focus|focused|hover|hovered|current|expanded|collapsed|checked|is-.*|has-.*)$/i;
      var SEMANTIC = /^(header|footer|aside|nav|dialog)$/;
      var TESTID = ['data-testid', 'data-test-id', 'data-test', 'data-automation-id', 'data-uia', 'data-qa', 'data-e2e'];
      var ROLES = ['banner', 'dialog', 'alert', 'complementary', 'region', 'navigation', 'contentinfo', 'status', 'group'];
      function okClass(c) { return /^[A-Za-z][A-Za-z0-9_-]{2,39}$/.test(c) && !/[0-9]/.test(c) && !STATE.test(c); }
      function okId(v) { return /^[A-Za-z][A-Za-z0-9_-]{1,39}$/.test(v) && !/[0-9]{3,}/.test(v) && !/^(react|radix|headlessui|mui|ember|:r)/i.test(v); }
      function okValue(v) { return /^[A-Za-z][A-Za-z0-9_-]{1,59}$/.test(v); }
      function forbidden(n) {
        if (!n || n.nodeType !== 1 || FORBID.test(n.tagName)) return true;
        var r = n.getAttribute('role'); if (r === 'main' || r === 'application') return true;
        return !!n.querySelector('video, audio, main, [role="main"], input[type="password"]');
      }
      function candidates(n) {
        var tag = n.tagName.toLowerCase(), out = [];
        var id = n.getAttribute('id'); if (id && okId(id)) out.push(tag + '#' + id);
        for (var i = 0; i < TESTID.length; i++) { var v = n.getAttribute(TESTID[i]); if (v && okValue(v)) out.push(tag + '[' + TESTID[i] + '="' + v + '"]'); }
        for (var q = 0; q < n.attributes.length; q++) {
          var an = n.attributes[q].name, av = n.attributes[q].value;
          if (/^data-[a-z][a-z-]{1,29}$/.test(an) && TESTID.indexOf(an) < 0 && av && okValue(av) && !/[0-9]{3,}/.test(av)) out.push(tag + '[' + an + '="' + av + '"]');
        }
        var cls = []; for (var j = 0; j < n.classList.length; j++) { if (okClass(n.classList[j])) cls.push(n.classList[j]); }
        if (cls.length) { out.push(tag + '.' + cls.slice(0, 3).join('.')); if (cls.length > 1) { for (var k = 0; k < Math.min(cls.length, 3); k++) out.push(tag + '.' + cls[k]); } }
        var role = n.getAttribute('role'); if (role && ROLES.indexOf(role) >= 0) out.push(tag + '[role="' + role + '"]');
        if (SEMANTIC.test(tag)) out.push(tag);
        return out;
      }
      var vw = Math.max(1, window.innerWidth * window.innerHeight);
      function verify(sel, n) {
        var list; try { list = document.querySelectorAll(sel); } catch (e) { return false; }
        if (list.length < 1 || list.length > max) return false;
        var holds = false;
        for (var i = 0; i < list.length; i++) {
          var m = list[i]; if (m === n) holds = true;
          if (forbidden(m)) return false;
          var b = m.getBoundingClientRect(); if (b.width * b.height > 0.6 * vw) return false;
        }
        return holds;
      }
      function selectorFor(el) {
      var node = el, chain = [];
      for (var d = 0; d < 5 && node && node.nodeType === 1; d++) { if (forbidden(node)) break; chain.push(node); node = node.parentElement; }
      for (var a = 0; a < chain.length; a++) {
        var c = candidates(chain[a]);
        for (var b = 0; b < c.length; b++) { if (verify(c[b], chain[a])) return { selector: c[b], node: chain[a] }; }
      }
      for (var p = 1; p < chain.length && p < 4; p++) {
        var pc = candidates(chain[p]), ec = candidates(chain[0]);
        if (!ec.length) ec = [chain[0].tagName.toLowerCase()];
        for (var u = 0; u < pc.length; u++) for (var w = 0; w < ec.length; w++) {
          var sel = pc[u] + ' ' + ec[w];
          if (sel.length <= 160 && verify(sel, chain[0])) return { selector: sel, node: chain[0] };
        }
      }
      return null;
        return null;
      }
    """#

    /// The reading script for a point (the right-click route): climbs from the clicked element and keeps the first safe selector.
    static let pickScript = selectorCore + #"""
    try {
      var el = document.elementFromPoint(x, y);
      if (!el || el.nodeType !== 1) return null;
      var r = selectorFor(el);
      return r ? JSON.stringify({ selector: r.selector }) : null;
    } catch (e) { return null; }
    """#

    /// Pick mode. One-off: installs a temporary overlay (crosshair, outline on the element that would be hidden, a hint), swallows the page's pointer and
    /// key events while it is up so the page never sees them, and resolves with { selector } | { none } | { cancelled } | { error }. It removes everything it
    /// added when it ends (a click, Escape, 60 seconds, the page leaving, or the app cancelling). Colours and the hint come in as arguments.
    static let pickModeScript = selectorCore + #"""
    return await new Promise(function (resolve) {
      var done = false, raf = 0, timer = 0;
      // Inline style attributes and <style> elements can be refused by a page's content security policy; the style object and a constructed sheet cannot.
      var sheet = null;
      try { sheet = new CSSStyleSheet(); sheet.replaceSync('html, html * { cursor: crosshair !important; }'); } catch (e) { sheet = null; }
      var box = document.createElement('div');
      var hintEl = document.createElement('div');
      var EVENTS = ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'auxclick', 'dblclick', 'contextmenu', 'touchstart', 'touchend', 'dragstart', 'submit', 'keyup', 'keypress'];
      function frame(r, ok) {
        box.style.display = 'block';
        box.style.left = r.left + 'px'; box.style.top = r.top + 'px'; box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
        box.style.borderStyle = ok ? 'solid' : 'dashed';
        box.style.background = ok ? accentFill : 'transparent';
      }
      function stop(e) { if (e.cancelable) e.preventDefault(); e.stopImmediatePropagation(); e.stopPropagation(); }
      function cleanup() {
        window.removeEventListener('mousemove', onMove, true); window.removeEventListener('click', onClick, true); window.removeEventListener('keydown', onKey, true);
        window.removeEventListener('pagehide', onLeave, true);
        for (var i = 0; i < EVENTS.length; i++) window.removeEventListener(EVENTS[i], stop, true);
        if (raf) cancelAnimationFrame(raf);
        clearTimeout(timer);
        [box, hintEl].forEach(function (n) { if (n.parentNode) n.parentNode.removeChild(n); });
        if (sheet) { try { document.adoptedStyleSheets = Array.prototype.filter.call(document.adoptedStyleSheets, function (x) { return x !== sheet; }); } catch (e) {} }
        window.__ssPick = null;
      }
      function finish(result) { if (done) return; done = true; cleanup(); resolve(JSON.stringify(result)); }
      function onMove(e) {
        stop(e);
        if (raf) return;
        var cx = e.clientX, cy = e.clientY;
        raf = requestAnimationFrame(function () {
          raf = 0;
          var el = document.elementFromPoint(cx, cy);
          if (!el || el.nodeType !== 1) { box.style.display = 'none'; return; }
          var r = selectorFor(el);
          frame((r ? r.node : el).getBoundingClientRect(), !!r);
        });
      }
      function onClick(e) {
        stop(e);
        var el = document.elementFromPoint(e.clientX, e.clientY);
        var r = el && el.nodeType === 1 ? selectorFor(el) : null;
        finish(r ? { selector: r.selector } : { none: true });
      }
      function onKey(e) {
        if (e.key === 'Escape') { stop(e); finish({ cancelled: true }); return; }
        if (!(e.metaKey || e.ctrlKey)) stop(e);
      }
      function onLeave() { finish({ cancelled: true }); }
      try {
        if (window.__ssPick) { try { window.__ssPick(); } catch (e) {} }
        box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;box-sizing:border-box;display:none;border:2px solid ' + accent + ';border-radius:4px;';
        hintEl.textContent = hint;
        hintEl.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;top:14px;left:50%;transform:translateX(-50%);padding:7px 14px;border-radius:999px;font:12px -apple-system,system-ui,sans-serif;white-space:nowrap;background:' + panel + ';color:' + text + ';border:1px solid ' + line + ';';
        if (sheet) { try { document.adoptedStyleSheets = Array.prototype.concat.call(Array.prototype.slice.call(document.adoptedStyleSheets), [sheet]); } catch (e) {} }
        document.documentElement.appendChild(box); document.documentElement.appendChild(hintEl);
        window.addEventListener('mousemove', onMove, true); window.addEventListener('click', onClick, true); window.addEventListener('keydown', onKey, true);
        window.addEventListener('pagehide', onLeave, true);
        for (var i = 0; i < EVENTS.length; i++) window.addEventListener(EVENTS[i], stop, true);
        timer = setTimeout(function () { finish({ cancelled: true }); }, timeout);
        window.__ssPick = function () { finish({ cancelled: true }); };
      } catch (e) { finish({ error: true }); }
    });
    """#

    /// Hides what the selector matches on the open page, remembering each element's earlier value so Undo can put it back.
    static let applyScript = #"""
    try {
      var list = document.querySelectorAll(sel), n = 0;
      for (var i = 0; i < list.length && i < 20; i++) {
        var e = list[i];
        if (!e.__ssHid) { e.__ssHid = { v: e.style.getPropertyValue('display'), p: e.style.getPropertyPriority('display') }; e.style.setProperty('display', 'none', 'important'); n++; }
      }
      return n;
    } catch (e) { return 0; }
    """#

    static let undoScript = #"""
    try {
      var list = document.querySelectorAll(sel), n = 0;
      for (var i = 0; i < list.length; i++) {
        var e = list[i];
        if (e.__ssHid) { e.style.removeProperty('display'); if (e.__ssHid.v) e.style.setProperty('display', e.__ssHid.v, e.__ssHid.p); delete e.__ssHid; n++; }
      }
      return n;
    } catch (e) { return 0; }
    """#
}
