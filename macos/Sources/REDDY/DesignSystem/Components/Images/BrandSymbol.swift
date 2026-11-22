import SwiftUI
import AppKit

/// The transparent TV symbol (silver TV, play button, teal ribbon) used on the dark start screens. It is
/// Resources/Branding/BrandSymbol.png, copied into the app's Resources folder by the release script. A development build run
/// straight from the package finds it in the source tree instead. If it is missing, the app icon stands in.
struct BrandSymbol: View {
    var size: CGFloat = 260

    var body: some View {
        Group {
            if let image = BrandSymbolImage.shared {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                BrandIcon(size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
enum BrandSymbolImage {
    /// Loaded once: the image is large and every start screen shows it.
    static let shared: NSImage? = {
        if let url = Bundle.main.url(forResource: "BrandSymbol", withExtension: "png"), let image = NSImage(contentsOf: url) { return image }
        #if DEBUG
        // swift run and swift test have no app bundle, so the file is read from the package's Resources folder.
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return NSImage(contentsOf: packageRoot.appendingPathComponent("Resources/Branding/BrandSymbol.png"))
        #else
        return nil
        #endif
    }()
}
