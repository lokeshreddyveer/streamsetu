import SwiftUI
import AVFoundation

/// When the motion pieces may run. One place, so the clip, the drift and the tests agree.
enum MusicMotionPlaybackRules {
    /// The clip moves only while the song plays, the view is on screen, the app is in front and Reduce Motion is off.
    static func shouldPlay(isPlaying: Bool, onScreen: Bool, appActive: Bool, reduceMotion: Bool) -> Bool {
        isPlaying && onScreen && appActive && !reduceMotion
    }

    /// A lookup (and so a download) starts only when the switch is on and a song is playing in a view the person can see.
    static func shouldFetch(enabled: Bool, isPlaying: Bool, onScreen: Bool, reduceMotion: Bool) -> Bool {
        enabled && isPlaying && onScreen && !reduceMotion
    }

    /// The slow drift on the cover: on while moving, never under a playing clip.
    static func coverDrifts(setting: Bool, shouldPlay: Bool, clipShowing: Bool) -> Bool { setting && shouldPlay && !clipShowing }

    static let fadeSeconds = 0.3
}

/// The gentle zoom and drift of a still cover. Pure maths of elapsed seconds, starting from the resting picture so that switching it on never jumps.
enum MusicCoverDriftMath {
    static let zoomAmount = 0.07
    static let zoomPeriod = 28.0
    static let driftAmount = 0.012
    static let driftPeriod = 41.0

    static func zoom(at t: Double) -> Double { 1 + zoomAmount * (1 - cos(2 * .pi * t / zoomPeriod)) / 2 }
    /// Offset as a fraction of the cover's side.
    static func offset(at t: Double) -> (x: Double, y: Double) {
        (driftAmount * sin(2 * .pi * t / driftPeriod), driftAmount * (1 - cos(2 * .pi * t / driftPeriod)) / 2)
    }
}

/// The cover, slowly breathing, for a song that has no animated artwork. It needs no network. Still while paused, off screen or with Reduce Motion;
/// the frame clock is paused then, so the idle cost is nothing.
struct MusicCoverMotionView: View {
    var thumbs: [MusicThumbnail]
    var corner: CGFloat = 12
    var drifting: Bool
    @State private var started = Date()
    @State private var settled = true

    var body: some View {
        GeometryReader { g in
            MusicFrameClock(minimumInterval: 1.0 / 20, paused: !drifting) { ctx in
                let t = drifting ? max(0, ctx.date.timeIntervalSince(started)) : 0
                let o = MusicCoverDriftMath.offset(at: t)
                MusicCoverImage(thumbs: thumbs, size: nil, corner: 0)
                    .scaleEffect(drifting ? MusicCoverDriftMath.zoom(at: t) : 1)
                    .offset(x: g.size.width * o.x, y: g.size.height * o.y)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onChange(of: drifting) { _, on in if on { started = Date() } }
        .accessibilityHidden(true)
    }
}

/// Holds the muted looping player for one clip.
@MainActor @Observable
final class MusicMotionArtViewModel {
    private(set) var player: AVQueuePlayer?
    private(set) var ready = false
    private var looper: AVPlayerLooper?
    private var fileURL: URL?
    private var watch: Task<Void, Never>?
    private let service: MusicMotionArtworkService

    init(service: MusicMotionArtworkService = .shared) { self.service = service }

    var hasClip: Bool { player != nil }

    /// Looks for the clip of this song and starts it when found. A clip already showing for the same file is left alone.
    func load(track: MusicTrack, storefront: String) async {
        let file = await service.file(for: MusicMotionQuery(track: track, storefront: storefront))
        guard !Task.isCancelled else { return }
        guard let file else { teardown(); return }
        if file == fileURL, player != nil { return }
        build(file)
    }

    private func build(_ url: URL) {
        teardown()
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.volume = 0
        queue.allowsExternalPlayback = false
        queue.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        fileURL = url
        watch = Task { [weak self] in
            // The picture is only shown once its first frame is ready; a clip that cannot be read leaves the cover alone.
            while !Task.isCancelled {
                guard let self, let status = self.player?.currentItem?.status else { return }
                if status == .readyToPlay { self.ready = true; return }
                if status == .failed { self.teardown(); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func setPlaying(_ play: Bool) {
        guard let player else { return }
        if play { player.play() } else { player.pause() }
    }

    func teardown() {
        watch?.cancel(); watch = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil; player = nil; fileURL = nil; ready = false
    }
}

#if os(macOS)
private final class MusicMotionLayerView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
}

private struct MusicMotionSurface: NSViewRepresentable {
    var player: AVQueuePlayer
    func makeNSView(context: Context) -> NSView { MusicMotionLayerView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        guard let l = (view as? MusicMotionLayerView)?.playerLayer else { return }
        if l.player !== player { l.player = player }
        l.videoGravity = .resizeAspectFill
    }
    static func dismantleNSView(_ view: NSView, coordinator: ()) { (view as? MusicMotionLayerView)?.playerLayer?.player = nil }
}
#else
private final class MusicMotionLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
}

private struct MusicMotionSurface: UIViewRepresentable {
    var player: AVQueuePlayer
    func makeUIView(context: Context) -> UIView { MusicMotionLayerView() }
    func updateUIView(_ view: UIView, context: Context) {
        guard let l = (view as? MusicMotionLayerView)?.playerLayer else { return }
        if l.player !== player { l.player = player }
        l.videoGravity = .resizeAspectFill
    }
    static func dismantleUIView(_ view: UIView, coordinator: ()) { (view as? MusicMotionLayerView)?.playerLayer?.player = nil }
}
#endif

/// The cover slot of the expanded player: the cover, the looping clip faded in over it once ready (300 ms), or the slow drift when there is no clip.
/// Square, filling the width it is given.
struct MusicMotionArtView: View {
    let track: MusicTrack
    var corner: CGFloat = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MusicMotionPrefs.motionKey) private var motionOn = false
    @AppStorage(MusicMotionPrefs.coverMotionKey) private var coverMotion = true
    @State private var model = MusicMotionArtViewModel()
    @State private var onScreen = false

    private struct FetchKey: Equatable { var uid: String; var go: Bool }

    var body: some View {
        let hub = MusicHub.shared
        let playing = hub.player.isPlaying
        let play = MusicMotionPlaybackRules.shouldPlay(isPlaying: playing, onScreen: onScreen, appActive: scenePhase == .active, reduceMotion: reduceMotion)
        let fetch = MusicMotionPlaybackRules.shouldFetch(enabled: motionOn, isPlaying: playing, onScreen: onScreen, reduceMotion: reduceMotion)
        let showing = model.player != nil && model.ready
        ZStack {
            MusicCoverMotionView(thumbs: track.thumbnails, corner: corner,
                                 drifting: MusicMotionPlaybackRules.coverDrifts(setting: coverMotion, shouldPlay: play, clipShowing: showing))
            if let p = model.player {
                MusicMotionSurface(player: p)
                    .opacity(model.ready ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: MusicMotionPlaybackRules.fadeSeconds), value: model.ready)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false; model.teardown() }
        .task(id: FetchKey(uid: track.uid, go: fetch)) {
            guard fetch else { return }
            await model.load(track: track, storefront: hub.library.settings.countryCode)
            model.setPlaying(play)
        }
        .task(id: play) { model.setPlaying(play) }
        .onChange(of: motionOn) { _, on in if !on { model.teardown() } }
        .onChange(of: track.uid) { _, _ in if model.hasClip { model.teardown() } }
        .accessibilityHidden(true)
    }
}
