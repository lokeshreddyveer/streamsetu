import SwiftUI

/// A small dot on a channel row: the channel has a guide now ("Guide available"), or is matched but empty. Nothing is drawn for a channel without a guide, so a long list stays quiet.
struct GuideDot: View {
    let availability: GuideAvailability
    var body: some View {
        if availability.showsDot || availability == .mappedEmpty {
            Circle().fill(availability == .nowNext ? ColorTokens.success : ColorTokens.warning).frame(width: 6, height: 6)
                .accessibilityLabel(availability.accessibilityLabel).atlas("setting.guide.freshness")
        }
    }
}

/// "Guide ends in 6 h", "The guide was last updated 3 days ago": shown at the top of the TV Guide when a guide needs attention. Dismissed for 24 hours per message.
struct GuideFreshnessBanner: View {
    @Environment(\.container) private var container
    @State private var item: (key: String, text: String, level: GuideFreshnessLevel)?
    @AppStorage("guide.banner.dismissed") private var dismissed = ""

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0).task { reload() }       // a view that always exists, so the load runs even while no banner is shown
            if let item, !isDismissed(item.key) {
                HStack(spacing: 8) {
                    Image(systemName: item.level == .error ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark").foregroundStyle(ColorTokens.warning).accessibilityHidden(true)
                    Text(LocalizedStringKey(item.text)).font(.callout)
                    Spacer(minLength: 8)
                    Button("Dismiss") { dismissed = "\(item.key)|\(Int(Date().timeIntervalSince1970))" }.buttonStyle(.borderless).font(.callout).atlas("setting.storage.guideBannerDismissed")
                }
                .padding(.horizontal, 14).padding(.vertical, 8).background(ColorTokens.warning.opacity(0.14))
                .accessibilityElement(children: .contain).atlas("setting.guide.freshness")
            }
        }
    }

    private func isDismissed(_ key: String) -> Bool {
        let p = dismissed.split(separator: "|"); guard p.count == 2, p[0] == key, let t = Double(p[1]) else { return false }
        return Date().timeIntervalSince1970 - t < 86400
    }
    private func reload() {
        guard let db = container?.db, let m = try? GuideSettingsModel.load(db: db) else { return }
        // The worst enabled guide that has something to say; a healthy library shows nothing.
        let worst = m.rows.filter { $0.enabled && $0.freshness.level >= .warning || ($0.enabled && $0.freshness.key == "guide.endsIn") }.max { $0.freshness.level < $1.freshness.level }
        item = worst.map { ($0.freshness.key, $0.summary, $0.freshness.level) }
    }
}
