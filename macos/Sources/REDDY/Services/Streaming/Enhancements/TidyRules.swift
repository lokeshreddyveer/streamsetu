import Foundation
import Observation
import WebKit

/// "Tidy pages": a short, built-in list of purely cosmetic nags (banners and buttons that ask you to install the app, a few promo panels) that a
/// person can hide per service. It is NOT an ad blocker: every rule is a `css-display-none` selector in a system content rule list scoped to that
/// service's own page hosts. No script, no network, nothing is read from the page. Rules come from public annoyance lists and are best effort:
/// a site can change its markup at any time, and a rule only ever hides, it never clicks, blocks a request or touches video, licences, keys or CDNs.
/// Cookie and consent dialogs are deliberately NOT here: hiding one leaves the question unanswered and can block the page.
struct TidyRule: Equatable, Sendable {
    let selector: String
    /// What it hides, in a few words.
    let hides: String
    /// Where the rule was found (a public list or userscript, by name).
    let source: String
}

enum TidyRules {
    /// Bumped whenever a table below changes; part of the compiled list's identifier so a changed table is recompiled.
    static let version = 1

    /// The exact page hosts of each service (the service's own pages, never a sign-in or account host). WebKit's `if-domain` without a leading `*`
    /// matches that exact host only, so `accounts.google.com`, `accounts.youtube.com`, `accounts.spotify.com`, `auth.max.com` and every other
    /// service are never touched. A service missing here (JioHotstar, on hold) gets nothing, not even the element picker.
    static let hosts: [ProviderID: [String]] = [
        .netflix: ["www.netflix.com"],
        .primevideo: ["www.primevideo.com"],
        .disneyplus: ["www.disneyplus.com"],
        .hulu: ["www.hulu.com"],
        .hbomax: ["www.hbomax.com", "www.max.com"],
        .peacock: ["www.peacocktv.com"],
        .paramountplus: ["www.paramountplus.com"],
        .appletv: ["tv.apple.com"],
        .youtube: ["www.youtube.com"],
        .crunchyroll: ["www.crunchyroll.com"],
        .spotify: ["open.spotify.com"],
    ]

