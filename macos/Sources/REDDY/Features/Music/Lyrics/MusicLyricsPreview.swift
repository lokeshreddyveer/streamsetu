import SwiftUI

// A live lyrics preview for the lower part of the Now Playing tab. It shows a few lines around the line being sung (or the first lines of
// plain lyrics, a short note, or the miss state) and a footer that opens the Lyrics tab. The synced window follows the lyric clock the
// full view uses (`MusicLyricsTimeKeeper`, fed by the player's readings, redrawn by one `MusicFrameClock` that pauses with playback).
// The body of the preview reads only a derived cursor (line index and gap flag), never `player.position`.

// MARK: - Pure logic

enum MusicLyricsPreviewLogic {
    /// The preview is shown only when it can have at least this much height.
    static let minimumHeight: CGFloat = 160
    static let minLines = 5
    static let maxLines = 9
    /// A line is looked up this long before it starts so the glide ends on time.
    static let leadMs: Int64 = 200
    /// A quiet stretch longer than this after a line has ended shows the dots.
    static let gapAfterMs: Int64 = 2500
    /// ...unless the next line is about to start.
    static let gapBeforeNextMs: Int64 = 1500
    /// The song's opening is a gap when the first line starts later than this.
    static let introGapMs: Int64 = 4000
    static let rowHeightEstimate: CGFloat = 32

    /// The height the preview may take: what the panel has left under the details, or nil when that is under the minimum.
    static func previewHeight(panelHeight: CGFloat, detailsHeight: CGFloat, verticalPadding: CGFloat, gap: CGFloat) -> CGFloat? {
        guard panelHeight.isFinite, detailsHeight.isFinite, detailsHeight > 0 else { return nil }
        let room = panelHeight - detailsHeight - verticalPadding * 2 - gap
        return room >= minimumHeight ? room : nil
    }

    /// The preview is not shown when there is no room, or when the panel is already on the Lyrics tab.
    static func isVisible(availableHeight: CGFloat?, lyricsTabShowing: Bool) -> Bool {
        guard let availableHeight, !lyricsTabShowing else { return false }
        return availableHeight >= minimumHeight
    }

    /// How many lines the block shows for its height: odd, from 5 to 9, so the active line sits in the middle.
    static func lineCount(forHeight height: CGFloat, footer: CGFloat) -> Int {
        guard height.isFinite else { return minLines }
        let body = max(0, height - footer)
        var n = Int(body / rowHeightEstimate)
        n = max(minLines, min(maxLines, n))
        return n % 2 == 0 ? n - 1 : n
    }

    /// The lines inside the window around `active`, clamped at both ends of the song.
    static func window(count: Int, active: Int?, size: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let a = min(count - 1, max(0, active ?? 0))
        let half = max(0, size / 2)
        return max(0, a - half)..<min(count, a + half + 1)
    }

    /// Where the song is: the line being sung and whether the stretch is an instrumental gap.
    struct Cursor: Equatable, Sendable {
        var index: Int?
        var gap: Bool
        static let start = Cursor(index: nil, gap: false)

        /// The row the window is centred on: the active line, or the upcoming one in a gap.
        func anchor(count: Int) -> Int {
            guard count > 0 else { return 0 }
            if gap { return min(count - 1, (index ?? -1) + 1) }
            return min(count - 1, max(0, index ?? 0))
        }
        func isActive(_ i: Int) -> Bool { !gap && index == i }
    }

