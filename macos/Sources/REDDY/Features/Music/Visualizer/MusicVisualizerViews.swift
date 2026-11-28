import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Counts the visualizers on screen; the audio tap is on only while at least one is.
@MainActor
enum MusicVisualizerUse {
    private static var count = 0
    static func begin(_ hub: MusicHub) { count += 1; if !MusicListeningModes.profile.noVisualizer, !MusicAccessibilityPrefs.visualizersDisabled { hub.player.setVisualizer(true) } }
    static func end(_ hub: MusicHub) { count = max(0, count - 1); if count == 0 { hub.player.setVisualizer(false) } }
}

/// Keeps the recent columns of the spectrogram.
final class MusicSpectrogramHistory: @unchecked Sendable {
    var columns: [[Float]] = []
    func add(_ c: [Float], keep: Int) { columns.append(c); if columns.count > keep { columns.removeFirst(columns.count - keep) } }
}

/// The picture itself. It draws only while it is on screen and the music is playing, at the frame rate the person chose, and turns the audio tap on and off with its own presence.
struct MusicVisualizerCanvas: View {
    let hub: MusicHub
    var mode: MusicVisualizerMode
    var colour: MusicVisualizerPreset.Colour
    var sensitivity: Double
    var smoothing: Double
    var fps: Int
    @State private var analyzer = MusicVisualizerAnalyzer()
    @State private var history = MusicSpectrogramHistory()
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cap = MusicListeningModes.profile.visualizerFPSCap
        let limit = cap > 0 ? min(fps, cap) : fps
        TimelineView(.animation(minimumInterval: 1.0 / Double(max(5, reduceMotion ? min(limit, 15) : limit)), paused: !hub.player.isPlaying || MusicListeningModes.profile.noVisualizer || MusicAccessibilityPrefs.visualizersDisabled)) { ctx in
            Canvas { gc, size in
                _ = ctx.date
                let tap = MusicAudioTap.shared.latest(MusicVisualizerAnalyzer.fftSize)
                let f = analyzer.analyse(left: tap.left, right: tap.right, sampleRate: tap.sampleRate, sensitivity: Float(sensitivity), smoothing: Float(smoothing))
                draw(f, in: &gc, size: size)
            }
        }
        .background(Color.black.opacity(0.0))
        .onAppear { MusicVisualizerUse.begin(hub) }
        .onDisappear { MusicVisualizerUse.end(hub) }
        .accessibilityLabel(Localized.string("Music visualizer"))
    }

    // MARK: colours

    private func shade(_ t: Double) -> Color {
        let x = min(1, max(0, t))
        switch colour {
        case .theme: return accent.opacity(0.35 + 0.65 * x)
        case .fire: return Color(hue: 0.0 + 0.13 * x, saturation: 0.95, brightness: 0.45 + 0.55 * x)
        case .ocean: return Color(hue: 0.62 - 0.12 * x, saturation: 0.8, brightness: 0.4 + 0.6 * x)
        case .mono: return Color.white.opacity(0.25 + 0.75 * x)
        }
    }

    // MARK: drawing

    private func draw(_ f: MusicVisualFrame, in gc: inout GraphicsContext, size: CGSize) {
        guard !f.bands.isEmpty else { return }
        switch mode {
        case .spectrum:
            let n = f.bands.count, w = size.width / CGFloat(n)
            for (i, v) in f.bands.enumerated() {
                let h = max(2, CGFloat(v) * size.height)
                gc.fill(Path(roundedRect: CGRect(x: CGFloat(i) * w + 1, y: size.height - h, width: max(1, w - 2), height: h), cornerRadius: min(3, w / 3)), with: .color(shade(Double(v))))
            }
        case .oscilloscope:
            var p = Path()
            let n = f.waveform.count
            for (i, v) in f.waveform.enumerated() {
                let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(max(1, n - 1)), y: size.height / 2 - CGFloat(max(-1, min(1, v))) * size.height * 0.45)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            gc.stroke(p, with: .color(shade(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        case .spectrogram:
            history.add(f.bands, keep: 160)
            let cols = history.columns, cw = size.width / CGFloat(160), rh = size.height / CGFloat(f.bands.count)
            for (x, col) in cols.enumerated() {
                let ox = size.width - CGFloat(cols.count - x) * cw
                for (b, v) in col.enumerated() where v > 0.05 {
                    gc.fill(Path(CGRect(x: ox, y: size.height - CGFloat(b + 1) * rh, width: cw + 0.5, height: rh + 0.5)), with: .color(shade(Double(v))))
                }
            }
        case .meters:
            let rows: [(String, Float, Float)] = [("L", f.rmsL, f.peakL), ("R", f.rmsR, f.peakR)]
            let rowH = size.height / 3
            for (i, r) in rows.enumerated() {
                let y = rowH * (CGFloat(i) + 0.5)
                let rms = CGFloat(min(1, r.1 * 2.2)), peak = CGFloat(min(1, r.2))
                gc.fill(Path(roundedRect: CGRect(x: 30, y: y, width: size.width - 40, height: rowH * 0.55), cornerRadius: 4), with: .color(.white.opacity(0.08)))
                gc.fill(Path(roundedRect: CGRect(x: 30, y: y, width: (size.width - 40) * rms, height: rowH * 0.55), cornerRadius: 4), with: .color(shade(Double(rms))))
                gc.fill(Path(CGRect(x: 30 + (size.width - 40) * peak - 2, y: y, width: 3, height: rowH * 0.55)), with: .color(peak > 0.95 ? .red : .white.opacity(0.85)))
                gc.draw(Text(verbatim: r.0).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.7)), at: CGPoint(x: 14, y: y + rowH * 0.27))
            }
        case .radial:
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r0 = min(size.width, size.height) * 0.22, rMax = min(size.width, size.height) * 0.48
            let n = f.bands.count
            for (i, v) in f.bands.enumerated() {
                let a = Double(i) / Double(n) * 2 * .pi - .pi / 2
                let r1 = r0 + CGFloat(v) * (rMax - r0)
                var p = Path()
                p.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0)); p.addLine(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
                gc.stroke(p, with: .color(shade(Double(v))), style: StrokeStyle(lineWidth: max(2, 2 * .pi * r0 / CGFloat(n) * 0.6), lineCap: .round))
            }
        case .phase:
            let w = size.width * 0.8, x0 = size.width * 0.1, y = size.height / 2
            gc.fill(Path(roundedRect: CGRect(x: x0, y: y - 8, width: w, height: 16), cornerRadius: 8), with: .color(.white.opacity(0.1)))
            let pos = x0 + w * CGFloat((f.correlation + 1) / 2)
            gc.fill(Path(ellipseIn: CGRect(x: pos - 12, y: y - 12, width: 24, height: 24)), with: .color(f.correlation < 0 ? .red : shade(0.9)))
            gc.draw(Text(verbatim: "-1").foregroundColor(.white.opacity(0.6)), at: CGPoint(x: x0, y: y + 28))
            gc.draw(Text(verbatim: "0").foregroundColor(.white.opacity(0.6)), at: CGPoint(x: x0 + w / 2, y: y + 28))
            gc.draw(Text(verbatim: "+1").foregroundColor(.white.opacity(0.6)), at: CGPoint(x: x0 + w, y: y + 28))
        case .vectorscope:
            let c = CGPoint(x: size.width / 2, y: size.height / 2), s = min(size.width, size.height) * 0.45
            var p = Path()
            for (l, r) in zip(f.leftPoints, f.rightPoints) {
                // Mid/side rotation: mono sits on the vertical axis, left-only and right-only on the diagonals.
                let m = (l + r) * 0.7071, d = (l - r) * 0.7071
                let pt = CGPoint(x: c.x + CGFloat(max(-1, min(1, d))) * s, y: c.y - CGFloat(max(-1, min(1, m))) * s)
                p.addEllipse(in: CGRect(x: pt.x - 1, y: pt.y - 1, width: 2, height: 2))
            }
            gc.fill(p, with: .color(shade(0.85)))
        }
    }
}

