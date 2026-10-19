import SwiftUI

/// Three short lines on the first screen saying what happens after a playlist is added.
struct FirstRunSteps: View {
    private let steps: [(symbol: String, title: String, detail: String)] = [
        ("link", "Add what you have", "A playlist link or file, or a login from your provider."),
        ("arrow.down.circle", "Let it load", "Channels, films and series are sorted for you. Big lists can take a minute."),
        ("play.circle", "Press play", "Search anything, add favorites, and pick up where you stopped.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: step.symbol).font(.system(size: 18)).foregroundStyle(ColorTokens.accentDefault).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(index + 1). \(step.title)").font(.subheadline.weight(.semibold))
                        Text(step.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