    static func cursor(lines: [MusicLyricLine], ms: Int64) -> Cursor {
        guard let first = lines.first else { return .start }
        let at = ms + leadMs
        guard let i = MusicLyricsLookup.lineIndex(in: lines, at: at) else { return Cursor(index: nil, gap: first.timeMs - at > introGapMs) }
        let line = lines[i]
        if line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Cursor(index: i, gap: true) }
        let nextStart = i + 1 < lines.count ? lines[i + 1].timeMs : nil
        if let end = MusicLyricsMotion.knownEnd(line), at - end >= gapAfterMs, nextStart.map({ $0 - at > gapBeforeNextMs }) ?? true {
            return Cursor(index: i, gap: true)
        }
        return Cursor(index: i, gap: false)
    }

    /// 0 for the active line, then 1, 2, 3...: how far a row sits from the anchor (a non-active anchor counts as 1).
    static func level(row: Int, cursor: Cursor, count: Int) -> Int {
        if cursor.isActive(row) { return 0 }
        return max(1, abs(row - cursor.anchor(count: count)))
    }

    /// Opacity of a row by level; rows beyond the window are hidden. Increase Contrast lifts the dim rows.
    static func opacity(level: Int, half: Int, increaseContrast: Bool) -> Double {
        if level > half { return 0 }
        let steps: [Double] = [1, 0.7, 0.52, 0.42, 0.34]
        let base = steps[min(level, steps.count - 1)]
        return level == 0 ? 1 : min(1, increaseContrast ? base + 0.25 : base)
    }

    // MARK: states

    enum Mode: Equatable {
        case loading, synced, plain, instrumental
        case miss(MusicLyricsMiss)
    }

    /// What the preview draws for the lyrics service's state. A lookup that never ends (`timedOut`) reads as offline, never as a skeleton.
    static func mode(for state: MusicLyricsLoadState, timedOut: Bool) -> Mode {
        switch state {
        case .idle, .loading: return timedOut ? .miss(.offline) : .loading
        case .none(let m): return .miss(m)
        case .found(let l):
            if l.instrumental { return .instrumental }
            if let s = l.synced, !s.isEmpty { return .synced }
            if let p = l.plain, !plainLines(p, limit: 1).isEmpty { return .plain }
            return .miss(.notFound)
        }
    }

    /// The first lines of plain lyrics: blank lines and [Section] labels dropped.
    static func plainLines(_ text: String, limit: Int) -> [String] {
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || (t.hasPrefix("[") && t.hasSuffix("]")) { continue }
            out.append(t)
            if out.count >= limit { break }
        }
        return out
    }

    /// The text of a sub line (translation or romanisation) for row `i`, when there is one.
    static func subText(_ sub: MusicLyricsSubLines?, index: Int, original: String) -> String? {
        guard let s = sub?.display(for: index, original: original), !s.text.isEmpty else { return nil }
        return s.text
    }
}

// MARK: - The block

struct MusicLyricsPreview: View {
    let hub: MusicHub
    /// The panel state of the shell this preview lives in (the app's shared one unless a host brings its own).
    var panelState: MusicContextPanelState = .shared
    @State private var timedOut = false

