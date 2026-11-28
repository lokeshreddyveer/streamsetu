import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The accent colour the system is set to, as a plain colour. Nil when it cannot be read.
@MainActor
enum MusicSystemAccent {
    static func current() -> MusicRGB? {
        #if os(macOS)
        guard let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return nil }
        return MusicRGB(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor.tintColor.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return MusicRGB(Double(r), Double(g), Double(b))
        #endif
    }
}
