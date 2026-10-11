import SwiftUI
import AppKit

/// The REDDY app icon, wherever the interface needs one. It is the bundle's own icon (Resources/Branding/REDDY.icns, copied in by
/// the release script), so replacing that one file changes the icon everywhere.
struct BrandIcon: View {
    var size: CGFloat = 64
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
