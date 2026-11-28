import SwiftUI
#if os(macOS)
import AppKit
#endif

// The animated lyrics panel. Rows fade and blur with distance from the line being sung, the active line sweeps word by word, the list
// glides to the next line a moment early, and a manual scroll pauses following for three seconds. Nothing animates while the song is
// paused, the app is in the background or the panel is off screen: the only frame loops are TimelineViews that are paused in those cases.

struct MusicLyricsView: View {
    enum Style { case panel, expanded }

    let player: MusicPlayer
    let lyrics: MusicLyrics
    let trackKey: String
    var style: Style = .panel
    var ink: Color = ColorTokens.textPrimary
    var showTranslation = true
    var showRomanisation = false
    /// On-device translation or reading shown under each line, when one is ready.
    var subLines: MusicLyricsSubLines? = nil
    /// Bumped by the toolbar to start picking lines for a share card.
    var pickRequest = 0
    var onSeek: ((TimeInterval) -> Void)? = nil
    /// True for a Listen Together guest: tapping a line does not seek, so it never moves the song out of step with the host.
    var seekLocked = false
    /// Called with the picked line indices when the person long-presses a line (pick mode) and chooses Share.
    var onShare: (([Int]) -> Void)? = nil

    @State private var model = MusicLyricsPanelModel()
    @State private var keeper = MusicLyricsTimeKeeper()
    @State private var appeared = false
    @State private var glideDistance: CGFloat = 0
    @State private var glideSettled = true
    @State private var glideFrom: Int?
    @State private var glideTarget = 0
    @State private var resumeTask: Task<Void, Never>?
    @AppStorage(MusicLyricsPrefs.blurKey) private var blurPref = true
    @AppStorage(MusicLyricsPrefs.textStepKey) private var textStep = 1
    @AppStorage(MusicLyricsPrefs.alignmentKey) private var alignRaw = 0
    /// The one offset for every song, from the lyrics service (the settings write it there).
    var globalOffsetMs: Int64 = 0
    private var globalOffset: Int { Int(globalOffsetMs) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var lines: [MusicLyricLine] { lyrics.synced ?? [] }
    private var wide: Bool { style == .expanded }
    /// The voice layout is computed once per set of lines, not once per realized row.
    @State private var layoutBox = MusicLyricsLayoutBox()
    private var layouts: [MusicLyricLineLayout]? {
        var h = Hasher()
        h.combine(trackKey); h.combine(lines.count); h.combine(lines.first?.timeMs); h.combine(lines.last?.timeMs)
        // A different source or a re-timed copy of the same song keeps the count and the ends: the sum of every time and the first and last text tell them apart.
        h.combine(lines.reduce(Int64(0)) { $0 &+ Int64($1.timeMs) }); h.combine(lines.first?.text); h.combine(lines.last?.text)
        let k = h.finalize()
        if layoutBox.key != k { layoutBox.key = k; layoutBox.value = MusicLyricsVoices.layout(lines) }
        return layoutBox.value
    }
    private var baseSize: Double { (wide ? 34.0 : 26.0) * MusicLyricsPrefs.textSteps[min(max(0, textStep), MusicLyricsPrefs.textSteps.count - 1)] }
    private var active: Bool { appeared && scenePhase == .active }
    private let spacing: CGFloat = 14
    private var anchorY: Double { wide ? 0.37 : 0.28 }

    private func look(for line: MusicLyricLine) -> MusicLyricsLook {
        MusicLyricsLook(ink: ink, fontSize: baseSize, wide: wide, glow: blurPref && !reduceMotion, reduceMotion: reduceMotion, rtl: MusicLyricsDirection.isRTL(line.text),
                       align: MusicLyricsAlignment(rawValue: alignRaw) ?? .automatic)
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: spacing) {
                            ForEach(lines.indices, id: \.self) { i in
                                row(i)
                                    .id(i)
                                    .background(GeometryReader { g in Color.clear.preference(key: MusicLyricsRowHeightKey.self, value: [i: g.size.height]) })
                            }
                        }
                        .padding(.horizontal, 10).padding(.top, wide ? geo.size.height * 0.37 : 40).padding(.bottom, geo.size.height * 0.6)
                    }
                    .scrollIndicators(.hidden)
                    .onPreferenceChange(MusicLyricsRowHeightKey.self) { model.rowHeights.merge($0) { _, new in new } }
                    .mask(edgeFade)
                    .modifier(MusicLyricsManualScroll { userScrolled() })
                    if !model.following, !model.pickMode, model.focus != nil {
                        Button { rejoin(proxy) } label: { Label("Jump to current", systemImage: "arrow.down.to.line").font(Typography.bodyMedium) }
                            .musicButton(.secondary, size: .compact).padding(.bottom, 8).accessibilityLabel("Jump to current line").atlas("control.music.lyricsJumpToCurrentLine")
                    }
                    if model.pickMode { pickBar }
                    if player.isPlaying, let note = player.audioState.holdNote {
                        // The line holds until sound is really coming out; the person is told why.
                        Text(verbatim: Localized.string(note)).font(Typography.caption).foregroundStyle(ink.opacity(0.8))
                            .padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 8)
                            .accessibilityLabel(Localized.string(note))
                    }
                    MusicLyricsDriver(player: player, keeper: keeper, model: model, lines: lines, active: active)
                        .frame(width: 0, height: 0).accessibilityHidden(true)
                }
                .onChange(of: model.following) { _, now in
                    // Following again (after a manual scroll, or after picking lines) brings the current line back into place at once, not at the next line change.
                    guard now, let f = model.focus, !model.pickMode else { return }
                    let anchor = UnitPoint(x: 0.5, y: anchorY)
                    if let a = MusicLyricsMotion.animationStyle(reduceMotion: reduceMotion) { withAnimation(a) { proxy.scrollTo(f, anchor: anchor) } } else { proxy.scrollTo(f, anchor: anchor) }
                }
                .onChange(of: model.focus) { old, new in
                    guard let new, model.following, !model.pickMode else { return }
                    follow(proxy, from: old, to: new, viewport: geo.size.height)
                }
                .onAppear {
                    appeared = true
                    model.viewportHeight = geo.size.height
                    keeper.songOffsetMs = lyrics.offsetMs
                    keeper.globalOffsetMs = MusicLyricsMotion.clampUIOffset(Int64(globalOffset))
                    keeper.feed(positionSeconds: player.position, playing: player.audioAdvancing, rate: player.tempo, discontinuity: true)
                    model.setPlaying(player.audioAdvancing)
                    let ms = keeper.lyricMs(at: Date())
                    model.apply(MusicLyricsPanelModel.snapshot(lines: lines, ms: ms), lines: lines, ms: ms)
                    if let f = model.focus { proxy.scrollTo(f, anchor: UnitPoint(x: 0.5, y: anchorY)); model.markPlaced() }
                }
                .onDisappear { appeared = false; resumeTask?.cancel() }
                .onChange(of: trackKey) { _, _ in
                    model.resetForTrack()
                    keeper.songOffsetMs = lyrics.offsetMs
                    keeper.feed(positionSeconds: player.position, playing: player.audioAdvancing, rate: player.tempo, discontinuity: true)   // the old song's predicted position must not light up the new lines
                }
                .onChange(of: lyrics.offsetMs) { _, new in
                    keeper.songOffsetMs = new
                    keeper.feed(positionSeconds: player.position, playing: player.audioAdvancing, rate: player.tempo, discontinuity: true)
                    model.nudge()
                }
                .onChange(of: globalOffset) { _, new in
                    keeper.globalOffsetMs = MusicLyricsMotion.clampUIOffset(Int64(new))
                    keeper.feed(positionSeconds: player.position, playing: player.audioAdvancing, rate: player.tempo, discontinuity: true)
                    model.nudge()
                }
                .onChange(of: pickRequest) { _, _ in if onShare != nil { model.pickMode = true; model.picked = [] } }
                .onChange(of: model.pickMode) { _, on in if on { model.following = false } else { model.picked = []; model.following = true; model.lastManualScroll = nil } }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Lyrics")
    }

    private var edgeFade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06), .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var pickBar: some View {
        HStack(spacing: 10) {
            Text(verbatim: model.cardFull ? Localized.string("Card is full") : Localized.string("%@ picked", String(model.picked.count))).font(Typography.caption).foregroundStyle(ink.opacity(0.8))
            Button("Share") { onShare?(model.picked.sorted()); model.pickMode = false }
                .musicButton(.primary).disabled(model.picked.isEmpty).accessibilityLabel("Share picked lines").atlas("control.music.lyricsSharePickedLines")
            Button("Cancel") { model.pickMode = false }.musicButton(.secondary).accessibilityLabel("Cancel picking lines").atlas("control.music.lyricsCancelPickingLines")
        }
        .padding(10).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 8)
    }

    // MARK: rows

    private func row(_ i: Int) -> some View {
        MusicLyricsRow(index: i, line: lines[i], layout: layouts?[i], model: model, keeper: keeper, look: look(for: lines[i]),
                       lines: lines, durationMs: player.duration > 0 ? Int64(player.duration * 1000) : nil,
                       showTranslation: showTranslation, showRomanisation: showRomanisation, subLines: subLines,
                       blurEnabled: blurPref && !reduceMotion, glideOffset: glideSettled ? 0 : glideDistance,
                       glideAnimation: glideAnimation(for: i),
                       onTap: { tapped(i) }, onLongPress: { if onShare != nil { model.pickMode = true; model.picked = []; model.togglePick(i, lines: lines) } })
    }

    private func glideAnimation(for i: Int) -> Animation? {
        guard !reduceMotion else { return nil }
        let forward = glideTarget >= (glideFrom ?? glideTarget)
        let behind = forward ? glideTarget - i : i - glideTarget
        let seconds = max(0.2, model.leadMs / 1000)
        let d = MusicLyricsMotion.rowDelay(rowsBehind: behind, duration: seconds)
        return MusicLyricsMotion.animationStyle(reduceMotion: false, duration: seconds)?.delay(d)
    }

    // MARK: following

    private func tapped(_ i: Int) {
        if model.pickMode { model.togglePick(i, lines: lines); return }
        if seekLocked { return }
        let ms = MusicLyricsMotion.seekTime(lineMs: lines[i].timeMs, songOffset: lyrics.offsetMs, globalOffset: keeper.globalOffsetMs)
        let seconds = TimeInterval(ms) / 1000
        if let onSeek { onSeek(seconds) } else { player.seek(to: seconds) }
        model.following = true; model.lastManualScroll = nil
        keeper.feed(positionSeconds: seconds, playing: player.audioAdvancing, rate: player.tempo, discontinuity: true)
    }

    private func userScrolled() {
        guard !model.pickMode else { return }
        model.manualScroll()
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(MusicLyricsMotion.manualPause * 1_000_000_000))
            guard !Task.isCancelled else { return }
            model.resumeIfDue()
        }
    }

    private func rejoin(_ proxy: ScrollViewProxy) {
        resumeTask?.cancel()
        model.following = true; model.lastManualScroll = nil
        guard let f = model.focus else { return }
        let anchor = UnitPoint(x: 0.5, y: anchorY)
        if let a = MusicLyricsMotion.animationStyle(reduceMotion: reduceMotion) { withAnimation(a) { proxy.scrollTo(f, anchor: anchor) } } else { proxy.scrollTo(f, anchor: anchor) }
    }

    /// The first placement on a track is instant. After that the list jumps at once and every row animates from its old position to zero,
    /// rows behind the target trailing by up to three steps.
    private func follow(_ proxy: ScrollViewProxy, from old: Int?, to new: Int, viewport: CGFloat) {
        let anchor = UnitPoint(x: 0.5, y: anchorY)
        guard model.firstPlacementDone, !reduceMotion, let old, old != new else {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { proxy.scrollTo(new, anchor: anchor) }
            model.markPlaced()
            return
        }
        let heights = model.rowHeights.mapValues { Double($0) }
        let estimate = heights.isEmpty ? 60 : heights.values.reduce(0, +) / Double(heights.count)
        let raw = MusicLyricsMotion.travel(heights: heights, spacing: Double(spacing), from: old, to: new, estimate: estimate)
        let capped = max(-Double(viewport), min(Double(viewport), raw))
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            glideFrom = old; glideTarget = new
            glideDistance = CGFloat(capped); glideSettled = false
            proxy.scrollTo(new, anchor: anchor)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            glideSettled = true
        }
    }
}

