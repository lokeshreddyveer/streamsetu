import SwiftUI
import AVKit
import UniformTypeIdentifiers
import AVFoundation
import Observation

// MARK: - video surface and Picture in Picture

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Owns the system Picture in Picture controller for the video layer on screen.
@MainActor @Observable
final class PiPController: NSObject, AVPictureInPictureControllerDelegate {
    private(set) var isPossible = false
    private(set) var isActive = false
    private var controller: AVPictureInPictureController?
    private var observation: NSKeyValueObservation?

    func attach(_ layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(), controller == nil else { return }
        let c = AVPictureInPictureController(playerLayer: layer)
        c?.canStartPictureInPictureAutomaticallyFromInline = true       // leaving the app keeps the picture going
        c?.delegate = self
        controller = c
        observation = c?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() } else { controller.startPictureInPicture() }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { Task { @MainActor in self.isActive = true } }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { Task { @MainActor in self.isActive = false } }
}

#if STREAMSETU_MPV
/// Picture in Picture for MPV. MPV draws its own frames, so while Picture in Picture is on each finished frame is also handed to a
/// sample-buffer layer, which is what the system shows in the small window. Off otherwise, so there is no extra work.
@MainActor @Observable
final class MPVPiPController: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private(set) var isActive = false
    private var controller: AVPictureInPictureController?
    private weak var playback: PlaybackCoordinator?

    func attach(_ layer: AVSampleBufferDisplayLayer, playback: PlaybackCoordinator) {
        guard AVPictureInPictureController.isPictureInPictureSupported(), controller == nil else { return }
        self.playback = playback
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        controller = c
    }

    func toggle() {
        guard let controller, let playback else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture(); return }
        playback.setPiPFeed(true)
        Task { try? await Task.sleep(nanoseconds: 350_000_000); controller.startPictureInPicture() }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { Task { @MainActor in self.isActive = true } }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { Task { @MainActor in self.isActive = false; self.playback?.setPiPFeed(false) } }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { Task { @MainActor in self.playback?.setPiPFeed(false) } }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in if playing { self.playback?.resume() } else { self.playback?.pause() } }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated {
            if let p = playback, !p.isLive, let d = p.duration, d > 0 { return CMTimeRange(start: .zero, duration: CMTime(seconds: d, preferredTimescale: 600)) }
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { playback?.state == .paused }
    }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping @Sendable () -> Void) {
        Task { @MainActor in
            if let p = self.playback, !p.isLive { p.seek(by: skipInterval.seconds) }
            completion()
        }
    }
}
#endif

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var fill: Bool
    /// Stretches the picture to the view (for a chosen aspect ratio, which the view already has).
    var stretch = false
    let pip: PiPController

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = stretch ? .resize : (fill ? .resizeAspectFill : .resizeAspect)
        pip.attach(v.playerLayer)
        return v
    }

    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = stretch ? .resize : (fill ? .resizeAspectFill : .resizeAspect)
    }
}

#if STREAMSETU_MPV
/// Hosts libmpv's picture (a sample-buffer layer). Used for MKV, RTSP, AVI and other formats Apple's player can't open.
final class MPVHostView: UIView {
    var videoLayer: CALayer? { didSet { oldValue?.removeFromSuperlayer(); if let l = videoLayer { layer.addSublayer(l); setNeedsLayout() } } }
    /// The sample-buffer layer behind Picture in Picture. It sits under the picture and only receives frames while Picture in Picture is on.
    var pipLayer: CALayer? { didSet { oldValue?.removeFromSuperlayer(); if let l = pipLayer { layer.insertSublayer(l, at: 0); setNeedsLayout() } } }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        pipLayer?.frame = bounds
        Trace.log("MPVHostView layout bounds=\(Int(bounds.width))x\(Int(bounds.height)) inWindow=\(window != nil) hidden=\(videoLayer?.isHidden ?? true) hasContents=\(videoLayer?.contents != nil)")
        CATransaction.commit()
    }
}

struct MPVSurface: UIViewRepresentable {
    let layer: CALayer
    var fill: Bool
    var stretch = false
    var pipLayer: CALayer?
    func makeUIView(context: Context) -> MPVHostView { let v = MPVHostView(); v.backgroundColor = .black; v.videoLayer = layer; v.pipLayer = pipLayer; return v }
    func updateUIView(_ v: MPVHostView, context: Context) {
        if v.pipLayer !== pipLayer { v.pipLayer = pipLayer }
        layer.contentsGravity = stretch ? .resize : (fill ? .resizeAspectFill : .resizeAspect)
        if v.videoLayer !== layer { v.videoLayer = layer }
    }
}
#endif

