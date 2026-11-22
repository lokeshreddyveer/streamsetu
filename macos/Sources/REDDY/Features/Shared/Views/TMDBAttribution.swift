import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The TMDB logo, the notice TMDB requires, and what is and is not sent to TMDB. Shown in About and beside the TMDB settings.
struct TMDBAttribution: View {
    static let notice = MetadataMatchService.attribution
    static let privacy = "TMDB is used only with your own free API key, and no key is built into the app. Matching artwork, and opening a title's cast or trailer, sends that title's name and year to TMDB; a title in a locked or hidden folder, or with a copy in one, is never sent. Looking up a person by name (Ask) sends that name and nothing else. Weekly trending requests TMDB's public list: nothing about you, your history, your profile or this device is sent, and the list is matched here on this device. Saved lists and details, and the posters, summaries and ratings TMDB filled in, are kept for at most 180 days and then removed; anything your playlist provided itself is never touched. Turn the switch off, or remove the key, and the saved list is deleted."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            logo.frame(height: 14, alignment: .leading).accessibilityLabel("TMDB logo")
            Text(Self.notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(Self.privacy).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var logo: some View {
        #if os(macOS)
        if let image = TMDBLogoImage.shared { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
        else { Text("TMDB").font(.system(size: 12, weight: .heavy)).foregroundStyle(Color(red: 0.24, green: 0.75, blue: 0.79)) }
        #else
        Image("TMDBLogo").resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        #endif
    }
}

#if os(macOS)
@MainActor enum TMDBLogoImage {
    static let shared: NSImage? = {
        if let url = Bundle.main.url(forResource: "TMDBLogo", withExtension: "png"), let image = NSImage(contentsOf: url) { return image }
        #if DEBUG
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return NSImage(contentsOf: root.appendingPathComponent("Resources/Branding/TMDBLogo.png"))
        #else
        return nil
        #endif
    }()
}
#endif