extension MusicLyricsMotion {
    /// The shared easing as a SwiftUI animation; nil when motion is reduced.
    static func animationStyle(reduceMotion: Bool, duration: Double = MusicLyricsMotion.duration) -> Animation? {
        reduceMotion ? nil : .timingCurve(bezier.x1, bezier.y1, bezier.x2, bezier.y2, duration: duration)
    }
}

struct MusicLyricsRowHeightKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue()) { _, new in new } }
}

// MARK: - clock driver

/// Feeds the clock from the player and publishes which rows are lit. The frame loop here is paused unless the song is playing and the panel is up.
private struct MusicLyricsDriver: View {
    let player: MusicPlayer
    let keeper: MusicLyricsTimeKeeper
    let model: MusicLyricsPanelModel
    let lines: [MusicLyricLine]
    let active: Bool

    var body: some View {
        let running = player.audioAdvancing && active
        MusicFrameClock(minimumInterval: 1.0 / 15, paused: !running) { ctx in
            MusicLyricsTick(date: ctx.date, keeper: keeper, model: model, lines: lines)
        }
        .onChange(of: player.position) { _, p in
            keeper.feed(positionSeconds: p, playing: player.audioAdvancing, rate: player.tempo)
            if !player.audioAdvancing { refreshStill() }
        }
        .onChange(of: player.audioAdvancing) { _, playing in
            keeper.feed(positionSeconds: player.position, playing: playing, rate: player.tempo, discontinuity: !playing)
            model.setPlaying(playing)
            refreshStill()
        }
        .onChange(of: player.tempo) { _, t in keeper.feed(positionSeconds: player.position, playing: player.audioAdvancing, rate: t) }
    }

