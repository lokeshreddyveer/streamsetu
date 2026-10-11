import SwiftUI

/// Shown instead of a black picture while a radio channel (sound, no video) plays: the channel's artwork, its name, what is on,
/// and a quiet level display that moves while it plays.
struct AudioOnlyBackdrop: View {
    let playback: PlaybackCoordinator
    var program: EPGProgram?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x10151F), Color(hex: 0x05070B)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [ColorTokens.accentDefault.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 360)
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Color.white.opacity(0.06))
                        .frame(width: 190, height: 190)
                        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
                        .shadow(color: ColorTokens.accentDefault.opacity(0.35), radius: 40)
                    ArtworkImage(url: playback.currentChannel?.logoURL ?? playback.current?.artworkURL, kind: .logo, contentMode: .fit, symbol: "dot.radiowaves.left.and.right")
                        .frame(width: 140, height: 140)
                }
                Text(playback.title).font(.system(size: 22, weight: .semibold)).lineLimit(1).foregroundStyle(.white)
                if let program { Text(program.title).font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
                Levels(active: playback.state == .playing && !reduceMotion)
                Text("Radio · audio only").font(.system(size: 11, weight: .medium)).tracking(0.8).foregroundStyle(.white.opacity(0.45))
            }
            .padding(30)
        }
        .accessibilityElement(children: .combine).accessibilityLabel("Radio: \(playback.title)\(program.map { ", now " + $0.title } ?? "")")
    }

    private struct Levels: View {
        let active: Bool
        var body: some View {
            TimelineView(.animation(minimumInterval: 0.12, paused: !active)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: 5) {
                    ForEach(0..<9, id: \.self) { i in
                        let phase = active ? (sin(t * 3.2 + Double(i) * 0.9) * 0.5 + 0.5) : 0.25
                        Capsule().fill(ColorTokens.accentDefault.opacity(0.9)).frame(width: 5, height: 8 + 28 * phase)
                    }
                }.frame(height: 40)
            }
        }
    }
}