    /// The rules, only for the services where a public source showed a marker stable enough to use. Netflix, Prime Video, Disney+, Hulu, HBO Max,
    /// Peacock, Paramount+ and Apple TV have none: the public lists only hold consent or ad rules for them (see the research notes). Nothing is guessed.
    static let rules: [ProviderID: [TidyRule]] = [
        .youtube: [
            TidyRule(selector: "ytd-popup-container ytd-mealbar-promo-renderer", hides: "The bottom promo bar (get the app, try Premium)", source: "AdGuard Annoyances list"),
            TidyRule(selector: "yt-mealbar-promo-renderer", hides: "The same promo bar, under its other element name", source: "AdGuard Annoyances list"),
            TidyRule(selector: "ytd-statement-banner-renderer", hides: "The statement banner at the top of the home page", source: "AdGuard Annoyances list"),
            TidyRule(selector: ".ytd-primetime-promo-renderer", hides: "The Premium promo panel", source: "Fanboy Annoyances list"),
        ],
        .crunchyroll: [
            TidyRule(selector: ".cr-expo-banner", hides: "The event promo banner", source: "AdGuard Annoyances list"),
            TidyRule(selector: ".game-banner-wrapper", hides: "The mobile games promo banner", source: "AdGuard Annoyances list"),
        ],
        .spotify: [
            TidyRule(selector: #"a[href="/download"]"#, hides: "The Install App button in the top bar", source: "AdGuard Annoyances and Mobile App Banners lists (.Root__nav-bar a[href=\"/download\"])"),
            TidyRule(selector: #"div[data-testid="home-banner"]"#, hides: "The promo banner on the home page", source: "AdGuard Annoyances list"),
        ],
    ]

    static func hosts(for id: ProviderID) -> [String] { hosts[id] ?? [] }
    static func rules(for id: ProviderID) -> [TidyRule] { rules[id] ?? [] }
    /// The service has any page host at all (so the toggle and the element picker can work).
    static func supports(_ id: ProviderID) -> Bool { !hosts(for: id).isEmpty }

    /// The page may be tidied or have an element picked: https and one of the service's own exact hosts.
    static func isTidyHost(_ host: String?, scheme: String?, for id: ProviderID) -> Bool {
        guard scheme?.lowercased() == "https", let h = host?.lowercased() else { return false }
        return hosts(for: id).contains(h)
    }
}

/// A hidden element's selector, checked to be only a selector. Used before anything is stored and again when it is read back.
enum HiddenSelector {
    static let maxLength = 200
    static let maxPerService = 50
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-#.[]=\"> *")

    /// Letters, digits and the few characters a plain selector needs. No braces, semicolons, parentheses, commas, colons, backslashes, `@` or `/`, so
    /// it cannot end a rule, start another, call `url()` or `:not()`, or carry a comment. Words that name a CSS function or at-rule are refused too.
    static func isValid(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= maxLength, s == s.trimmingCharacters(in: .whitespaces), s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let l = s.lowercased()
        guard !["url", "import", "expression", "charset", "font-face", "media", "keyframes", "javascript"].contains(where: l.contains) else { return false }
        guard s.filter({ $0 == "\"" }).count % 2 == 0, s.filter({ $0 == "[" }).count == s.filter({ $0 == "]" }).count else { return false }
        guard !s.hasPrefix(">"), !s.hasSuffix(">"), !s.contains("  "), !s.contains("]]"), !s.contains("[[") else { return false }
        // too broad on their own: the page, its body, its main area, or everything
        let bare = l.trimmingCharacters(in: .whitespaces)
        return !["html", "body", "main", "head", "*", "div", "span", "a", "section", "article"].contains(bare)
    }
}

/// The two preferences of the feature, per service, in UserDefaults like the other hub preferences: whether Tidy pages is on (off by default), and the
/// list of selectors the person hid with "Hide This Element" (at most 50). Only a selector is ever kept: no text, address, cookie or credential.
@MainActor @Observable
final class TidyStore {
    static let shared = TidyStore()
    /// Posted (object: the service's raw id) after any change, so a live web view can swap its rule list.
    nonisolated static let didChange = Notification.Name("streaming.tidyDidChange")

    @ObservationIgnored private let defaults: UserDefaults
    /// For tests: the store this one reads, to open a second store on the same preferences.
    var testDefaults: UserDefaults { defaults }
    private(set) var revision = 0
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func enabledKey(_ id: ProviderID) -> String { "tidy.enabled.\(id.rawValue)" }
    static func hiddenKey(_ id: ProviderID) -> String { "tidy.hidden.\(id.rawValue)" }

    /// On unless the person turned it off: a service with rules starts on; one never set and without rules stays off (nothing to tidy). A stored choice, either way, wins.
    func isEnabled(_ id: ProviderID) -> Bool {
        _ = revision
        if let stored = defaults.object(forKey: Self.enabledKey(id)) as? Bool { return stored }
        return !TidyRules.rules(for: id).isEmpty
    }
    func setEnabled(_ on: Bool, for id: ProviderID) {
        guard TidyRules.supports(id), isEnabled(id) != on || defaults.object(forKey: Self.enabledKey(id)) == nil else { return }
        defaults.set(on, forKey: Self.enabledKey(id)); changed(id)
    }

    /// The stored selectors, each re-checked as it is read (a hand-edited preference cannot smuggle anything in), without duplicates, at most 50.
    func hidden(_ id: ProviderID) -> [String] {
        _ = revision
        guard let raw = defaults.data(forKey: Self.hiddenKey(id)), let list = try? JSONDecoder().decode([String].self, from: raw) else { return [] }
        var seen = Set<String>(), out: [String] = []
        for s in list where HiddenSelector.isValid(s) && seen.insert(s).inserted { out.append(s); if out.count == HiddenSelector.maxPerService { break } }
        return out
    }
    func hiddenCount(_ id: ProviderID) -> Int { hidden(id).count }

    enum AddResult: Equatable { case added, alreadyThere, invalid, limitReached, unsupported }

    @discardableResult func addHidden(_ selector: String, for id: ProviderID) -> AddResult {
        guard TidyRules.supports(id) else { return .unsupported }
        guard HiddenSelector.isValid(selector) else { return .invalid }
        var list = hidden(id)
        if list.contains(selector) { return .alreadyThere }
        guard list.count < HiddenSelector.maxPerService else { return .limitReached }
        list.append(selector); save(list, id); return .added
    }

    func removeHidden(_ selector: String, for id: ProviderID) {
        let list = hidden(id)
        guard list.contains(selector) else { return }
        save(list.filter { $0 != selector }, id)
    }

    /// Reset: removes every hidden element of the service (Tidy pages itself stays as it is).
    func resetHidden(for id: ProviderID) {
        guard defaults.object(forKey: Self.hiddenKey(id)) != nil else { return }
        defaults.removeObject(forKey: Self.hiddenKey(id)); changed(id)
    }

    private func save(_ list: [String], _ id: ProviderID) {
        if list.isEmpty { defaults.removeObject(forKey: Self.hiddenKey(id)) }
        else if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.hiddenKey(id)) }
        changed(id)
    }
    private func changed(_ id: ProviderID) {
        revision += 1
        NotificationCenter.default.post(name: Self.didChange, object: id.rawValue)
    }
}