    /// A seek while paused still moves the lit line.
    private func refreshStill() {
        let ms = keeper.lyricMs(at: Date())
        model.apply(MusicLyricsPanelModel.snapshot(lines: lines, ms: ms), lines: lines, ms: ms)
        model.nudge()
    }
}

private struct MusicLyricsTick: View {
    let date: Date
    let keeper: MusicLyricsTimeKeeper
    let model: MusicLyricsPanelModel
    let lines: [MusicLyricLine]

    var body: some View {
        let ms = keeper.lyricMs(at: date)
        let snap = MusicLyricsPanelModel.snapshot(lines: lines, ms: ms)
        Color.clear.frame(width: 0, height: 0).onChange(of: snap) { _, s in model.apply(s, lines: lines, ms: ms) }
    }
}

// MARK: - one row

private struct MusicLyricsRowEmphasis: Equatable {
    var alpha: Double
    var blur: Double
    var scale: Double
}

struct MusicLyricsRow: View {
    let index: Int
    let line: MusicLyricLine
    let layout: MusicLyricLineLayout?
    let model: MusicLyricsPanelModel
    let keeper: MusicLyricsTimeKeeper
    let look: MusicLyricsLook
    let lines: [MusicLyricLine]
    let durationMs: Int64?
    let showTranslation: Bool
    let showRomanisation: Bool
    let subLines: MusicLyricsSubLines?
    let blurEnabled: Bool
    let glideOffset: CGFloat
    let glideAnimation: Animation?
    let onTap: () -> Void
    let onLongPress: () -> Void