/// The system AirPlay button.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white; v.activeTintColor = UIColor(ColorTokens.accentDefault); v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

// MARK: - full screen player

struct PlayerScreen: View {
    let playback: PlaybackCoordinator
    @State private var pip = PiPController()
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    /// The last Fill/Fit choice, used for a title that has none of its own.
    @AppStorage("player.fillScreen") private var lastFill = false
    @State private var fill = false
    @State private var drag: CGFloat = 0
    @State private var locked = false
    @State private var showChannels = false
    @State private var showGuide = false
    @State private var showOptions = false
    @State private var showCatchUp = false
    @State private var programme: EPGProgram?
    @State private var upcoming: [EPGProgram] = []
    @Environment(\.container) private var container
    @State private var hud: GestureHUD?
    @State private var hudTask: Task<Void, Never>?
    @State private var banner = false
    @State private var bannerTask: Task<Void, Never>?
    @State private var resumeAt: Double?
    @State private var resumeTask: Task<Void, Never>?
    @State private var resumeShown: Set<String> = []
    @State private var nextDismissedFor: String?
    @State private var heldRate: Double?
    @State private var skipTotal = 0.0
    @State private var skipSide = 0
    @State private var skipAt: Date?
    @State private var scrubPreview: Double?
    @State private var logNote: String?
    @State private var landscape = false
    @State private var aspect: AspectRatioOption = .original
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var loopA: Double?
    @State private var loopB: Double?
    @AppStorage("player.controlSeconds") private var controlSeconds = 3.5
    @AppStorage("player.leftHanded") private var leftHanded = false
    /// Keeps the picture size, language and other details on screen while playing (on by default).
    @AppStorage("player.streamInfo") private var streamInfo = true
    @State private var showEpisodes = false
    @State private var showSearch = false
    @State private var importingSubtitle = false
    @AppStorage("player.tourSeen") private var tourSeen = false
    @State private var showTour = false
    @State private var showNumberPad = false
    @State private var reminded: Set<Int64> = []
    @State private var longWatchTask: Task<Void, Never>?
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if STREAMSETU_MPV
    @State private var mpvPiP = MPVPiPController()
    #endif

    var body: some View {
        ZStack {
            // The picture and the touch layer: their own reader that ignores the safe area, so the size it reports is the whole screen and the
            // picture is centred on the screen itself (measured from the safe area instead, it sat about 10 points too high).
            GeometryReader { screen in
                ZStack {
                    Color.black
                    picture(screen.size)
                    if playback.isAudioOnly { AudioOnlyBackdrop(playback: playback, program: programme).allowsHitTesting(false) }
                    GestureSurface(enabled: !locked, isLive: playback.isLive, zoomed: zoom > 1, actions: gestureActions)
                }
            }
            .ignoresSafeArea()
            controlsLayer
        }
    }