/// The compiled rule list of one service: Tidy pages rules (while on) merged with the person's hidden elements. One `css-display-none` rule per
/// kind, each scoped with `if-domain` to the service's own exact hosts.
enum TidyRuleList {
    /// The WebKit JSON, or nil when there is nothing to hide (then no list exists at all).
    static func json(for id: ProviderID, tidyOn: Bool, hidden: [String]) -> String? {
        let hosts = TidyRules.hosts(for: id)
        guard !hosts.isEmpty else { return nil }
        var selectors = tidyOn ? TidyRules.rules(for: id).map(\.selector) : []
        selectors += hidden.filter(HiddenSelector.isValid)
        var seen = Set<String>(); selectors = selectors.filter { seen.insert($0).inserted }
        guard !selectors.isEmpty else { return nil }
        let rule: [String: Any] = ["trigger": ["url-filter": ".*", "if-domain": hosts], "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")]]
        guard let data = try? JSONSerialization.data(withJSONObject: [rule], options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Stable name in WebKit's rule store: service, table version and a checksum of the JSON (so a changed list is a new list).
    static func identifier(for id: ProviderID, json: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in json.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "setu.tidy.\(id.rawValue).v\(TidyRules.version).\(String(h, radix: 16))"
    }
    static func prefix(for id: ProviderID) -> String { "setu.tidy.\(id.rawValue)." }

    /// Compiles (or finds) the list and forgets this service's older ones. nil on any failure: the page then stays exactly as it was.
    @MainActor static func list(for id: ProviderID, tidyOn: Bool, hidden: [String], in store: WKContentRuleListStore) async -> WKContentRuleList? {
        guard let json = json(for: id, tidyOn: tidyOn, hidden: hidden) else { await removeStale(for: id, keeping: nil, in: store); return nil }
        let identifier = identifier(for: id, json: json)
        await removeStale(for: id, keeping: identifier, in: store)
        if let existing = try? await store.contentRuleList(forIdentifier: identifier) { return existing }
        return try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
    }

    @MainActor private static func removeStale(for id: ProviderID, keeping keep: String?, in store: WKContentRuleListStore) async {
        let ids: [String] = await withCheckedContinuation { c in store.getAvailableContentRuleListIdentifiers { c.resume(returning: $0 ?? []) } }
        for old in ids where old.hasPrefix(prefix(for: id)) && old != keep { try? await store.removeContentRuleList(forIdentifier: old) }
    }
}
