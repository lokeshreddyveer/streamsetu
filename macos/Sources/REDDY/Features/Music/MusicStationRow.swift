import SwiftUI

/// While a radio station plays: its name, the mode it is in (change it here), a way to stop it, and a quiet note with a retry when it is having trouble
/// finding songs. Shown at the top of the queue and in the Now Playing panel, and nowhere else.
struct MusicStationRow: View {
    @Bindable var hub: MusicHub
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        if hub.radio.isActive, let st = hub.radio.activeStation {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: MusicSpace.sm) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(MusicTokens.iconMedium).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: st.name).font(Typography.bodyMedium).lineLimit(1)
                        Text(verbatim: Localized.string("Station") + " · " + st.mode.title).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(RadioMode.allCases) { m in
                            Button { hub.radio.setMode(st.id, m) } label: { if m == st.mode { Label(m.title, systemImage: "checkmark") } else { Text(verbatim: m.title) } }.atlas("control.music.stationMode")
                        }
                    } label: { Text(Localized.string("Mode")) }
                        .menuStyle(.button).fixedSize().musicButton(.secondary, size: .compact).atlas("control.music.stationModeMenu")
                    Button { hub.radio.stop() } label: { Text(Localized.string("Stop station")) }
                        .musicButton(.secondary, size: .compact).atlas("control.music.stationStop")
                }
                if hub.radio.phase == .troubled {
                    HStack(spacing: MusicSpace.xs) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(ColorTokens.textTertiary)
                        Text(Localized.string("Having trouble finding more songs for this station.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                        Spacer(minLength: 0)
                        Button(Localized.string("Try again")) { hub.radio.retry() }.musicButton(.tertiary, size: .compact).atlas("control.music.stationRetry")
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ColorTokens.lineStrong.opacity(0.15)))
            .accessibilityElement(children: .contain)
        }
    }
}