/// The window: pick a look, a preset and a frame rate; open it full screen or on a second display.
struct MusicVisualizerSheet: View {
    let hub: MusicHub
    let close: () -> Void
    @AppStorage(MusicVisualizerPrefs.modeKey) private var modeRaw = MusicVisualizerMode.spectrum.rawValue
    @AppStorage(MusicVisualizerPrefs.colourKey) private var colourRaw = MusicVisualizerPreset.Colour.theme.rawValue
    @AppStorage(MusicVisualizerPrefs.fpsKey) private var fps = 30
    @AppStorage(MusicVisualizerPrefs.sensitivityKey) private var sensitivity = 1.0
    @AppStorage(MusicVisualizerPrefs.smoothingKey) private var smoothing = 0.7

    private var mode: MusicVisualizerMode { MusicVisualizerMode(rawValue: modeRaw) ?? .spectrum }
    private var colour: MusicVisualizerPreset.Colour { MusicVisualizerPreset.Colour(rawValue: colourRaw) ?? .theme }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Visualizer")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.visualizerClose")
            }
            MusicVisualizerCanvas(hub: hub, mode: mode, colour: colour, sensitivity: sensitivity, smoothing: smoothing, fps: fps)
                .frame(minHeight: 260).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: MusicCorner.card).fill(Color.black.opacity(0.9)))
                .clipShape(RoundedRectangle(cornerRadius: MusicCorner.card))
            if hub.player.current == nil { Text(Localized.string("Play a song to see it move.")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
            HStack(spacing: MusicSpace.sm) {
                Picker("", selection: $modeRaw) { ForEach(MusicVisualizerMode.allCases) { Text($0.title).tag($0.rawValue) } }.labelsHidden().fixedSize().atlas("control.music.visualizerMode")
                Picker("", selection: $colourRaw) {
                    Text(Localized.string("Theme")).tag("theme"); Text(Localized.string("Fire")).tag("fire"); Text(Localized.string("Ocean")).tag("ocean"); Text(Localized.string("Mono")).tag("mono")
                }.labelsHidden().fixedSize().atlas("control.music.visualizerColour")
                Picker("", selection: $fps) { ForEach(MusicVisualizerPrefs.fpsChoices, id: \.self) { Text(Localized.string("%@ frames a second", String($0))).tag($0) } }.labelsHidden().fixedSize().atlas("control.music.visualizerFPS")
                Menu(Localized.string("Presets")) {
                    ForEach(MusicVisualizerPreset.builtIn) { p in
                        Button(Localized.string(p.name)) { modeRaw = p.mode; colourRaw = p.colour.rawValue; sensitivity = p.sensitivity; smoothing = p.smoothing }.atlas("control.music.visualizerPreset")
                    }
                }.menuStyle(.borderlessButton).fixedSize().atlas("control.music.visualizerPresets")
            }
            HStack(spacing: MusicSpace.md) {
                VStack(alignment: .leading) { Text(Localized.string("Sensitivity")).font(Typography.caption); Slider(value: $sensitivity, in: 0.4...3).atlas("control.music.visualizerSensitivity") }
                VStack(alignment: .leading) { Text(Localized.string("Smoothness")).font(Typography.caption); Slider(value: $smoothing, in: 0...0.95).atlas("control.music.visualizerSmoothing") }
            }
            #if os(macOS)
            HStack(spacing: MusicSpace.sm) {
                Button { MusicVisualizerWindows.open(hub: hub, mode: mode, colour: colour, sensitivity: sensitivity, smoothing: smoothing, fps: fps, secondDisplay: false) } label: {
                    Label(Localized.string("Full screen"), systemImage: "arrow.up.left.and.arrow.down.right")
                }.musicButton(.secondary, size: .compact).atlas("control.music.visualizerFullScreen")
                if NSScreen.screens.count > 1 {
                    Button { MusicVisualizerWindows.open(hub: hub, mode: mode, colour: colour, sensitivity: sensitivity, smoothing: smoothing, fps: fps, secondDisplay: true) } label: {
                        Label(Localized.string("On the other display"), systemImage: "display.2")
                    }.musicButton(.secondary, size: .compact).atlas("control.music.visualizerSecondDisplay")
                }
            }
            #endif
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520)
    }
}

#if os(macOS)
/// Full-screen and second-display windows. Each holds its own canvas, so closing the window ends its use of the audio tap.
@MainActor
enum MusicVisualizerWindows {
    private static var windows: [NSWindow] = []

    static func open(hub: MusicHub, mode: MusicVisualizerMode, colour: MusicVisualizerPreset.Colour, sensitivity: Double, smoothing: Double, fps: Int, secondDisplay: Bool) {
        let screens = NSScreen.screens
        let target = secondDisplay ? (screens.first { $0 != NSScreen.main } ?? screens.first) : NSScreen.main
        let frame = (target ?? NSScreen.screens[0]).visibleFrame
        let w = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false, screen: target)
        w.title = Localized.string("Visualizer")
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentView = NSHostingView(rootView: MusicVisualizerCanvas(hub: hub, mode: mode, colour: colour, sensitivity: sensitivity, smoothing: smoothing, fps: fps).background(Color.black).ignoresSafeArea())
        w.setFrame(frame, display: true)
        w.makeKeyAndOrderFront(nil)
        if !secondDisplay { w.toggleFullScreen(nil) }
        windows.removeAll { !$0.isVisible }
        windows.append(w)
    }
}
#endif
