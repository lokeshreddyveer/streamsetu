import SwiftUI
import CoreGraphics

// Music follows the cover of the song that is playing, and only inside Music views. The modifier replaces `reddyAccent` for its content (the rest of the app is
// untouched) and exposes tinted fills through the environment. Colour work runs off the main thread and is cached per cover address.

extension Color {
    init(_ c: MusicRGB) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1) }
}

private struct MusicTintKey: EnvironmentKey { static let defaultValue: MusicTintFills? = nil }
extension EnvironmentValues {
    /// Fills tinted from the cover (backgrounds only, never text or borders). Nil when "Adapt colours to artwork" is off or the cover has no colour.
    var musicTint: MusicTintFills? { get { self[MusicTintKey.self] } set { self[MusicTintKey.self] = newValue } }
}

enum MusicAdaptiveSettings {
    /// The switch for "Adapt colours to artwork". Off until the person turns it on.
    static let defaultsKey = "music.adaptiveAccent"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

/// Cover colours cached by address: 500 entries, then cleared. Washes keep the last 8.
@MainActor
final class MusicAdaptiveColorCache {
    static let shared = MusicAdaptiveColorCache()
    static let accentLimit = 500
    private var accents: [String: MusicRGB?] = [:]
    private var washes: [(key: String, baked: MusicCoverWash.Baked)] = []

    /// The raw cover colour (before it is brought into the theme band, so a light or dark flip reuses it).
    func rawColor(for url: String) async -> MusicRGB? {
        if let hit = accents[url] { return hit }
        guard let img = await MusicArtworkService.shared.load(url, targetPixelSize: 128) else { return nil }
        let c = await Task.detached(priority: .utility) { MusicAdaptiveColor.rgba(from: img.cg).flatMap { MusicAdaptiveColor.dominant(rgba: $0) } }.value
        if accents.count >= Self.accentLimit { accents.removeAll() }
        accents[url] = .some(c)
        return c
    }

    func wash(for url: String) async -> MusicCoverWash.Baked? {
        if let hit = washes.first(where: { $0.key == url }) { return hit.baked }
        guard let img = await MusicArtworkService.shared.load(url, targetPixelSize: 256) else { return nil }
        let baked = await Task.detached(priority: .utility) { MusicAdaptiveColor.rgba(from: img.cg, side: MusicCoverWash.side).map { MusicCoverWash.bake(rgba: $0) } }.value
        guard let baked else { return nil }
        washes.append((url, baked))
        if washes.count > MusicCoverWash.cacheLimit { washes.removeFirst() }
        return baked
    }

    /// Looks at the next cover ahead of time so the colour starts moving on the frame the artwork changes.
    func warm(_ url: String?) { if let url { Task { _ = await rawColor(for: url) } } }
}

private struct MusicAdaptiveAccent: ViewModifier {
    let url: String?
    /// Read live: the Settings switch applies at once, without waiting for the page that hosts this to be drawn again.
    @AppStorage(MusicAdaptiveSettings.defaultsKey) private var stored = false
    var override: Bool?
    private var enabled: Bool { override ?? stored }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.reddyAccent) private var base
    @State private var raw: MusicRGB?

    private var accent: MusicRGB? { enabled ? raw.map { MusicAdaptiveColor.toAccent($0, dark: scheme == .dark) } : nil }

    func body(content: Content) -> some View {
        content
            .environment(\.reddyAccent, accent.map(Color.init) ?? base)
            .environment(\.musicTint, accent.map { MusicAdaptiveColor.fills(hue: MusicAdaptiveColor.oklchHue($0), dark: scheme == .dark) })
            .task(id: enabled ? url : nil) {
                guard enabled, let url else { raw = nil; return }
                raw = nil                           // the previous song's colour is dropped at once, not kept
                raw = await MusicAdaptiveColorCache.shared.rawColor(for: url)
            }
    }
}

extension View {
    /// Inside Music only: replaces the accent with a colour taken from this cover. `enabled` defaults to the "Adapt colours to artwork" setting (off).
    func musicAdaptiveAccent(for thumbs: [MusicThumbnail], enabled: Bool? = nil) -> some View {
        modifier(MusicAdaptiveAccent(url: thumbs.best(minSide: 120), override: enabled))
    }
}

