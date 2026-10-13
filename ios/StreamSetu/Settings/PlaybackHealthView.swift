import SwiftUI

/// What is going on with playback, in plain words: how long each player takes to start for each playlist, what failed lately, and a
/// one-tap fix when the other player is clearly faster. Everything here is measured on this device.
struct PlaybackHealthView: View {
    @Environment(\.container) private var container
    @Environment(AppSettings.self) private var settings
    @State private var sources: [PlaylistSource] = []
    @State private var rows: [StartStats.Row] = []
    @State private var problems: [String] = []
    @State private var note: String?
    @State private var sending = false

    var body: some View {
        List {
            if rows.isEmpty {
                Section { Text("Nothing measured yet. Play a few movies, episodes and channels, then come back.").foregroundStyle(.secondary) }
                    .listRowBackground(ColorTokens.surface)
            }
            ForEach(sources) { s in
                let mine = rows.filter { $0.source == s.id }
                if !mine.isEmpty {
                    Section(s.name) {
                        ForEach(mine) { r in line(r) }
                        if let hint = StartStats.suggestion(rows: rows, source: s.id), settings.engineOverride(for: s.id) == nil || settings.engineOverride(for: s.id) == .automatic {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(hint.engine.rawValue) starts movies about \(Int(hint.fasterBy.rounded())) seconds faster here.").font(.subheadline)
                                Button("Use \(hint.engine.rawValue) for this playlist") {
                                    settings.setEngineOverride(hint.engine == .mpv ? .mpv : .avPlayer, for: s.id)
                                    note = "Done. \(s.name) now uses \(hint.engine.rawValue). You can change it in Settings → Playback."
                                }.buttonStyle(.borderedProminent)
                                if hint.engine == .mpv { Text("MPV has no Picture in Picture or AirPlay.").font(.footnote).foregroundStyle(.secondary) }
                            }.padding(.vertical, 4)
                        }
                    }.listRowBackground(ColorTokens.surface)
                }
            }
            if let note { Section { Label(note, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }.listRowBackground(ColorTokens.surface) }
            Section("Recent problems") {
                if problems.isEmpty { Text("None lately.").foregroundStyle(.secondary) }
                ForEach(problems, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
            }.listRowBackground(ColorTokens.surface)
            Section {
                Button { send() } label: { Label(sending ? "Sending…" : "Send My Log", systemImage: "paperplane") }.disabled(sending)
                Button("Reset These Numbers", role: .destructive) { StartStats.shared.reset(); reload() }
            } footer: { Text("Only counts and times are kept, on this device. No titles or addresses.") }.listRowBackground(ColorTokens.surface)
        }
        .navigationTitle("Playback Health").themed("Playback Health")
        .task { reload() }
    }

    private func line(_ r: StartStats.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(r.live ? "Live TV" : "Movies and episodes") · \(r.engine)").font(.subheadline.weight(.semibold))
            let rec = r.record
            Text(rec.plays == 0 ? "No successful starts yet" : "Starts in about \(Int(rec.average.rounded())) s (slowest \(Int(rec.slowest.rounded())) s) · \(rec.plays) play\(rec.plays == 1 ? "" : "s")")
                .font(.footnote).foregroundStyle(.secondary)
            if rec.failures > 0 { Text("\(rec.failures) gave up").font(.footnote).foregroundStyle(.orange) }
        }
    }

    private func reload() {
        guard let c = container else { return }
        sources = (try? c.catalog.sources()) ?? []
        rows = StartStats.shared.rows()
        problems = LogMasker.mask(PlaybackLog.shared.tail(lines: 400).filter { $0.contains(" failure ") }.suffix(8).reversed().map { String($0.dropFirst(0)) })
    }

    private func send() {
        sending = true; note = nil
        Task {
            let ok = await DiagnosticsUploader.shared.send(trigger: "manual")
            sending = false
            note = ok ? "Log sent. Thank you." : "Couldn't send. Check your connection."
        }
    }
}