    /// Everything above the picture, laid out inside the safe area.
    private var controlsLayer: some View {
        GeometryReader { geo in
            ZStack {
                status
                cards
                if streamInfo, !locked, !showControls, infoVisible {
                    // One small faint line, so nothing jumps around when the controls hide.
                    VStack { Spacer(); StreamInfoLine(playback: playback).padding(.bottom, landscape ? 8 : 20) }
                        .padding(.horizontal, landscape ? 28 : 16).frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
                if locked { lockLayer } else if showControls { controls.transition(.opacity) }
                if showChannels { sidePanel.transition(.move(edge: leftHanded ? .leading : .trailing)) }
                if !showControls, !locked, !playback.isLive, let d = playback.duration, d > 0 {
                    VStack { Spacer(); ProgressLine(position: scrubbing ?? playback.position, duration: d) }.ignoresSafeArea(edges: .bottom)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { if showTour { GestureTour(isLive: playback.isLive) { showTour = false; tourSeen = true }.transition(.opacity) } }
            .overlay(alignment: .top) { if let hud { GestureHUDView(hud: hud).padding(.top, 70).transition(.opacity) } }
            .offset(y: max(0, drag))
            .onChange(of: geo.size, initial: true) { _, s in landscape = s.width > s.height }
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            fill = PlayerMemory.fill(for: playback.current?.itemID) ?? lastFill; scheduleHide(); if playback.isLive { showBanner() }
            longWatchTask?.cancel()
            longWatchTask = Task {
                try? await Task.sleep(nanoseconds: 3 * 3_600 * 1_000_000_000)
                if !Task.isCancelled { showHUD(GestureHUD(symbol: "moon.zzz", label: "You've been watching for 3 hours", level: nil), hideAfter: 6) }
            }
        }
        .onDisappear { ScreenBrightness.restore(); longWatchTask?.cancel(); if let r = heldRate { playback.setRate(r); heldRate = nil } }
        .task(id: playback.currentChannel?.id) {
            guard let c = container, let id = playback.currentChannel?.id else { programme = nil; upcoming = []; return }
            let list = await Task.detached { (try? c.epgRepo.nowNext(channelIDs: [id], at: Date()))?[id] ?? [] }.value
            upcoming = list; programme = list.first { $0.isLive() }
        }
        .onChange(of: playback.currentChannel?.id) { _, _ in logNote = nil; showBanner() }
        .onChange(of: playback.current?.itemID) { _, id in
            fill = PlayerMemory.fill(for: id) ?? lastFill
            resumeAt = nil; nextDismissedFor = nil; logNote = nil
            loopA = nil; loopB = nil; zoom = 1; pan = .zero; aspect = .original
            if let r = PlayerMemory.speed(forSeries: playback.current?.seriesID) { playback.setRate(r) } else if playback.rate != 1, !playback.isLive { playback.setRate(1) }
        }
        .onChange(of: playback.state) { _, s in
            // Controls come up only when something needs the person: paused, failed or finished. Not for a skip, a swipe or a brief buffer,
            // which would pop the slider and buttons over the picture every time they double-tap.
            switch s {
            case .playing:
                scheduleHide(); maybeShowResume()
                if !tourSeen, !showTour { Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if playback.state == .playing, !tourSeen { showTour = true } } }
            case .paused, .failed, .idle, .ended: showControlsNow()
            default: break
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: showChannels)
        .animation(.easeInOut(duration: 0.2), value: hud)
        .sheet(isPresented: $showOptions) {
            PlayerOptionsSheet(playback: playback, aspect: $aspect, zoom: $zoom, fill: $fill, loopA: $loopA, loopB: $loopB, controlSeconds: $controlSeconds, leftHanded: $leftHanded, streamInfo: $streamInfo,
                               setFill: setFill, setSpeed: setSpeed, saveFrame: saveFrame)
        }
        .sheet(isPresented: $showEpisodes) { EpisodeListSheet(playback: playback) }
        .sheet(isPresented: $showSearch) {
            if let c = container {
                PlayerSearchSheet(onChannel: { Play.channel($0, queue: playback.queue, c) }, onMovie: { Play.movie($0, c) }, onEpisode: { Play.episode($0, $1, c) })
                    .presentationDetents([.large])
            }
        }
        .fileImporter(isPresented: $importingSubtitle, allowedContentTypes: [.item]) { result in
            showHUD(GestureHUD(symbol: "captions.bubble", label: SubtitleImport.load(result, into: playback), level: nil), hideAfter: 2.5)
            scheduleHide()
        }
        .sheet(isPresented: $showNumberPad) { ChannelNumberPad(playback: playback) }
        .sheet(isPresented: $showCatchUp) { if let ch = playback.currentChannel { CatchUpSheet(playback: playback, channel: ch) } }
    }

    // MARK: picture

    /// The video, shaped to the chosen aspect ratio, zoomed and moved. With the original shape and no zoom it is the plain fit or fill picture.
    private func picture(_ full: CGSize) -> some View {
        let shaped = aspect.value != nil
        let size = shaped ? Self.shape(aspect.value!, in: full, cover: fill) : full
        return ZStack {
            VideoSurface(player: playback.avPlayer, fill: fill, stretch: shaped, pip: pip)
            #if STREAMSETU_MPV
            if playback.activeEngine == .mpv, let mpv = playback.mpvSurface {
                MPVSurface(layer: mpv, fill: fill, stretch: shaped, pipLayer: playback.mpvLayer)
                    .onAppear { if let l = playback.mpvLayer { mpvPiP.attach(l, playback: playback) } }
            }
            #endif
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(zoom)
        .offset(pan)
        .frame(width: full.width, height: full.height)
        .clipped()
    }

    /// The largest (or, covering, smallest) rectangle of this width-to-height ratio that fits in the container.
    static func shape(_ ratio: Double, in c: CGSize, cover: Bool) -> CGSize {
        let containerRatio = Double(c.width / max(1, c.height))
        let widthLimited = cover ? ratio < containerRatio : ratio >= containerRatio
        return widthLimited ? CGSize(width: c.width, height: c.width / ratio) : CGSize(width: c.height * ratio, height: c.height)
    }

    private func movePicture(_ d: CGSize) {
        let limitX = UIScreen.main.bounds.width * (zoom - 1) / 2, limitY = UIScreen.main.bounds.height * (zoom - 1) / 2
        pan = CGSize(width: min(limitX, max(-limitX, pan.width + d.width)), height: min(limitY, max(-limitY, pan.height + d.height)))
    }

    private func zoomBy(_ step: Double) {
        zoom = min(3, max(1, zoom + step))
        if zoom == 1 { pan = .zero } else { movePicture(.zero) }
        showHUD(GestureHUD(symbol: "plus.magnifyingglass", label: String(format: "%.2g×", zoom), level: nil), hideAfter: 0.8)
    }

    // MARK: gestures

    private var gestureActions: PlayerGestureActions {
        PlayerGestureActions(
            tap: { toggleControls() },
            doubleTap: { doubleTap(fraction: $0) },
            holdChanged: { hold($0) },
            adjust: { adjust($0, $1) },
            adjustEnded: { hideHUD(after: 0.9) },
            zap: { zap($0) },
            pull: { distance, ended in
                if !ended { drag = distance } else { if distance > 140 { dismiss() }; withAnimation(.smooth) { drag = 0 } }
            },
            pinchEnded: { scale in
                if scale > 1.15 { if fill || aspect.value != nil { zoomBy(0.5) } else { setFill(true) } }
                else if scale < 0.87 { if zoom > 1 { zoomBy(-0.5) } else { setFill(false) } }
            },
            panVideo: { movePicture($0) },
            scrub: { dx, ended in scrub(dx, ended: ended) })
    }

    private func doubleTap(fraction: CGFloat) {
        guard !playback.isLive else { return }
        let back = fraction < 0.5
        let side = back ? -1 : 1
        // Tapping again on the same side keeps adding: 10 s, 20 s, 30 s…
        skipTotal = PlayerMath.stackedSkip(previousTotal: skipTotal, previousSide: skipSide, previousAt: skipAt, side: side, now: Date())
        skipSide = side; skipAt = Date()
        playback.seek(by: Double(side) * 10)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showHUD(GestureHUD(symbol: back ? "gobackward" : "goforward", label: "\(back ? "−" : "+")\(Int(skipTotal)) s", level: nil), hideAfter: 0.9)
    }

    /// A swipe along the picture moves through a movie; the preview shows where it would land, and letting go jumps there.
    private func scrub(_ dx: CGFloat, ended: Bool) {
        guard !playback.isLive, let d = playback.duration, d > 0 else { return }
        let width = Double(UIScreen.main.bounds.width)
        let target = PlayerMath.scrubTarget(position: playback.position, dragPoints: Double(dx), screenWidth: width, duration: d)
        if ended {
            scrubPreview = nil
            playback.seek(to: target)
            hideHUD(after: 0.4)
        } else {
            scrubPreview = target
            showHUD(GestureHUD(symbol: dx < 0 ? "backward.fill" : "forward.fill", label: "\(DurationFormatter.clock(target))  (\(PlayerMath.signedClock(target - playback.position)))", level: nil), hideAfter: nil)
        }
    }

    private func hold(_ holding: Bool) {
        guard !playback.isLive else { return }
        if holding {
            heldRate = playback.rate
            playback.setRate(2)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showHUD(GestureHUD(symbol: "forward.fill", label: "2×", level: nil), hideAfter: nil)
        } else {
            if let r = heldRate { playback.setRate(r) }
            heldRate = nil
            hideHUD(after: 0.2)
        }
    }

    private func adjust(_ side: PlayerGestureActions.Side, _ delta: CGFloat) {
        switch (leftHanded ? (side == .left ? PlayerGestureActions.Side.right : .left) : side) {
        case .left:
            ScreenBrightness.value += delta
            let v = Double(ScreenBrightness.value)
            showHUD(GestureHUD(symbol: v < 0.35 ? "sun.min.fill" : "sun.max.fill", label: "\(Int((v * 100).rounded()))%", level: v), hideAfter: nil)
        case .right:
            playback.volume = min(1, max(0, playback.volume + Double(delta)))
            let v = playback.volume
            showHUD(GestureHUD(symbol: v == 0 ? "speaker.slash.fill" : (v < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"), label: "\(Int((v * 100).rounded()))%", level: v), hideAfter: nil)
        }
    }

    private func setFill(_ on: Bool) {
        guard on != fill else { return }
        fill = on; lastFill = on
        PlayerMemory.setFill(on, for: playback.current?.itemID)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showHUD(GestureHUD(symbol: on ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", label: on ? "Fill" : "Fit", level: nil), hideAfter: 0.9)
    }

    /// Swipe to change channel while watching live TV.
    private func zap(_ step: Int) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if step > 0 { playback.nextChannel() } else { playback.previousChannelInList() }
        scheduleHide()
    }

    private func showHUD(_ value: GestureHUD, hideAfter: Double?) {
        hudTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) { hud = value }
        if let hideAfter { hideHUD(after: hideAfter) }
    }

    private func hideHUD(after seconds: Double) {
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.25)) { hud = nil } }
        }
    }

    /// The one skip button offered right now: the recap, the opening or the credits.
    private var skipButton: (title: String, action: () -> Void)? {
        if playback.recapEnd != nil { return ("Skip Recap", { playback.skipRecap() }) }
        if playback.introEnd != nil { return ("Skip Intro", { playback.skipIntro() }) }
        if playback.creditsShowing { return ("Skip Credits", { playback.skipCredits() }) }
        return nil
    }

    // MARK: overlays on the picture

    @ViewBuilder private var status: some View {
        switch playback.state {
        case .buffering, .seeking:
            VStack(spacing: 8) { ProgressView().controlSize(.large).tint(.white); if let m = playback.statusMessage { Text(m).font(.caption).foregroundStyle(.white.opacity(0.8)) } }
        case .resolving, .preparing, .recovering:
            StatusCard(state: playback.state, message: playback.statusMessage, offline: playback.waitingForNetwork) { playback.stop(); dismiss() }
        case .failed(let e):
            FailureCard(error: e, isLive: playback.isLive, canZap: playback.queue.count > 1, logNote: $logNote,
                        retry: { playback.retryNow() }, nextChannel: { zap(1) },
                        sendLog: { sendLog() }, close: { playback.stop(); dismiss() })
        default: EmptyView()
        }
    }

    /// Cards that come and go over the picture: resumed, up next, the channel just tuned, and the guide.
    private var cards: some View {
        VStack {
            if playback.isLive, banner, !showControls, let ch = playback.currentChannel {
                HStack { ChannelBanner(channel: ch, number: playback.channelNumber(of: ch), programme: programme).transition(.move(edge: .leading).combined(with: .opacity)); Spacer() }
                    .padding(.top, 56)
            }
            Spacer()
            if showGuide, playback.isLive {
                MiniGuideCard(programmes: upcoming, reminded: reminded, remind: { remind($0) }) { showGuide = false }.padding(.bottom, showControls ? 150 : 24)
            }
            HStack(alignment: .bottom) {
                if let at = resumeAt, !playback.isLive {
                    ResumeCard(position: at, startOver: { playback.seek(to: 0); resumeAt = nil }, dismiss: { resumeAt = nil })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Spacer()
                if playback.state.isPlaying, let skip = skipButton {
                    Button { skip.action() } label: { Label(skip.title, systemImage: "forward.end.fill").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 16).frame(minHeight: 40) }
                        .buttonStyle(.plain).foregroundStyle(.white).background(.black.opacity(0.65), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.3)))
                        .frame(maxWidth: .infinity, alignment: .trailing).transition(.opacity)
                }
                if let next = playback.upNext, !playback.isLive, let d = playback.duration, d > 60, d - playback.position < 30,
                   nextDismissedFor != playback.current?.itemID {
                    NextEpisodeCard(episode: next, play: { playback.playNextEpisode() }, dismiss: { nextDismissedFor = playback.current?.itemID })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.bottom, showControls ? 175 : 56)
        }
        .padding(.horizontal, landscape ? 28 : 16)
        .animation(.easeInOut(duration: 0.25), value: resumeAt != nil)
        .animation(.easeInOut(duration: 0.25), value: banner)
    }

    private var sidePanel: some View {
        HStack(spacing: 0) {
            if leftHanded { ChannelSidePanel(playback: playback, leading: true) { showChannels = false } }
            Color.black.opacity(0.001).onTapGesture { showChannels = false }
            if !leftHanded { ChannelSidePanel(playback: playback) { showChannels = false } }
        }
        .ignoresSafeArea()
    }

    private var lockLayer: some View {
        VStack {
            Spacer()
            if showControls {
                Button { locked = false; UINotificationFeedbackGenerator().notificationOccurred(.success); scheduleHide() } label: {
                    Label("Unlock controls", systemImage: "lock.open.fill").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 18).frame(minHeight: 44)
                        .background(.black.opacity(0.7), in: Capsule())
                }.foregroundStyle(.white).accessibilityLabel("Unlock controls").transition(.opacity)
            }
        }.padding(.bottom, 40)
    }

    // MARK: controls

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, landscape ? 24 : 16).padding(.top, 8).padding(.bottom, landscape ? 30 : 34)
            // Play, back and forward sit on the true middle of the screen, whatever the bars above and below take up.
            transport.frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }

    private var infoVisible: Bool {
        playback.state == .playing || playback.state == .buffering || playback.state == .paused || playback.state == .seeking
    }

    /// Minimal top bar: close, what is playing, AirPlay and one More button that holds everything else.
    private var topBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44) }.accessibilityLabel("Close player")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(playback.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    if playback.isLive { Text("LIVE").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2).background(.red, in: Capsule()) }
                }
                if let s = playback.subtitle, !s.isEmpty { Text(s).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if landscape { ClockBattery() }
            Button { showSearch = true; hideTask?.cancel() } label: { Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }.accessibilityLabel("Search the catalog")
            AirPlayButton().frame(width: 44, height: 44)
            moreMenu
        }
    }

    /// Everything that is not needed every minute, in one place.
    private var moreMenu: some View {
        Menu {
            Button { showOptions = true; hideTask?.cancel() } label: { Label("Options", systemImage: "slider.horizontal.3") }
            if playback.isLive, let ch = playback.currentChannel {
                Button { _ = state.toggleFavorite(ch.id, kind: .channel) } label: { Label(state.isFavorite(ch.id) ? "Remove from Favourites" : "Add to Favourites", systemImage: state.isFavorite(ch.id) ? "heart.slash" : "heart") }
                if playback.hasPreviousChannel { Button { playback.playPreviousChannel() } label: { Label("Last Channel", systemImage: "arrow.uturn.backward") } }
                if playback.queue.count > 1 { Button { showNumberPad = true } label: { Label("Go to Channel Number", systemImage: "number") } }
                Button { addToMultiView(ch) } label: { Label("Add to Multi-View", systemImage: "rectangle.split.2x2") }
                CollectionMenu(itemID: ch.id, kind: .channel)
            }
            if !playback.isLive {
                Button { playback.seek(by: 85); showHUD(GestureHUD(symbol: "forward.fill", label: "+85 s", level: nil), hideAfter: 0.8) } label: { Label("Skip 85 Seconds", systemImage: "forward.fill") }
                if playback.currentSeries != nil { Button { showEpisodes = true } label: { Label("Episodes", systemImage: "list.number") } }
                if let q = container?.watchQueue, !q.items.isEmpty {
                    Menu {
                        ForEach(q.items) { item in
                            Menu(item.title) {
                                Button("Play Now") { q.remove(item.id); container?.play(queued: item) { _ in } }
                                Button("Remove from Queue") { q.remove(item.id) }
                            }
                        }
                        Button("Clear Queue", role: .destructive) { q.clear() }
                    } label: { Label("Up Next (\(q.items.count))", systemImage: "list.bullet") }
                }
            }
            if playback.isCatchup { Button { playback.goLiveFromCatchup() } label: { Label("Go Live", systemImage: "dot.radiowaves.left.and.right") } }
            if let ch = playback.currentChannel, ch.archiveDays > 0 { Button { showCatchUp = true } label: { Label("Earlier Programmes", systemImage: "clock.arrow.circlepath") } }
            Divider()
            Button { setFill(!fill) } label: { Label(fill ? "Fit to Screen" : "Fill Screen", systemImage: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
            pipButton
            Menu {
                ForEach(SleepTimer.presets, id: \.self) { m in Button("Stop after \(m) minutes") { playback.startSleepTimer(minutes: m) } }
                if !playback.isLive, playback.duration != nil { Button("Stop at the end") { playback.startSleepTimerAtEndOfItem() } }
                if playback.sleepTimer != nil { Divider(); Button("Cancel Sleep Timer", role: .destructive) { playback.cancelSleepTimer() } }
            } label: { Label("Sleep Timer", systemImage: playback.sleepTimer == nil ? "moon.zzz" : "moon.zzz.fill") }
            ExternalPlayerMenu(playback: playback)
            Button { locked = true; withAnimation { showControls = false }; showHUD(GestureHUD(symbol: "lock.fill", label: "Controls locked", level: nil), hideAfter: 1.2) } label: { Label("Lock Controls", systemImage: "lock") }
            Divider()
            Button(role: .destructive) { playback.stop(); playback.isExpanded = false } label: { Label("Stop", systemImage: "stop.fill") }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 20)).frame(width: 44, height: 44)
        }
        .accessibilityLabel("More")
    }

    @ViewBuilder private var pipButton: some View {
        if AVPictureInPictureController.isPictureInPictureSupported() {
            #if STREAMSETU_MPV
            if playback.activeEngine == .mpv {
                Button { mpvPiP.toggle() } label: { Label("Picture in Picture", systemImage: mpvPiP.isActive ? "pip.exit" : "pip.enter") }
            } else {
                Button { pip.toggle() } label: { Label("Picture in Picture", systemImage: pip.isActive ? "pip.exit" : "pip.enter") }.disabled(!pip.isPossible)
            }
            #else
            Button { pip.toggle() } label: { Label("Picture in Picture", systemImage: pip.isActive ? "pip.exit" : "pip.enter") }.disabled(!pip.isPossible)
            #endif
        }
    }

    private var transport: some View {
        HStack(spacing: landscape ? 56 : 44) {
            if playback.isLive {
                Button { playback.previousChannelInList(); scheduleHide() } label: { Image(systemName: "backward.end.fill").font(.system(size: 26)).frame(width: 52, height: 52) }.accessibilityLabel("Previous channel")
            } else {
                Button { playback.seek(by: -10); scheduleHide() } label: { Image(systemName: "gobackward.10").font(.system(size: 32)).frame(width: 52, height: 52) }.accessibilityLabel("Back 10 seconds")
            }
            Button { playback.togglePause(); scheduleHide() } label: {
                Image(systemName: playback.state == .playing || playback.state == .buffering ? "pause.fill" : "play.fill").font(.system(size: 44)).frame(width: 72, height: 72)
            }.accessibilityLabel(playback.state == .playing ? "Pause" : "Play")
            if playback.isLive {
                Button { playback.nextChannel(); scheduleHide() } label: { Image(systemName: "forward.end.fill").font(.system(size: 26)).frame(width: 52, height: 52) }.accessibilityLabel("Next channel")
            } else {
                Button { playback.seek(by: 30); scheduleHide() } label: { Image(systemName: "goforward.30").font(.system(size: 32)).frame(width: 52, height: 52) }.accessibilityLabel("Forward 30 seconds")
            }
        }
    }

    /// Minimal bottom: the seek bar (movies), one line of times, then the always-visible stream details. Live TV has only two buttons.
    private var bottomBar: some View {
        VStack(spacing: 6) {
            if !playback.isLive, let duration = playback.duration, duration > 0 {
                ScrubBar(position: playback.position, duration: duration, scrubbing: $scrubbing, marks: playback.chapters.map(\.time),
                         began: { hideTask?.cancel() },
                         ended: { t in playback.seek(to: t); scrubbing = nil; scheduleHide() })
                HStack {
                    Text(DurationFormatter.clock(scrubbing ?? playback.position)).monospacedDigit()
                    Spacer()
                    let left = max(0, duration - (scrubbing ?? playback.position))
                    Text("Ends " + Date().addingTimeInterval(left / max(0.25, playback.rate)).formatted(date: .omitted, time: .shortened)).monospacedDigit()
                    Spacer()
                    Text("-" + DurationFormatter.clock(left)).monospacedDigit()
                }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 8) {
                // The details scroll sideways if they do not all fit, so the row can never push the controls past the screen edge.
                ScrollView(.horizontal, showsIndicators: false) {
                    if streamInfo, infoVisible { StreamInfoChips(playback: playback, fill: fill, setFill: setFill, setSpeed: setSpeed, addSubtitle: { importingSubtitle = true; hideTask?.cancel() }) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .scrollBounceBehavior(.basedOnSize)
                if playback.isLive {
                    if playback.queue.count > 1 { tool("Channels", "list.bullet", label: true) { showChannels = true; showControls = false } }
                    tool("Guide", "calendar", label: true) { showGuide.toggle() }
                } else if playback.upNext != nil {
                    tool("Next Episode", "forward.end", label: true) { playback.playNextEpisode() }
                }
            }
            .font(.system(size: 15, weight: .medium))
        }
    }

    /// One button in the bottom row: at least 44 points square, and a spoken label.
    private func tool(_ title: String, _ symbol: String, label: Bool, action: @escaping () -> Void) -> some View {
        Button { action(); scheduleHide() } label: {
            Group { if label { Label(title, systemImage: symbol).labelStyle(.titleAndIcon) } else { Image(systemName: symbol) } }
                .padding(.horizontal, label ? 12 : 0).frame(minWidth: 44, minHeight: 44)
        }.accessibilityLabel(title)
    }

    // MARK: actions

    private func setSpeed(_ r: Double) {
        playback.setRate(r)
        PlayerMemory.setSpeed(r, forSeries: playback.current?.seriesID)
    }

    private func addToMultiView(_ c: Channel) {
        guard let mv = container?.multiView else { return }
        switch mv.add(c) {
        case .full: state.toasts.show("Multi-View is full (4 channels)", symbol: "rectangle.split.2x2")
        case .alreadyShown: state.toasts.show("Already in Multi-View", symbol: "rectangle.split.2x2")
        default: state.toasts.show("Added to Multi-View", symbol: "rectangle.split.2x2")
        }
    }

    private func remind(_ p: EPGProgram) {
        guard let c = container, let name = playback.currentChannel?.name else { return }
        Task {
            if reminded.contains(p.id) { c.reminders.cancel(programID: p.id); reminded.remove(p.id) }
            else if await c.reminders.schedule(program: p, channelName: name) { reminded.insert(p.id); state.toasts.show("Reminder set", symbol: "bell") }
            else { state.toasts.show("Couldn't set the reminder. Check notification permission.", symbol: "bell.slash") }
        }
    }

    /// Saves the picture on screen to Photos. Returns what to tell the person.
    private func saveFrame() -> String {
        guard let image = playback.screenshot() else { return "No picture to save right now." }
        UIImageWriteToSavedPhotosAlbum(UIImage(cgImage: image), nil, nil, nil)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return "Saved. If nothing appears in Photos, allow it in Settings."
    }

    // MARK: behaviour

    private func dismiss() { playback.isExpanded = false }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func showControlsNow() { withAnimation(.easeInOut(duration: 0.2)) { showControls = true }; hideTask?.cancel() }

    private func scheduleHide() {
        hideTask?.cancel()
        guard playback.state == .playing, controlSeconds > 0 else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(controlSeconds * 1_000_000_000))
            if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.25)) { showControls = false; showGuide = false } }
        }
    }

    private func showBanner() {
        bannerTask?.cancel()
        withAnimation { banner = true }
        bannerTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { withAnimation { banner = false } }
        }
    }

    /// A movie or episode that continues where it stopped says so for a few seconds, with a way back to the start.
    private func maybeShowResume() {
        guard !playback.isLive, let r = playback.current, r.startPosition > 5, !resumeShown.contains(r.itemID) else { return }
        resumeShown.insert(r.itemID)
        withAnimation { resumeAt = r.startPosition }
        resumeTask?.cancel()
        resumeTask = Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if !Task.isCancelled { withAnimation { resumeAt = nil } }
        }
    }

    private func sendLog() {
        logNote = "Sending…"
        Task {
            let ok = await DiagnosticsUploader.shared.send(trigger: "manual")
            logNote = ok ? "Log sent. Thank you." : "Couldn't send"
        }
    }
}

