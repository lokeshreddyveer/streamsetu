import SwiftUI
#if os(macOS)
import AppKit
#endif

/// How quickly Music has answered this session against the targets: pages open in under 200 ms, a play press answers in under 100 ms, and the app never
/// stalls for more than 50 ms. Kept in memory only; Copy puts a plain report on the clipboard.
struct MusicPerformanceSection: View {
    private let probe = MusicPerfProbe.shared

    var body: some View {
        let pages = MusicPerfStats.summary(probe.samples, kind: .pageOpen)
        let plays = MusicPerfStats.summary(probe.samples, kind: .playPress)
        let slow = MusicPerfStats.summary(probe.samples, kind: .slowMoment)
        MusicSettingsGroup(title: "Responsiveness", footer: "Measured on this device while you use Music. Nothing is sent anywhere, and it is forgotten when you quit.") {
            MusicSettingsRow(title: "Pages opened", atlas: "control.music.perfPages", detail: Self.line(pages, limit: Int(MusicPerfBudget.pageOpenMs))) { EmptyView() }
            MusicSettingsRow(title: "Play presses", atlas: "control.music.perfPlays", detail: Self.line(plays, limit: Int(MusicPerfBudget.playPressMs))) { EmptyView() }
            MusicSettingsRow(title: "Slow moments", atlas: "control.music.perfSlow", detail: slow.count == 0 ? Localized.string("None over 50 ms") : Localized.string("%@ over 50 ms", "\(slow.count)") + ", " + Localized.string("worst %@ ms", "\(Int(slow.worst))")) { EmptyView() }
            MusicSettingsActions {
                Button("Copy report") { Self.copy(probe.report()) }.atlas("control.music.perfCopy")
                Button("Clear") { probe.clear() }.atlas("control.music.perfClear")
            }
        }
    }

    private static func line(_ s: MusicPerfSummary, limit: Int) -> String {
        guard s.count > 0 else { return Localized.string("Nothing measured yet") }
        return Localized.string("median %@ ms", "\(Int(s.median))") + ", " + Localized.string("slowest %@ ms", "\(Int(s.worst))") + " · " + Localized.string("%@ over the limit", "\(s.overBudget)") + ", " + Localized.string("%@ measured", "\(s.count)")
    }

    private static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
