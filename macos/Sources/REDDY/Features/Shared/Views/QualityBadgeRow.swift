import SwiftUI

/// Small labels for what a title's own text says about picture and sound (4K, HDR, Dolby Vision, Atmos, 5.1). Nothing shows when it says nothing.
struct QualityBadgeRow: View {
    let texts: [String?]
    var body: some View {
        let badges = QualityBadges.from(texts)
        if !badges.isEmpty {
            HStack(spacing: 6) {
                ForEach(badges, id: \.self) { b in
                    Text(b).font(.system(size: 11, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(.primary.opacity(0.85))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                }
            }.accessibilityElement(children: .combine).accessibilityLabel(badges.joined(separator: ", "))
        }
    }
}