    private var far: Bool { look.align.isFar(duetFar: layout?.far ?? false) }
    private var centered: Bool { look.align.isCentered }
    private var hAlign: Alignment { centered ? .center : (far ? .trailing : .leading) }
    private var textAlign: TextAlignment { centered ? .center : (far ? .trailing : .leading) }
    private var isLit: Bool { model.lit.contains(index) }
    private var isLive: Bool { model.live.contains(index) }
    private var isPast: Bool { (model.focus ?? -1) > index }

    var body: some View {
        let d = model.lit.isEmpty ? abs(index - (model.focus ?? 0)) : (model.lit.map { abs($0 - index) }.min() ?? 0)
        let e = MusicLyricsRowEmphasis(
            alpha: model.browsing ? MusicLyricsMotion.browsingAlpha : MusicLyricsMotion.alpha(distance: d, wide: look.wide),
            blur: (blurEnabled && !model.browsing) ? MusicLyricsMotion.blur(distance: d) : 0,
            scale: isLit ? 1 : MusicLyricsMotion.inactiveScale)
        let anchor: UnitPoint = centered ? .center : (far ? .trailing : .leading)
        Button(action: onTap) { content }
            .buttonStyle(MusicLyricsRowButtonStyle(anchor: anchor))
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in onLongPress() })
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: hAlign)
            .background(pickTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(e.alpha).blur(radius: e.blur).scaleEffect(e.scale, anchor: anchor)
            .animation(look.animation, value: e)
            .offset(y: glideOffset)
            .animation(glideAnimation, value: glideOffset == 0)
            .accessibilityLabel(line.text.isEmpty ? Localized.string("Instrumental") : line.text)
            .accessibilityAddTraits(isLit ? .isSelected : []).atlas("control.music.lyricsMusiclyricsrowbodyButton")
    }

    private var pickTint: Color {
        guard model.pickMode else { return .clear }
        return look.ink.opacity(model.picked.contains(index) ? 0.16 : 0.05)
    }

    @ViewBuilder
    private var content: some View {
        if let br = MusicLyricsMotion.interlude(lines: lines, index: index, trackEndMs: durationMs) {
            MusicLyricsInterludeRow(start: br.start, end: br.end, live: isLive, keeper: keeper, model: model, ink: look.ink)
        } else {
            VStack(alignment: centered ? .center : (far ? .trailing : .leading), spacing: 4) {
                lead
                backing
                subLine
            }
            .environment(\.layoutDirection, look.rtl ? .rightToLeft : .leftToRight)
        }
    }

    private var leadWords: [MusicLyricWord] {
        if let l = layout?.lead, !l.isEmpty { return l }
        return (line.words ?? []).filter { !$0.background }
    }

    @ViewBuilder
    private var lead: some View {
        let words = leadWords
        if words.isEmpty {
            // Line-timed: the whole line lights at its stamp.
            Text(verbatim: line.text).font(look.font).multilineTextAlignment(textAlign)
                .foregroundStyle(look.ink.opacity(isLit || isPast ? 1 : MusicLyricsMotion.unsungAlpha))
                .animation(look.animation, value: isLit || isPast)
                .frame(maxWidth: .infinity, alignment: hAlign)
        } else if isLive {
            MusicLyricsLiveLine(words: words, keeper: keeper, model: model, look: look, trailing: far)
        } else {
            MusicLyricsFlowLayout(rowSpacing: look.lineAdvance - look.fontSize * 1.2, trailing: far, mirrored: look.rtl, centered: centered) {
                ForEach(words.indices, id: \.self) { w in Text(verbatim: words[w].text).font(look.font).foregroundStyle(look.ink) }
            }
        }
    }

    @ViewBuilder
    private var backing: some View {
        let bg = layout?.background ?? []
        if !bg.isEmpty, isLive {
            MusicLyricsBackingLine(words: bg, keeper: keeper, model: model, look: look, trailing: far)
        }
    }

    @ViewBuilder
    private var subLine: some View {
        let sub = subLines.flatMap { $0.display(for: index, original: line.text)?.text }.flatMap { $0.isEmpty ? nil : $0 } ?? MusicLyricsRow.subText(line: line, showTranslation: showTranslation, showRomanisation: showRomanisation)
        if let sub {
            Text(verbatim: sub).font(look.subFont).foregroundStyle(look.ink.opacity(0.85)).multilineTextAlignment(textAlign)
                .padding(.top, 2).transition(.opacity.combined(with: .offset(y: -6)))
        }
    }

    /// Romanisation wins over translation when both are on, one sub-line at a time.
    static func subText(line: MusicLyricLine, showTranslation: Bool, showRomanisation: Bool) -> String? {
        if showRomanisation, MusicLyricsMotion.showsSubLine(line.romanized, original: line.text) { return line.romanized }
        if showTranslation, MusicLyricsMotion.showsSubLine(line.translation, original: line.text) { return line.translation }
        return nil
    }
}