// MARK: - mini player

/// What is playing, above the tab bar, once the full player has been dismissed.
struct MiniPlayerBar: View {
    @Environment(\.container) private var container

    var body: some View {
        if let p = container?.playback, p.current != nil, !p.isExpanded {
            HStack(spacing: 12) {
                if let c = p.currentChannel { ChannelLogo(url: c.logoURL, name: c.name, size: 40) }
                else { Image(systemName: "play.rectangle.fill").font(.system(size: 22)).foregroundStyle(ColorTokens.accentDefault).frame(width: 40, height: 40) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(statusText(p)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { p.togglePause() } label: { Image(systemName: p.state == .playing || p.state == .buffering ? "pause.fill" : "play.fill").font(.system(size: 20)).frame(width: 40, height: 40) }.accessibilityLabel("Play or pause")
                Button { p.stop() } label: { Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 40) }.accessibilityLabel("Stop")
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(ColorTokens.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
            .onTapGesture { p.isExpanded = true }
        }
    }

    private func statusText(_ p: PlaybackCoordinator) -> String {
        switch p.state {
        case .failed: "Could not play"
        case .buffering, .resolving, .preparing, .recovering: "Loading…"
        case .paused: "Paused"
        default: p.isLive ? "Live" : (p.subtitle ?? "Playing")
        }
    }
}
