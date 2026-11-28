import SwiftUI
#if os(macOS)
import AppKit
#endif

// Small views for the player: a marquee for long titles, the wavy seek bar, the scroll-wheel volume gesture and page zoom. Nothing here
// runs while idle: the marquee and the wave only draw while something is playing and the view is on screen, and not at all with Reduce Motion.

// MARK: marquee

/// One line of text that scrolls sideways when it does not fit. It rests first, scrolls a pass, rests again and stops after a few passes
/// (`MusicMarqueeSchedule`). While paused, off screen, finished or with Reduce Motion on it is a plain truncated line with the full text as its tooltip.
struct MusicMarquee: View {
    let text: String
    var font: Font = Typography.bodyMedium
    var playing: Bool
    /// Size to the text up to the offered width instead of filling it (the player bar's title, so the heart can follow it).
    var hugging = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var onScreen = false
    @State private var startedAt = Date()
    @State private var finished = false

    private var overflowing: Bool { MusicMarqueeMath.overflows(textWidth: textWidth, boxWidth: boxWidth) }
    private var running: Bool { !finished && MusicMarqueeMath.shouldRun(overflowing: overflowing, playing: playing, onScreen: onScreen, reduceMotion: reduceMotion) }

    var body: some View {
        Group {
            if running {
                MusicFrameClock(minimumInterval: 1.0 / 30) { tl in
                    let dx = MusicMarqueeSchedule.offset(elapsed: tl.date.timeIntervalSince(startedAt), textWidth: textWidth)
                    HStack(spacing: MusicMarqueeMath.gap) {
                        Text(verbatim: text).font(font).fixedSize()
                        Text(verbatim: text).font(font).fixedSize()
                    }
                    .offset(x: dx)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .clipped()
            } else {
                Text(verbatim: text).font(font).lineLimit(1).truncationMode(.tail).frame(maxWidth: hugging ? nil : .infinity, alignment: .leading)
            }
        }
        // The natural width of the text is measured once from a hidden copy; the box width comes from the visible container.
        .background(alignment: .leading) {
            Text(verbatim: text).font(font).fixedSize().hidden()
                .background(GeometryReader { g in Color.clear.onAppear { textWidth = g.size.width }.onChange(of: g.size.width) { _, w in textWidth = w } })
        }
        .background(GeometryReader { g in Color.clear.onAppear { boxWidth = g.size.width }.onChange(of: g.size.width) { _, w in boxWidth = w } })
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: running) { _, now in if now { startedAt = Date() } }
        .onChange(of: text) { _, _ in startedAt = Date(); finished = false }
        // After the last pass the clock stops: the title rests as a truncated line until the track changes.
        .task(id: text + (overflowing ? "1" : "0") + (playing ? "1" : "0")) {
            finished = false
            guard overflowing, playing else { return }
            try? await Task.sleep(for: .seconds(MusicMarqueeSchedule.totalDuration(textWidth: textWidth) + 0.2))
            if !Task.isCancelled { finished = true }
        }
        .musicTooltip(verbatim: overflowing ? text : "")
        .accessibilityElement().accessibilityLabel(text)
    }
}

// MARK: wavy seek bar

/// The seek bar drawn as a wave behind the played part. The wave grows when playback starts and flattens when it stops; paused, it is a
/// plain line and nothing redraws. Dragging holds a local value and the seek is sent on release.
struct MusicWavySeekBar: View {
    var fraction: Double
    var playing: Bool
    /// Called while a drag or a key moves the thumb (so the labels can follow it); `onChange` is the committed value.
    var onScrub: ((Double) -> Void)?
    var onChange: (Double) -> Void

    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging: Double?
    @State private var changedAt = Date()
    @State private var ampAtChange: CGFloat = 0
    @State private var settled = true
    @State private var onScreen = false
    @State private var origin = Date()

    private var wavy: Bool { playing && !reduceMotion }

    var body: some View {
        GeometryReader { g in
            let size = g.size
            MusicFrameClock(minimumInterval: MusicWaveMath.steadyInterval, paused: !(onScreen && (wavy || !settled))) { tl in
                Canvas { ctx, sz in
                    draw(&ctx, sz, now: tl.date)
                }
                .frame(width: size.width, height: size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in let r = min(1, max(0, v.location.x / max(1, size.width))); dragging = r; onScrub?(r) }
                .onEnded { v in let r = min(1, max(0, v.location.x / max(1, size.width))); dragging = nil; onChange(r) })
        }
        .onAppear { onScreen = true; ampAtChange = wavy ? MusicWaveMath.maxAmplitude : 0 }
        .onDisappear { onScreen = false }
        .onChange(of: wavy) { _, now in
            ampAtChange = currentAmplitude(at: Date())
            changedAt = Date(); settled = false
            if now { origin = Date() }
        }
        .task(id: wavy) {
            try? await Task.sleep(nanoseconds: UInt64((MusicWaveMath.easeSeconds + 0.1) * 1_000_000_000))
            settled = true
        }
        .focusable().focusEffectDisabled()
        .onKeyPress(.leftArrow) { onChange(MusicScrubState.nudged(fraction, forward: false)); return .handled }
        .onKeyPress(.rightArrow) { onChange(MusicScrubState.nudged(fraction, forward: true)); return .handled }
        .onKeyPress(.home) { onChange(0); return .handled }
        .onKeyPress(.end) { onChange(1); return .handled }
        .accessibilityElement().accessibilityLabel(MusicA11yLabels.seek).accessibilityValue(Localized.string("%@ percent", "\(Int(fraction * 100))"))
        .accessibilityAdjustableAction { d in onChange(min(1, max(0, fraction + (d == .increment ? 0.05 : -0.05)))) }
    }