private struct MusicLyricsRowButtonStyle: ButtonStyle {
    let anchor: UnitPoint
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? MusicLyricsMotion.pressedScale : 1, anchor: anchor)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed).contentShape(Rectangle())
    }
}

/// Holds the last voice layout so scrolling does not recompute it for every row.
final class MusicLyricsLayoutBox {
    var key: Int?
    var value: [MusicLyricLineLayout]?
}

/// The word line of the active row. Its frame loop runs only while playing.
struct MusicLyricsLiveLine: View {
    let words: [MusicLyricWord]
    let keeper: MusicLyricsTimeKeeper
    let model: MusicLyricsPanelModel
    let look: MusicLyricsLook
    var trailing = false

    var body: some View {
        let _ = model.tick
        MusicFrameClock(minimumInterval: MusicLyricsPanelModel.rowFrameInterval, paused: !model.isPlaying) { ctx in
            let ms = keeper.lyricMs(at: ctx.date)
            MusicLyricsFlowLayout(rowSpacing: look.lineAdvance - look.fontSize * 1.2, trailing: trailing, mirrored: look.rtl, centered: look.align.isCentered) {
                ForEach(words.indices, id: \.self) { i in MusicLyricsWordView(word: words[i], ms: ms, look: look) }
            }
        }
    }
}

