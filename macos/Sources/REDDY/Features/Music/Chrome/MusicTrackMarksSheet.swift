import SwiftUI

/// Moves around inside the song that is playing: an A-B loop, bookmarks with names, a custom start and end, and seconds to skip at the start and end.
/// Everything is remembered for this song on this device. The window works on the live position, so the person plays, listens, and presses "here".
struct MusicTrackMarksSheet: View {
    let hub: MusicHub
    let close: () -> Void
    @State private var bookmarkName = ""
    @State private var introText = ""
    @State private var outroText = ""
    @Environment(\.reddyAccent) private var accent
    @State private var waveWidth: CGFloat = 400
    @State private var peaks: [Float]?
    @State private var peaksFor: String?
    @State private var chapters: [MusicChapter] = []

    private var player: MusicPlayer { hub.player }

    var body: some View {
        let m = player.currentMark
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Song navigation")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.marksClose")
            }
            if let t = player.current {
                Text(verbatim: t.title).font(MusicTokens.rowTitle).lineLimit(1)
                Text(verbatim: "\(MusicTrackMarkRules.clock(player.position)) / \(MusicTrackMarkRules.clock(player.duration))").font(Typography.timestamp).foregroundStyle(ColorTokens.textSecondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: MusicSpace.md) {
                        if let peaks { waveform(peaks, m) }
                        if !chapters.isEmpty { chapterList }
                        loop(m)
                        bounds(m)
                        skips(m)
                        bookmarks(m)
                    }
                }
            } else {
                Text(Localized.string("Play a song to set loops and bookmarks.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520)
        .task(id: player.current?.uid) { await loadPicture() }
        .onAppear { introText = m.skipIntro.map { String(Int($0)) } ?? ""; outroText = m.skipOutro.map { String(Int($0)) } ?? "" }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        MusicSheetCard { VStack(alignment: .leading, spacing: MusicSpace.sm) { Text(verbatim: title).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary); body() } }
    }

    private func at(_ v: Double?) -> String { v.map(MusicTrackMarkRules.clock) ?? "–" }

    private func loop(_ m: MusicTrackMark) -> some View {
        section(Localized.string("Loop a part")) {
            HStack(spacing: MusicSpace.sm) {
                Button { player.setLoopStart() } label: { Text(Localized.string("Start here (A)") + "  " + at(m.loopA)) }.musicButton(.secondary, size: .compact).atlas("control.music.marksLoopA")
                Button { player.setLoopEnd() } label: { Text(Localized.string("End here (B)") + "  " + at(m.loopB)) }.musicButton(.secondary, size: .compact).atlas("control.music.marksLoopB")
            }
            HStack(spacing: MusicSpace.sm) {
                Toggle(Localized.string("Repeat this part"), isOn: Binding(get: { m.loopOn && m.hasLoop }, set: { _ in player.toggleLoop() }))
                    .toggleStyle(.switch).disabled(!m.hasLoop).atlas("control.music.marksLoopToggle")
                Spacer()
                Button(Localized.string("Clear")) { player.clearLoop() }.buttonStyle(.plain).foregroundStyle(accent).disabled(m.loopA == nil && m.loopB == nil).atlas("control.music.marksLoopClear")
            }
        }
    }

    private func bounds(_ m: MusicTrackMark) -> some View {
        section(Localized.string("Play only a part of this song")) {
            HStack(spacing: MusicSpace.sm) {
                Button { player.setStartHere() } label: { Text(Localized.string("Start here") + "  " + at(m.start)) }.musicButton(.secondary, size: .compact).atlas("control.music.marksStart")
                Button { player.setEndHere() } label: { Text(Localized.string("Stop here") + "  " + at(m.end)) }.musicButton(.secondary, size: .compact).atlas("control.music.marksEnd")
            }
            Text(Localized.string("Next time this song plays it starts and stops there.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
        }
    }

    private func skips(_ m: MusicTrackMark) -> some View {
        section(Localized.string("Skip the intro and the outro")) {
            HStack(spacing: MusicSpace.sm) {
                TextField(Localized.string("Intro (seconds or 0:30)"), text: $introText).textFieldStyle(.roundedBorder).atlas("control.music.marksIntro")
                TextField(Localized.string("Outro (seconds or 0:30)"), text: $outroText).textFieldStyle(.roundedBorder).atlas("control.music.marksOutro")
                Button(Localized.string("Save")) {
                    player.setSkips(intro: MusicTrackMarkRules.parse(introText).flatMap { $0 > 0 ? $0 : nil }, outro: MusicTrackMarkRules.parse(outroText).flatMap { $0 > 0 ? $0 : nil })
                }.musicButton(.secondary, size: .compact).atlas("control.music.marksSkipSave")
            }
            HStack {
                Spacer()
                Button(Localized.string("Reset start, stop and skips")) { player.clearBounds(); introText = ""; outroText = "" }
                    .buttonStyle(.plain).foregroundStyle(accent).disabled(m.start == nil && m.end == nil && m.skipIntro == nil && m.skipOutro == nil).atlas("control.music.marksBoundsClear")
            }
        }
    }

    private func bookmarks(_ m: MusicTrackMark) -> some View {
        section(Localized.string("Bookmarks")) {
            HStack(spacing: MusicSpace.sm) {
                TextField(Localized.string("Name (optional)"), text: $bookmarkName).textFieldStyle(.roundedBorder).atlas("control.music.marksBookmarkName")
                Button { player.addBookmark(named: bookmarkName); bookmarkName = "" } label: { Label(Localized.string("Bookmark here"), systemImage: "bookmark") }
                    .musicButton(.secondary, size: .compact).atlas("control.music.marksBookmarkAdd")
            }
            if m.bookmarks.isEmpty {
                Text(Localized.string("No bookmarks yet.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            } else {
                HStack(spacing: MusicSpace.sm) {
                    Button { player.jumpToBookmark(forward: false) } label: { Image(systemName: "backward.end") }.musicButton(.glassIcon, size: .compact)
                        .accessibilityLabel(Localized.string("Previous bookmark")).atlas("control.music.marksBookmarkPrev")
                    Button { player.jumpToBookmark(forward: true) } label: { Image(systemName: "forward.end") }.musicButton(.glassIcon, size: .compact)
                        .accessibilityLabel(Localized.string("Next bookmark")).atlas("control.music.marksBookmarkNext")
                }
                ForEach(m.bookmarks) { b in
                    HStack {
                        Button { player.seek(to: b.at) } label: {
                            HStack { Text(verbatim: MusicTrackMarkRules.clock(b.at)).font(Typography.timestamp).foregroundStyle(accent); Text(verbatim: b.name).lineLimit(1); Spacer(minLength: 0) }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).atlas("control.music.marksBookmarkJump")
                        Button { player.removeBookmark(b.id) } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(ColorTokens.textTertiary) }
                            .buttonStyle(.plain).accessibilityLabel(Localized.string("Remove bookmark")).atlas("control.music.marksBookmarkRemove")
                    }
                }
            }
        }
    }

    // MARK: waveform and chapters

    private func localFile(_ t: MusicTrack) -> URL? {
        guard t.providerID == "local", let s = t.directStreams?.first?.url, let u = URL(string: s), u.isFileURL else { return nil }
        return u
    }

    private func loadPicture() async {
        peaks = nil; chapters = []
        guard let t = player.current, let file = localFile(t) else { return }
        chapters = MusicCueSheet.chapters(for: file)
        let uid = t.uid
        let result = await Task.detached(priority: .utility) { await MusicWaveform.peaks(of: file) }.value
        if player.current?.uid == uid { peaks = result; peaksFor = uid }
    }

    private func waveform(_ p: [Float], _ m: MusicTrackMark) -> some View {
        section(Localized.string("Waveform")) {
            let d = max(1, player.duration)
            Canvas { ctx, size in
                let w = size.width / CGFloat(p.count)
                for (i, v) in p.enumerated() {
                    let h = max(1.5, CGFloat(v) * size.height)
                    let r = CGRect(x: CGFloat(i) * w, y: (size.height - h) / 2, width: max(1, w - 1), height: h)
                    let played = Double(i) / Double(p.count) <= player.position / d
                    ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(played ? accent : accent.opacity(0.3)))
                }
                if m.hasLoop, let a = m.loopA, let b = m.loopB {
                    ctx.fill(Path(CGRect(x: size.width * a / d, y: 0, width: size.width * (b - a) / d, height: size.height)), with: .color(accent.opacity(0.14)))
                }
                for bm in m.bookmarks { ctx.fill(Path(CGRect(x: size.width * bm.at / d - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(ColorTokens.textPrimary.opacity(0.7))) }
            }
            .frame(height: 72)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                // The Canvas fills the card width; the tap position over that width is the place in the song.
                player.seek(to: d * Double(min(1, max(0, v.location.x / max(1, waveWidth)))))
            })
            .background(GeometryReader { g in Color.clear.onAppear { waveWidth = g.size.width }.onChange(of: g.size.width) { _, w in waveWidth = w } })
            .accessibilityLabel(Localized.string("Waveform. Tap to jump to a place in the song."))
            .accessibilityValue(Text(verbatim: "\(MusicTrackMarkRules.clock(player.position)) / \(MusicTrackMarkRules.clock(player.duration))"))
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: player.skip(listeningSeconds: MusicSeekPrefs.forwardSeconds())
                case .decrement: player.skip(listeningSeconds: -MusicSeekPrefs.backSeconds())
                @unknown default: break
                }
            }
            .atlas("control.music.marksWaveform")
            let s = MusicWaveform.silence(peaks: p, duration: d)
            if s.lead > 1 || s.trail > 1 {
                Button { player.setSkips(intro: s.lead > 1 ? s.lead : nil, outro: s.trail > 1 ? s.trail : nil); introText = s.lead > 1 ? String(Int(s.lead.rounded())) : ""; outroText = s.trail > 1 ? String(Int(s.trail.rounded())) : "" } label: {
                    Text(Localized.string("Skip the silence at the ends (%@ and %@)", MusicTrackMarkRules.clock(s.lead), MusicTrackMarkRules.clock(s.trail)))
                }.musicButton(.secondary, size: .compact).atlas("control.music.marksSkipSilence")
            }
        }
    }

    private var chapterList: some View {
        section(Localized.string("Chapters")) {
            ForEach(chapters) { c in
                let on = MusicCueSheet.current(chapters, at: player.position)?.number == c.number
                Button { player.seek(to: c.start) } label: {
                    HStack {
                        Text(verbatim: MusicTrackMarkRules.clock(c.start)).font(Typography.timestamp).foregroundStyle(on ? accent : ColorTokens.textTertiary)
                        Text(verbatim: c.performer.map { "\(c.title) · \($0)" } ?? c.title).font(on ? Typography.bodyMedium : Typography.body).lineLimit(1)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).atlas("control.music.marksChapter")
            }
        }
    }
}
