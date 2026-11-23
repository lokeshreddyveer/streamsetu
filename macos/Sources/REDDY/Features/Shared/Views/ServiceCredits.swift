import SwiftUI

/// Credits and links for the extra artwork and details sources: in Settings and About only.
struct ServiceCreditsView: View {
    /// Credits drawn elsewhere on the same screen (TMDB has its logo and notice above).
    var skipping: Set<String> = []
    /// Sparkle updates the Mac app only: the iPhone and iPad list does not credit it.
    private static var phone: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ServiceCredits.all.filter { !skipping.contains($0.id) && !(Self.phone && $0.id == "sparkle") }) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.text.loc).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Link(c.linkTitle, destination: c.url).font(.caption)
                }
            }
            Text(ServiceCredits.privacy.loc).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
