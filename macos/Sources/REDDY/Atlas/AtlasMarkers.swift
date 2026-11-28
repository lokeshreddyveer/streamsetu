import SwiftUI

/// The frames of every marked control on screen, in the coordinate space of whoever reads them (the Show-me host). Merged up the view tree; a later marker with the same id wins.
struct AtlasFramesKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    /// Called for every node of the view tree each time anything under it updates, and almost always with nothing to merge (markers record only while Show-me runs), so the empty cases return before any dictionary work.
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        let next = nextValue()
        if next.isEmpty { return }
        if value.isEmpty { value = next; return }
        value.merge(next) { _, new in new }
    }
}

/// The screens that are on screen right now (innermost last), for the engine's "this screen" boost and for Show-me's "open <screen> first".
struct AtlasScreenKey: PreferenceKey {
    static var defaultValue: [String] { [] }
    static func reduce(value: inout [String], nextValue: () -> [String]) { value.append(contentsOf: nextValue()) }
}

private struct AtlasScreenEnvironmentKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    /// The Atlas id of the screen this view is in, set by `.atlasScreen("screen.settings.playback")`.
    var atlasScreen: String? {
        get { self[AtlasScreenEnvironmentKey.self] }
        set { self[AtlasScreenEnvironmentKey.self] = newValue }
    }
}

/// Debug-only support for the screen walk (gate c): with `--atlas-walk` on the command line every marker also publishes an invisible accessibility element named `atlas:<id>`, so a UI test can see which declared controls are really on screen.
/// Not compiled into release builds (the flag is a constant false there), and it adds nothing to the layout or to what VoiceOver reads.
enum AtlasProbe {
    #if DEBUG
    static let enabled = ProcessInfo.processInfo.arguments.contains("--atlas-walk")
    static let reduceMotion = ProcessInfo.processInfo.arguments.contains("--atlas-reduce-motion")
    #else
    static let enabled = false
    static let reduceMotion = false
    #endif
}

struct AtlasProbeView: View {
    let identifier: String
    var body: some View {
        Color.clear.frame(width: 2, height: 2).accessibilityElement().accessibilityLabel("atlas probe").accessibilityIdentifier(identifier).allowsHitTesting(false)
    }
}

/// Frames are only recorded while something reads them: a Show-me request is active, or tests force markers on.
/// Every tile and row carries a marker, and a live preference per tile makes the whole tree re-reduce each time a lazy container realizes or drops one.
enum AtlasMarkerGate {
    /// Tests (and the screen walk) set this to record frames without a Show-me session.
    nonisolated(unsafe) static var forceEnabled = false
    @MainActor static var enabled: Bool { forceEnabled || ShowMeController.shared.isActive }
}

private struct AtlasMarkerModifier: ViewModifier {
    let id: String?
    @MainActor func body(content: Content) -> some View {
        if AtlasMarkerGate.enabled, let id {
            content.anchorPreference(key: AtlasFramesKey.self, value: .bounds) { [id: $0] }
        } else {
            content
        }
    }
}

extension View {
    /// Marks an interactive control with the id of its Atlas entry. It changes nothing on screen; it records the control's frame so Show-me can point at it.
    func atlas(_ id: String) -> some View {
        modifier(AtlasMarkerModifier(id: id))
            .overlay(alignment: .topLeading) { if AtlasProbe.enabled { AtlasProbeView(identifier: "atlas:" + id) } }
    }

    /// The same marker for a helper that may or may not have an id (a settings row). With `nil` nothing is recorded and the view is unchanged.
    func atlasOptional(_ id: String?) -> some View {
        modifier(AtlasMarkerModifier(id: id))
            .overlay(alignment: .topLeading) { if AtlasProbe.enabled, let id { AtlasProbeView(identifier: "atlas:" + id) } }
    }

    /// Marks one declaration that makes many controls (a `ForEach` of rows) as covered by the entry `id`. For the scan gate only; nothing is recorded.
    func atlasCovers(_ id: String) -> some View { self }

    /// Put on the root of a screen or settings page. The id is an Atlas entry id.
    func atlasScreen(_ id: String) -> some View {
        environment(\.atlasScreen, id).preference(key: AtlasScreenKey.self, value: [id])
            .overlay(alignment: .topLeading) { if AtlasProbe.enabled { AtlasProbeView(identifier: "atlas.screen:" + id) } }
    }

    /// Lets Show-me scroll the marked view into sight: pass the proxy of the page's ScrollViewReader. Best effort; a page without it is simply not scrolled.
    func atlasScrollProxy(_ proxy: ScrollViewProxy) -> some View {
        onAppear { ShowMeController.shared.scrollHandler = { id in proxy.scrollTo(AtlasScroll.id(id), anchor: .center) } }
    }

    /// The scroll target for `atlasScrollProxy`. Use it on rows that live inside a long scrolling page.
    func atlasScrollTarget(_ id: String) -> some View { self.id(AtlasScroll.id(id)) }
}

enum AtlasScroll { static func id(_ marker: String) -> String { "atlas:" + marker } }