    var body: some View {
        if let t = hub.player.current {
            let state = hub.lyrics.loadState(for: t)
            let mode = MusicLyricsPreviewLogic.mode(for: state, timedOut: timedOut)
            GeometryReader { geo in
                VStack(spacing: MusicSpace.xs) {
                    main(mode: mode, state: state, track: t, height: geo.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let l = foundLyrics(state), mode == .synced || mode == .plain { footer(l) }
                }
            }
            .task(id: "\(t.uid)#\(hub.lyrics.epoch)") { await load(t) }
            .accessibilityElement(children: .contain).accessibilityLabel(Localized.string("Lyrics preview"))
        }
    }

    private func foundLyrics(_ s: MusicLyricsLoadState) -> MusicLyrics? { if case .found(let l) = s { return l }; return nil }

    /// Asks the service once per track (it joins a lookup that is already running) and never leaves the skeleton up past the service's own cap.
    private func load(_ t: MusicTrack) async {
        timedOut = false
        hub.lyrics.ensureLoaded(t)
        let wait = hub.lyrics.timing.overall + 3
        try? await Task.sleep(nanoseconds: UInt64(max(1, wait) * 1_000_000_000))
        guard !Task.isCancelled else { return }
        if !hub.lyrics.loadState(for: t).isTerminal { timedOut = true }
    }

    @ViewBuilder private func main(mode: MusicLyricsPreviewLogic.Mode, state: MusicLyricsLoadState, track t: MusicTrack, height: CGFloat) -> some View {
        switch mode {
        case .loading:
            MusicLyricsPreviewSkeleton()
        case .instrumental:
            note(Localized.string("Instrumental"), symbol: "music.note")
        case .miss(let miss):
            missView(miss, track: t)
        case .plain:
            if let l = foundLyrics(state) {
                MusicLyricsPreviewPlain(lines: MusicLyricsPreviewLogic.plainLines(l.plain ?? "", limit: MusicLyricsPreviewLogic.maxLines))
            }
        case .synced:
            if let l = foundLyrics(state) {
                MusicLyricsPreviewSynced(hub: hub, lyrics: l, count: MusicLyricsPreviewLogic.lineCount(forHeight: height, footer: MusicTokens.hitTarget + MusicSpace.xs))
                    .id(t.uid)
            }
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        VStack(spacing: MusicSpace.xs) {
            Image(systemName: symbol).font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
            Text(verbatim: text).font(MusicTypeRole.secondary.font).foregroundStyle(ColorTokens.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func missView(_ miss: MusicLyricsMiss, track t: MusicTrack) -> some View {
        let text: String
        switch miss {
        case .notFound: text = "No lyrics found"
        case .mix: text = "Lyrics are not available for a mix"
        case .offline: text = "Could not reach the lyric sources."
        }
        return VStack(spacing: MusicSpace.xxs) {
            Text(verbatim: Localized.string(text)).font(MusicTypeRole.secondary.font).foregroundStyle(ColorTokens.textSecondary).multilineTextAlignment(.center)
            HStack(spacing: MusicSpace.xs) {
                if miss == .notFound {
                    Button(Localized.string("Find lyrics")) { MusicLyricsFindRequest.shared.raise(); panelState.select(.lyrics) }
                        .musicButton(.tertiary, size: .compact).accessibilityLabel("Find lyrics for this track").atlas("control.music.musicFindLyricsForThisTrack")
                }
                if miss != .mix {
                    Button(Localized.string("Search again")) { hub.translation.reset(); hub.lyrics.searchAgain(t) }
                        .musicButton(.tertiary, size: .compact).atlas("control.music.lyricsSearchAgain")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(_ l: MusicLyrics) -> some View {
        HStack(spacing: MusicSpace.xs) {
            Spacer(minLength: 0)
            Button(Localized.string("Full lyrics")) { panelState.select(.lyrics) }
                .musicButton(.tertiary, size: .compact).atlas("control.music.lyricsPreviewFull")
        }
        .frame(minHeight: MusicTokens.hitTarget)
    }
}

// MARK: - Skeleton and plain

private struct MusicLyricsPreviewSkeleton: View {
    private static let widths: [Double] = [0.9, 0.62, 0.78, 0.5]

    var body: some View {
        GeometryReader { g in
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                ForEach(Self.widths.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: MusicCorner.control).fill(ColorTokens.elevated)
                        .frame(width: g.size.width * Self.widths[i], height: MusicSpace.sm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(Localized.string("Getting the lyrics"))
    }
}

private struct MusicLyricsPreviewPlain: View {
    let lines: [String]
    @Environment(\.musicA11y) private var a11y

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            ForEach(lines.indices, id: \.self) { i in
                Text(verbatim: lines[i]).font(MusicTypeRole.body.font).foregroundStyle(ColorTokens.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: MusicLyricsDirection.isRTL(lines[i]) ? .trailing : .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .mask(a11y.reduceTransparency ? AnyView(Rectangle()) : AnyView(MusicLyricsPreviewFade(top: false)))
    }
}

/// A soft edge fade drawn as a mask (only alpha matters).
private struct MusicLyricsPreviewFade: View {
    var top = true
    var body: some View {
        LinearGradient(stops: [.init(color: top ? .clear : ColorTokens.textPrimary, location: 0), .init(color: ColorTokens.textPrimary, location: 0.2),
                               .init(color: ColorTokens.textPrimary, location: 0.7), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Synced window

private struct MusicLyricsPreviewSynced: View {
    let hub: MusicHub
    let lyrics: MusicLyrics
    /// Lines shown (5 to 9, odd).
    let count: Int
    @State private var cursor = MusicLyricsPreviewLogic.Cursor.start
    @State private var seekBump = 0
    @Environment(\.musicA11y) private var a11y

    private var lines: [MusicLyricLine] { lyrics.synced ?? [] }
    private var half: Int { count / 2 }
    private var settings: MusicSettings { hub.library.settings }
    private var subLines: MusicLyricsSubLines? {
        if settings.showRomanisation, let s = hub.translation.romanization.subLines { return s }
        if settings.showTranslation, let s = hub.translation.translation.subLines { return s }
        return nil
    }

    var body: some View {
        let sub = subLines
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: MusicSpace.xs) {
                        ForEach(lines.indices, id: \.self) { i in row(i, sub: sub).id(i) }
                    }
                    .padding(.vertical, geo.size.height / 2)
                }
                .scrollDisabled(true).scrollIndicators(.hidden)
                .overlay(alignment: .top) { if cursor.gap { dots.position(x: geo.size.width / 2, y: geo.size.height * 0.3) } }
                .mask(a11y.reduceTransparency ? AnyView(Rectangle()) : AnyView(MusicLyricsPreviewFade()))
                .musicRoomLocked(hub.room.controlsLocked)
                .onChange(of: cursor) { _, _ in scroll(proxy, animated: true) }
                .onAppear { scroll(proxy, animated: false) }
            }
        }
        .background(driver)
        .clipped()
    }

    private var driver: some View {
        MusicLyricsPreviewDriver(player: hub.player, lines: lines, songOffsetMs: lyrics.offsetMs,
                                 globalOffsetMs: MusicLyricsMotion.clampUIOffset(hub.lyrics.globalOffsetMs), seekBump: seekBump, cursor: $cursor)
    }

    private var dots: some View {
        HStack(spacing: MusicSpace.xxs) {
            ForEach(0..<3, id: \.self) { _ in Circle().fill(ColorTokens.textTertiary).frame(width: MusicSpace.xxs + 1, height: MusicSpace.xxs + 1) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(Localized.string("Instrumental break"))
    }

    private func row(_ i: Int, sub: MusicLyricsSubLines?) -> some View {
        let line = lines[i]
        let level = MusicLyricsPreviewLogic.level(row: i, cursor: cursor, count: lines.count)
        let active = cursor.isActive(i)
        return Button { seek(i) } label: {
            MusicLyricsPreviewRow(text: line.text, sub: MusicLyricsPreviewLogic.subText(sub, index: i, original: line.text), level: level,
                                  opacity: MusicLyricsPreviewLogic.opacity(level: level, half: half, increaseContrast: a11y.increaseContrast),
                                  rtl: MusicLyricsDirection.isRTL(line.text))
                .equatable()
        }
        .buttonStyle(.plain)
        .musicLyricLine(line.text, startSeconds: Double(line.timeMs) / 1000, isActive: active) { seek(i) }
        .atlas("control.music.lyricsPreviewLine")
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !lines.isEmpty else { return }
        let target = cursor.anchor(count: lines.count)
        let point = UnitPoint(x: 0.5, y: cursor.gap ? 0.66 : 0.5)
        if animated, let a = MusicMotion.animation(.listChange, reduce: a11y.reduceMotion) {
            withAnimation(a) { proxy.scrollTo(target, anchor: point) }
        } else {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { proxy.scrollTo(target, anchor: point) }
        }
    }

    private func seek(_ i: Int) {
        // A Listen Together guest follows the host: tapping a line must not move this device out of step (the other lyric views have the same guard).
        guard !hub.room.controlsLocked, lines.indices.contains(i) else { return }
        let ms = MusicLyricsMotion.seekTime(lineMs: lines[i].timeMs, songOffset: lyrics.offsetMs, globalOffset: hub.lyrics.globalOffsetMs)
        hub.player.seek(to: TimeInterval(ms) / 1000)
        seekBump += 1
    }
}

private struct MusicLyricsPreviewRow: View, Equatable {
    let text: String
    let sub: String?
    let level: Int
    let opacity: Double
    let rtl: Bool

    var body: some View {
        let active = level == 0
        VStack(alignment: rtl ? .trailing : .leading, spacing: MusicSpace.xxs / 2) {
            Text(verbatim: text.trimmingCharacters(in: .whitespaces).isEmpty ? "\u{266A}" : text)
                .font(active ? MusicTypeRole.section.font : MusicTypeRole.secondary.font).fontWeight(active ? .semibold : .regular)
                .foregroundStyle(active ? ColorTokens.textPrimary : ColorTokens.textSecondary)
                .multilineTextAlignment(rtl ? .trailing : .leading)
                .lineLimit(active ? 4 : 2).fixedSize(horizontal: false, vertical: true)
            if let sub {
                Text(verbatim: sub).font(MusicTypeRole.caption.font).foregroundStyle(ColorTokens.textTertiary)
                    .multilineTextAlignment(rtl ? .trailing : .leading).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
        .padding(.vertical, MusicSpace.xxs / 2)
        .opacity(opacity)
        .contentShape(Rectangle())
    }
}

// MARK: - Following the song

/// Feeds the shared lyric clock from the player and publishes the cursor only when the line (or the gap flag) changes. It is the only view
/// here that reads the player's position; it draws nothing.
private struct MusicLyricsPreviewDriver: View {
    let player: MusicPlayer
    let lines: [MusicLyricLine]
    let songOffsetMs: Int64
    let globalOffsetMs: Int64
    let seekBump: Int
    @Binding var cursor: MusicLyricsPreviewLogic.Cursor
    @State private var keeper = MusicLyricsTimeKeeper()

    var body: some View {
        MusicFrameClock(minimumInterval: 1.0 / 6, paused: !player.audioAdvancing) { ctx in
            MusicLyricsPreviewTick(date: ctx.date, keeper: keeper, lines: lines, cursor: $cursor)
        }
        .frame(width: 0, height: 0).accessibilityHidden(true)
        .onAppear {
            configure()
            keeper.feed(positionSeconds: player.position, playing: player.audioAdvancing, rate: player.tempo, discontinuity: true)
            refresh()
        }
        .onChange(of: player.position) { _, p in
            keeper.feed(positionSeconds: p, playing: player.audioAdvancing, rate: player.tempo)
            if !player.audioAdvancing { refresh() }
        }
        .onChange(of: player.audioAdvancing) { _, playing in
            keeper.feed(positionSeconds: player.position, playing: playing, rate: player.tempo, discontinuity: !playing)
            refresh()
        }
        .onChange(of: player.tempo) { _, t in keeper.feed(positionSeconds: player.position, playing: player.audioAdvancing, rate: t) }
        .onChange(of: seekBump) { _, _ in
            keeper.feed(positionSeconds: player.position, playing: player.audioAdvancing, rate: player.tempo, discontinuity: true)
            refresh()
        }
        .onChange(of: songOffsetMs) { _, _ in reconfigure() }
        .onChange(of: globalOffsetMs) { _, _ in reconfigure() }
    }

    private func configure() {
        keeper.songOffsetMs = songOffsetMs
        keeper.globalOffsetMs = globalOffsetMs
    }

    private func reconfigure() {
        configure()
        keeper.feed(positionSeconds: player.position, playing: player.audioAdvancing, rate: player.tempo, discontinuity: true)
        refresh()
    }

    private func refresh() {
        let c = MusicLyricsPreviewLogic.cursor(lines: lines, ms: keeper.lyricMs(at: Date()))
        if c != cursor { cursor = c }
    }
}

private struct MusicLyricsPreviewTick: View {
    let date: Date
    let keeper: MusicLyricsTimeKeeper
    let lines: [MusicLyricLine]
    @Binding var cursor: MusicLyricsPreviewLogic.Cursor

    var body: some View {
        let c = MusicLyricsPreviewLogic.cursor(lines: lines, ms: keeper.lyricMs(at: date))
        Color.clear.frame(width: 0, height: 0).onChange(of: c) { _, new in if new != cursor { cursor = new } }
    }
}