    private func currentAmplitude(at now: Date) -> CGFloat {
        MusicWaveMath.amplitude(playing: wavy, elapsed: now.timeIntervalSince(changedAt), from: ampAtChange)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, now: Date) {
        let f = dragging ?? fraction
        let midY = size.height / 2
        let thumbX = MusicWaveMath.thumbX(fraction: f, width: size.width)
        let gap = MusicWaveMath.thumbGap
        let playedEnd = max(0, thumbX - gap)
        let amp = settled && !wavy ? 0 : currentAmplitude(at: now)
        let phase = MusicWaveMath.phase(time: now.timeIntervalSince(origin))

        var played = Path()
        if playedEnd > 0 {
            played.move(to: CGPoint(x: 0, y: midY))
            var x: CGFloat = 0
            while x < playedEnd {
                x = min(playedEnd, x + 2)
                played.addLine(to: CGPoint(x: x, y: midY + MusicWaveMath.displacement(x: x, end: playedEnd, amplitude: amp, phase: phase)))
            }
        }
        let style = StrokeStyle(lineWidth: MusicWaveMath.stroke, lineCap: .round, lineJoin: .round)
        ctx.stroke(played, with: .color(accent), style: style)

        let restStart = min(size.width, thumbX + gap)
        if restStart < size.width {
            var rest = Path()
            rest.move(to: CGPoint(x: restStart, y: midY)); rest.addLine(to: CGPoint(x: size.width, y: midY))
            ctx.stroke(rest, with: .color(ColorTokens.textPrimary.opacity(0.22)), style: style)
        }
        let thumb = CGRect(x: thumbX - MusicWaveMath.thumbWidth / 2, y: midY - MusicWaveMath.thumbHeight / 2,
                           width: MusicWaveMath.thumbWidth, height: MusicWaveMath.thumbHeight)
        ctx.fill(Path(roundedRect: thumb, cornerRadius: MusicWaveMath.thumbWidth / 2), with: .color(accent))
    }
}

// MARK: wheel volume

extension View {
    /// Scrolling over this view changes the volume in steps of five percent (macOS). Does nothing on iOS.
    /// `enabled` is false while another surface (the full-window player) covers this one: the event monitor ignores z-order, so it must be told.
    func musicWheelVolume(_ player: MusicPlayer, enabled: Bool = true) -> some View {
        #if os(macOS)
        return background(MusicWheelCatcher(player: player, enabled: enabled))
        #else
        return self
        #endif
    }
}

#if os(macOS)
/// Listens for scroll-wheel events whose pointer is inside this view. A local monitor is used so the view underneath stays clickable.
private struct MusicWheelCatcher: NSViewRepresentable {
    let player: MusicPlayer
    var enabled = true

    func makeNSView(context: Context) -> WheelView {
        let v = WheelView()
        v.player = player
        v.enabled = enabled
        return v
    }

    func updateNSView(_ nsView: WheelView, context: Context) { nsView.player = player; nsView.enabled = enabled }

    static func dismantleNSView(_ nsView: WheelView, coordinator: ()) { nsView.stop() }

    @MainActor
    final class WheelView: NSView {
        var player: MusicPlayer?
        var enabled = true
        private var token: Any?
        private var wheel = MusicWheelVolume()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { start() }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func stop() {
            if let t = token { NSEvent.removeMonitor(t) }
            token = nil
        }

        private func start() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let used: Bool = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return used ? nil : event
            }
        }

        private func handle(_ e: NSEvent) -> Bool {
            guard enabled, let window, e.window === window, let player else { return false }
            let p = convert(e.locationInWindow, from: nil)
            guard bounds.contains(p) else { return false }
            // A scrolling list under the pointer keeps its own scroll: only a bare wheel over the control is taken, and not mid-momentum.
            guard e.momentumPhase.isEmpty else { return false }
            let steps = wheel.steps(delta: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas)
            guard steps != 0 else { return true }
            player.volume = MusicWheelVolume.volume(from: player.volume, steps: steps)
            return true
        }
    }
}
#endif

// MARK: zoom

extension View {
    /// Scales the whole view by the Music zoom level and lays it out again at the new size, the way a browser zooms a page.
    func musicZoomed(_ zoom: MusicZoom = .shared) -> some View { modifier(MusicZoomModifier(zoom: zoom)) }
}

private struct MusicZoomModifier: ViewModifier {
    let zoom: MusicZoom

    func body(content: Content) -> some View {
        let s = zoom.scale
        if s == 1 {
            content
        } else {
            GeometryReader { g in
                content
                    .frame(width: g.size.width / s, height: g.size.height / s)
                    .scaleEffect(s, anchor: .topLeading)
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                    .clipped()
            }
        }
    }
}

/// The bar's Comments control: a second press closes the panel, a press while it shows another song moves it to the playing song.
@MainActor
enum MusicBarComments {
    static func toggle(_ current: MusicTrack?) {
        let chrome = MusicChromeState.shared
        if chrome.comments?.uid == current?.uid, chrome.comments != nil { chrome.comments = nil } else { chrome.comments = current }
    }
}
