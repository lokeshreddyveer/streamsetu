#if os(macOS)
import AppKit
import SwiftUI

/// The entertainment icons of the opening: the very symbols the top bar uses for its destinations, drawn once into bitmaps (off the frame path) and only read by a frame.
/// In the top bar's order: Live TV, Movies, Series, Podcasts, Music, then Sports (the court symbol the app's sport categories use), the Services button and the Library shortcut's grid.
enum OpeningIcons {
    /// (name, SF Symbol) in the order they travel. The symbols are the ones in NavTab.symbol, TopBarItem.podcastsGlyph, the Services button and the Library shortcut.
    static let symbols: [(name: String, symbol: String)] = [
        ("Live TV", "tv"), ("Movies", "film"), ("Series", "rectangle.stack.fill"), ("Podcasts", "mic.fill"), ("Music", "music.note"), ("Sports", "sportscourt"),
        ("Services", "square.grid.2x2"), ("Library", "books.vertical.fill")
    ]

    private static let store = Locked<[CGImage]?>(nil)

    /// The bitmaps, or empty until `preload()` has run. A frame never builds one.
    static var current: [CGImage] { store.value ?? [] }

    /// Draws every symbol once (template images, 96 px, semibold). Calling it again does nothing.
    @MainActor static func preload() {
        guard store.value == nil else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .semibold)
        var out: [CGImage] = []
        for item in symbols {
            guard let base = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { continue }
            var rect = CGRect(origin: .zero, size: CGSize(width: base.size.width * 2, height: base.size.height * 2))
            if let cg = base.cgImage(forProposedRect: &rect, context: nil, hints: nil) { out.append(cg) }
        }
        store.value = out
    }
}
#endif