/// Background vocals: a smaller line that opens a quarter second before its first word and closes after its last.
struct MusicLyricsBackingLine: View {
    let words: [MusicLyricWord]
    let keeper: MusicLyricsTimeKeeper
    let model: MusicLyricsPanelModel
    let look: MusicLyricsLook
    var trailing = false

    var body: some View {
        let _ = model.tick
        MusicFrameClock(minimumInterval: MusicLyricsPanelModel.rowFrameInterval, paused: !model.isPlaying) { ctx in
            let ms = keeper.lyricMs(at: ctx.date)
            let open = Self.isOpen(words: words, at: ms)
            Group {
                if open {
                    MusicLyricsFlowLayout(rowSpacing: 2, trailing: trailing, mirrored: look.rtl, centered: look.align.isCentered) {
                        ForEach(words.indices, id: \.self) { i in
                            MusicLyricsSweepText(text: Self.stripBrackets(words[i].text), progress: MusicLyricsMotion.wordProgress(words[i], at: ms), look: look, font: look.backFont)
                        }
                    }
                    .opacity(0.72)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: trailing ? .trailing : .leading)).combined(with: .offset(y: 6)))
                }
            }
            .animation(look.animation, value: open)
        }
    }

    static func isOpen(words: [MusicLyricWord], at ms: Int64) -> Bool {
        guard let start = words.map(\.startMs).min(), let end = words.map(\.endMs).max() else { return false }
        return ms >= start - 250 && ms < end
    }

    static func stripBrackets(_ s: String) -> String { s.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "") }
}

/// A break between lines: three dots that fill across the silence. Reads the clock only while the break runs.
private struct MusicLyricsInterludeRow: View {
    let start: Int64
    let end: Int64
    let live: Bool
    let keeper: MusicLyricsTimeKeeper
    let model: MusicLyricsPanelModel
    let ink: Color

    var body: some View {
        let _ = model.tick
        MusicFrameClock(minimumInterval: MusicLyricsPanelModel.rowFrameInterval, paused: !(live && model.isPlaying)) { ctx in
            let ms = keeper.lyricMs(at: ctx.date)
            MusicLyricsInterludeDots(progress: MusicLyricsMotion.breakProgress(start: start, end: end, at: ms), ink: ink)
        }
    }
}

// MARK: - manual scroll detection

private struct MusicLyricsManualScroll: ViewModifier {
    let onUserScroll: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content.background(MusicLyricsWheelWatcher(onScroll: onUserScroll))
            .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in onUserScroll() })
        #else
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, new in if new == .interacting || new == .decelerating { onUserScroll() } }
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in onUserScroll() })
        }
        #endif
    }
}

#if os(macOS)
/// Wheel and trackpad scrolling over this view counts as the person moving the list; our own scrollTo calls never produce wheel events.
private struct MusicLyricsWheelWatcher: NSViewRepresentable {
    let onScroll: () -> Void

    func makeNSView(context: Context) -> WatcherView { let v = WatcherView(); v.onScroll = onScroll; return v }
    func updateNSView(_ v: WatcherView, context: Context) { v.onScroll = onScroll }

    final class WatcherView: NSView {
        var onScroll: (() -> Void)?
        private nonisolated(unsafe) var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window, event.scrollingDeltaY != 0 || event.scrollingDeltaX != 0 else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(p) { self.onScroll?() }
                return event
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif

extension MusicLyricsPanelModel {
    /// The live, backing and interlude rows redraw at most 30 times a second (the lyric clock itself is read per frame, not per display refresh).
    static let rowFrameInterval: Double = 1.0 / 30
}
