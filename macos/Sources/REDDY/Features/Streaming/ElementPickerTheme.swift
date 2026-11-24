import SwiftUI
import AppKit

extension ElementPicker {
    /// The theme colours the overlay uses, as CSS colours (the overlay is drawn in the page, so it cannot read the app's tokens itself).
    @MainActor static func themeCSS() -> [String: String] {
        func css(_ c: Color, _ alpha: Double) -> String {
            let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor.systemBlue
            return String(format: "rgba(%d,%d,%d,%.2f)", Int((n.redComponent * 255).rounded()), Int((n.greenComponent * 255).rounded()), Int((n.blueComponent * 255).rounded()), alpha)
        }
        return ["accent": css(ColorTokens.accentDefault, 1), "accentFill": css(ColorTokens.accentDefault, 0.16), "panel": css(ColorTokens.panel, 0.96),
                "text": css(ColorTokens.textPrimary, 1), "line": css(ColorTokens.textPrimary, 0.25)]
    }
}
