import SwiftUI
import AVKit
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

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var fill: Bool
    let pip: PiPController

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        pip.attach(v.playerLayer)
        return v
    }

    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

#if STREAMSETU_MPV
/// Hosts libmpv's picture (a sample-buffer layer). Used for MKV, RTSP, AVI and other formats Apple's player can't open.
final class MPVHostView: UIView {
    var videoLayer: CALayer? { didSet { oldValue?.removeFromSuperlayer(); if let l = videoLayer { layer.addSublayer(l); setNeedsLayout() } } }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        Trace.log("MPVHostView layout bounds=\(Int(bounds.width))x\(Int(bounds.height)) inWindow=\(window != nil) hidden=\(videoLayer?.isHidden ?? true) hasContents=\(videoLayer?.contents != nil)")
        CATransaction.commit()
    }
}

struct MPVSurface: UIViewRepresentable {
    let layer: CALayer
    var fill: Bool
    func makeUIView(context: Context) -> MPVHostView { let v = MPVHostView(); v.backgroundColor = .black; v.videoLayer = layer; return v }
    func updateUIView(_ v: MPVHostView, context: Context) {
        layer.contentsGravity = fill ? .resizeAspectFill : .resizeAspect
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
    @State private var fill = false
    @State private var drag: CGFloat = 0
    @State private var showChannels = false
    @State private var showCatchUp = false
    @State private var programme: EPGProgram?
    @Environment(\.container) private var container
    @State private var flash: String?
    @State private var flashTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(player: playback.avPlayer, fill: fill, pip: pip).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { location in doubleTap(at: location.x, width: geo.size.width) }
                    .onTapGesture { toggleControls() }
                #if STREAMSETU_MPV
                if playback.activeEngine == .mpv, let mpv = playback.mpvSurface {
                    MPVSurface(layer: mpv, fill: fill).ignoresSafeArea().contentShape(Rectangle())
                        .onTapGesture(count: 2) { location in doubleTap(at: location.x, width: geo.size.width) }
                        .onTapGesture { toggleControls() }
                }
                #endif
                if playback.isAudioOnly { AudioOnlyBackdrop(playback: playback, program: programme).ignoresSafeArea().allowsHitTesting(false) }
                status
                if showControls { controls.transition(.opacity) }
            }
            .overlay { if let flash { FlashLabel(text: flash).transition(.opacity) } }
            .offset(y: max(0, drag))
            .gesture(DragGesture(minimumDistance: 24).onChanged { v in
                // a mostly-vertical drag pulls the player down; a horizontal one is a channel swipe and moves nothing
                drag = abs(v.translation.height) > abs(v.translation.width) ? v.translation.height : 0
            }.onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                if dy > 140, dy > abs(dx) { dismiss() }
                else if playback.isLive, abs(dx) > 90, abs(dx) > abs(dy) * 1.5 { zap(dx < 0 ? 1 : -1) }
                withAnimation(.smooth) { drag = 0 }
            })
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .onAppear { scheduleHide() }
        .task(id: playback.currentChannel?.id) {
            guard let c = container, let id = playback.currentChannel?.id else { programme = nil; return }
            programme = await Task.detached { ((try? c.epgRepo.nowNext(channelIDs: [id], at: Date()))?[id] ?? []).first { $0.isLive() } }.value
        }
        .onChange(of: playback.state) { _, s in if s == .playing { scheduleHide() } else { showControlsNow() } }
        .sheet(isPresented: $showChannels) { ChannelSheet(playback: playback) }
        .sheet(isPresented: $showCatchUp) { if let ch = playback.currentChannel { CatchUpSheet(playback: playback, channel: ch) } }
    }

    // MARK: overlays

    @ViewBuilder private var status: some View {
        switch playback.state {
        case .resolving, .preparing, .buffering, .recovering, .seeking:
            VStack(spacing: 8) { ProgressView().controlSize(.large).tint(.white); if let m = playback.statusMessage { Text(m).font(.caption).foregroundStyle(.white.opacity(0.8)) } }
        case .failed(let e):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
                Text(e.message).multilineTextAlignment(.center).font(.callout)
                Text(e.advice).multilineTextAlignment(.center).font(.footnote).foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 12) {
                    Button("Try Again") { playback.retryNow() }.buttonStyle(.borderedProminent)
                    if playback.isLive && playback.queue.count > 1 { Button("Next Channel") { zap(1) }.buttonStyle(.bordered) }
                    Button("Close") { playback.stop(); dismiss() }.buttonStyle(.bordered)
                }
            }.foregroundStyle(.white).padding(24)
        default: EmptyView()
        }
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer()
                transport
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44) }.accessibilityLabel("Close player")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(playback.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    if playback.isLive { Text("LIVE").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2).background(.red, in: Capsule()) }
                }
                if let s = playback.subtitle, !s.isEmpty { Text(s).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
            }
            Spacer(minLength: 8)
            AirPlayButton().frame(width: 44, height: 44)
            if AVPictureInPictureController.isPictureInPictureSupported() {
                Button { pip.toggle() } label: { Image(systemName: pip.isActive ? "pip.exit" : "pip.enter").font(.system(size: 18)).frame(width: 44, height: 44) }
                    .disabled(!pip.isPossible || playback.activeEngine == .mpv).accessibilityLabel("Picture in Picture")
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 44) {
            if playback.isLive {
                Button { playback.previousChannelInList(); scheduleHide() } label: { Image(systemName: "backward.end.fill").font(.system(size: 26)) }.accessibilityLabel("Previous channel")
            } else {
                Button { playback.seek(by: -10); scheduleHide() } label: { Image(systemName: "gobackward.10").font(.system(size: 32)) }.accessibilityLabel("Back 10 seconds")
            }
            Button { playback.togglePause(); scheduleHide() } label: {
                Image(systemName: playback.state == .playing || playback.state == .buffering ? "pause.fill" : "play.fill").font(.system(size: 44)).frame(width: 72, height: 72)
            }.accessibilityLabel(playback.state == .playing ? "Pause" : "Play")
            if playback.isLive {
                Button { playback.nextChannel(); scheduleHide() } label: { Image(systemName: "forward.end.fill").font(.system(size: 26)) }.accessibilityLabel("Next channel")
            } else {
                Button { playback.seek(by: 10); scheduleHide() } label: { Image(systemName: "goforward.10").font(.system(size: 32)) }.accessibilityLabel("Forward 10 seconds")
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if !playback.isLive, let duration = playback.duration, duration > 0 {
                Slider(value: Binding(get: { scrubbing ?? playback.position }, set: { scrubbing = $0 }), in: 0...duration) { editing in
                    if editing { hideTask?.cancel() } else { if let t = scrubbing { playback.seek(to: t) }; scrubbing = nil; scheduleHide() }
                }
                .tint(ColorTokens.accentDefault)
                HStack {
                    Text(DurationFormatter.clock(scrubbing ?? playback.position)).monospacedDigit()
                    Spacer()
                    Text("-" + DurationFormatter.clock(max(0, duration - (scrubbing ?? playback.position)))).monospacedDigit()
                }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 22) {
                if playback.isLive && playback.queue.count > 1 {
                    Button { showChannels = true } label: { Label("Channels", systemImage: "list.bullet") }
                }
                if !playback.audioTracks.isEmpty || !playback.subtitleTracks.isEmpty { tracksMenu }
                if playback.isCatchup { Button { playback.goLiveFromCatchup() } label: { Label("Go Live", systemImage: "dot.radiowaves.left.and.right") } }
                if let ch = playback.currentChannel, ch.archiveDays > 0 { Button { showCatchUp = true } label: { Label("Earlier", systemImage: "clock.arrow.circlepath") } }
                if playback.upNext != nil { Button { playback.playNextEpisode() } label: { Label("Next Episode", systemImage: "forward.end") } }
                if !playback.isLive { speedMenu }
                sleepMenu
                Button { fill.toggle() } label: { Image(systemName: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.accessibilityLabel(fill ? "Fit to screen" : "Fill screen")
                Spacer()
                Button { playback.stop(); playback.isExpanded = false } label: { Image(systemName: "stop.fill") }.accessibilityLabel("Stop")
            }
            .font(.system(size: 15, weight: .medium)).labelStyle(.titleAndIcon)
        }
    }

    private var tracksMenu: some View {
        Menu {
            if !playback.audioTracks.isEmpty {
                Section("Audio") { ForEach(playback.audioTracks) { t in Button { playback.selectAudio(t.id) } label: { Label(t.label, systemImage: t.isSelected ? "checkmark" : "") } } }
            }
            if !playback.subtitleTracks.isEmpty {
                Section("Subtitles") {
                    Button { playback.selectSubtitle(nil) } label: { Label("Off", systemImage: playback.subtitleTracks.contains { $0.isSelected } ? "" : "checkmark") }
                    ForEach(playback.subtitleTracks) { t in Button { playback.selectSubtitle(t.id) } label: { Label(t.label, systemImage: t.isSelected ? "checkmark" : "") } }
                }
            }
        } label: { Image(systemName: "captions.bubble") }.accessibilityLabel("Audio and subtitles")
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                Button { playback.setRate(r) } label: { Label(r == 1 ? "Normal" : String(format: "%g×", r), systemImage: playback.rate == r ? "checkmark" : "") }
            }
        } label: { Text(playback.rate == 1 ? "1×" : String(format: "%g×", playback.rate)) }.accessibilityLabel("Speed")
    }

    private var sleepMenu: some View {
        Menu {
            ForEach(SleepTimer.presets, id: \.self) { m in Button("Stop after \(m) minutes") { playback.startSleepTimer(minutes: m) } }
            if !playback.isLive, playback.duration != nil { Button("Stop at the end") { playback.startSleepTimerAtEndOfItem() } }
            if playback.sleepTimer != nil { Divider(); Button("Cancel Sleep Timer", role: .destructive) { playback.cancelSleepTimer() } }
        } label: { Image(systemName: playback.sleepTimer == nil ? "moon.zzz" : "moon.zzz.fill") }.accessibilityLabel("Sleep timer")
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
        guard playback.state == .playing else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.25)) { showControls = false } }
        }
    }

    private func doubleTap(at x: CGFloat, width: CGFloat) {
        guard !playback.isLive else { return }
        let back = x < width / 2
        playback.seek(by: back ? -10 : 10)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        show(back ? "−10 s" : "+10 s")
    }

    /// Swipe to change channel while watching live TV.
    private func zap(_ step: Int) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if step > 0 { playback.nextChannel() } else { playback.previousChannelInList() }
        showControlsNow(); scheduleHide()
    }

    private func show(_ text: String) {
        flashTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) { flash = text }
        flashTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.25)) { flash = nil } }
        }
    }
}

/// A brief label in the middle of the picture ("+10 s").
private struct FlashLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule()).allowsHitTesting(false)
    }
}

/// Channel list while watching live TV.
private struct ChannelSheet: View {
    let playback: PlaybackCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(playback.queue) { c in
                Button { playback.play(channel: c); dismiss() } label: { ChannelRow(channel: c, isPlaying: playback.currentChannel?.id == c.id) }.buttonStyle(.press)
            }
            .listStyle(.plain).navigationTitle("Channels").navigationBarTitleDisplayMode(.inline).clearTopBar()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
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
