import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Controls shown over the video (inline and fullscreen). Fades out after a few seconds of inactivity while playing.
struct PlayerControlsOverlay: View {
    let playback: PlaybackCoordinator
    var program: EPGProgram?
    var nextProgram: EPGProgram?
    var isFullscreenPlayer = false
    var onToggleFullscreen: () -> Void = {}
    var onChannelList: (() -> Void)?
    var onClose: (() -> Void)?

    @Environment(AppSettings.self) private var settings
    @Environment(\.container) private var container
    @Environment(AppState.self) private var appState: AppState?          // the separate player window has none
    @State private var visible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showDiagnostics = false
    @State private var showPicture = false
    @State private var showSearch = false
    @State private var showOnlineSubs = false
    @State private var showGoTo = false
    @State private var dismissedBufferingHint = false
    @State private var size: CGSize = .zero
    @State private var lastDrag: CGSize = .zero
    @State private var overControls = false
    /// A–B repeat points, in seconds (MPV).
    @State private var loopA: Double?
    @State private var loopB: Double?
    /// "Resumed at 42:10 · Start over", shown for a few seconds when a movie continues where it stopped.
    @State private var resumedAt: Double?
    @State private var resumeShownFor: String?
    @State private var upNextDismissedFor: String?
    /// True while any menu is open, so the controls never vanish from under it.
    @State private var menuOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in content.background { if playback.isAudioOnly { AudioOnlyBackdrop(playback: playback, program: program) } }.onAppear { size = g.size }.onChange(of: g.size) { _, n in size = n } }
    }

    private var content: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
                .onContinuousHover { phase in if case .active = phase { reveal() } }
                .onTapGesture(count: 2) { onToggleFullscreen() }
                .onTapGesture { playback.togglePause() }
                .gesture(DragGesture(minimumDistance: 4).onChanged { v in
                    guard playback.videoLayout.zoom > 1 else { return }
                    playback.panVideo(by: CGSize(width: v.translation.width - lastDrag.width, height: v.translation.height - lastDrag.height), container: size)
                    lastDrag = v.translation
                }.onEnded { _ in lastDrag = .zero })
            statusLayer
            if !playback.numberEntry.isEmpty { numberBadge.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(24).allowsHitTesting(false).transition(.opacity) }
            if playback.repeatedBuffering, !dismissedBufferingHint {
                bufferingHint.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 70)
            }
            if showDiagnostics || settings.showDiagnosticsOverlay { DiagnosticsOverlay(metrics: playback.metrics).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.top, 56).padding(Spacing.lg).allowsHitTesting(false) }
            if !(visible || !playback.state.isPlaying), playback.state.isPlaying { detailsLine.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(10).allowsHitTesting(false).transition(.opacity) }
            if let at = resumedAt, !playback.isLive { resumeCard(at).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.top, 70).padding(.trailing, 16).transition(.opacity) }
            if let next = playback.upNext, !playback.isLive, let d = playback.duration, d > 60, d - playback.position < 30, upNextDismissedFor != playback.current?.itemID, playback.state.isPlaying {
                upNextCard(next).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.bottom, 110).padding(.trailing, 16).transition(.opacity)
            }
            if playback.state.isPlaying, let button = skipButton {
                Button { button.action() } label: { Label(button.title, systemImage: "forward.end.fill").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 9) }
                    .buttonStyle(.plain).foregroundStyle(.white).background(.black.opacity(0.65), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.3)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.bottom, 110).padding(.trailing, 16).transition(.opacity)
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .opacity(visible || !playback.state.isPlaying ? 1 : 0)
            .animation(reduceMotion ? nil : AnimationTokens.standard, value: visible)
            if isFullscreenPlayer, playback.isLive, playback.showChannelSwitcher {
                // Opened with Tab, C or Return, or the list button. Esc, a choice or the X button closes it.
                ChannelSwitcherPanel(playback: playback).frame(maxWidth: .infinity, alignment: .leading).transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : AnimationTokens.page, value: playback.showChannelSwitcher)
        .onAppear { reveal() }
        .onChange(of: playback.state) { _, new in
            reveal()
            if new == .playing, !playback.isLive, let r = playback.current, r.startPosition > 5, resumeShownFor != r.itemID {
                resumeShownFor = r.itemID; withAnimation { resumedAt = r.startPosition }
                Task { try? await Task.sleep(nanoseconds: 7_000_000_000); withAnimation { resumedAt = nil } }
            }
        }
        .onChange(of: playback.current?.itemID) { _, _ in loopA = nil; loopB = nil; resumedAt = nil }
        .sheet(isPresented: $showOnlineSubs) { OnlineSubtitleSheet() }
        .sheet(isPresented: $showGoTo) { GoToTimeSheet { playback.goTo($0) } }
        .sheet(isPresented: $showSearch) {
            PlayerSearchSheet(onChannel: { playback.play(channel: $0, queue: playback.queue) }, onMovie: { playback.play(movie: $0) }, onEpisode: { playback.play(episode: $0, series: $1) })
                .frame(width: 520, height: 520)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in menuOpen = true; visible = true }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in menuOpen = false; reveal() }
    }

    // MARK: layers

    /// The channel number being typed, with the channel it would open.
    private var numberBadge: some View {
        let n = Int(playback.numberEntry) ?? 0
        let target = PlaybackCoordinator.channel(number: n, in: playback.queue)
        return VStack(alignment: .trailing, spacing: 4) {
            Text(playback.numberEntry).font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
            Text(target?.name ?? "No channel \(playback.numberEntry)").font(.system(size: 14, weight: .medium)).opacity(0.85).lineLimit(1)
        }
        .foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 12)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("Channel \(playback.numberEntry)\(target.map { ", " + $0.name } ?? ", not available")")
    }

    /// Shown once a stream has stalled three times: two one-click ways to a steadier picture.
    private var bufferingHint: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(ColorTokens.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("This stream keeps buffering").font(.system(size: 12, weight: .semibold))
                Text("Your connection or the provider can't keep up. A bigger buffer or the other player may help.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
            Button("Use bigger buffer") { dismissedBufferingHint = true; playback.useStabilityBufferingForThisPlaylist() }.buttonStyle(.bordered).controlSize(.small)
            if let alt = playback.availableEngines.first(where: { $0 != playback.activeEngine }) {
                Button("Try \(alt.rawValue)") { dismissedBufferingHint = true; playback.switchEngine(alt) }.buttonStyle(.bordered).controlSize(.small)
            }
            Button { dismissedBufferingHint = true } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .transition(.opacity)
    }

    @ViewBuilder private var statusLayer: some View {
        switch playback.state {
        case .resolving, .preparing, .buffering, .seeking, .recovering:
            VStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.large)
                if let m = playback.statusMessage { Text(m).font(Typography.bodyMedium).foregroundStyle(.white.opacity(0.85)) }
                else if playback.state == .recovering { Text("Reconnecting…").font(Typography.bodyMedium).foregroundStyle(.white.opacity(0.85)) }
            }.padding(Spacing.xl).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: LayoutTokens.radius)).allowsHitTesting(false)
        case .failed(let e):
            VStack(spacing: Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundStyle(ColorTokens.warning)
                Text(e.message).font(Typography.bodyMedium).multilineTextAlignment(.center).frame(maxWidth: 360)
                Text(e.advice).font(Typography.caption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).frame(maxWidth: 360)
                HStack {
                    PrimaryButton(title: "Try again", symbol: "arrow.clockwise") { playback.retryNow() }
                    if let alt = playback.availableEngines.first(where: { $0 != playback.activeEngine }) {
                        SecondaryButton(title: "Use \(alt.rawValue)") { playback.switchEngine(alt) }
                    }
                }
            }.padding(Spacing.xl).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: LayoutTokens.radiusLarge))
        case .ended:
            if playback.upNext != nil {
                VStack(spacing: Spacing.sm) {
                    Text("Up next").font(Typography.caption).foregroundStyle(.white.opacity(0.7))
                    PrimaryButton(title: "Play next episode", symbol: "forward.end.fill") { playback.playNextEpisode() }
                }.padding(Spacing.xl).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: LayoutTokens.radiusLarge))
            }
        default: EmptyView()
        }
    }

    // MARK: structured overlay regions

    private var showStreamInfo: Bool { showDiagnostics || settings.showDiagnosticsOverlay }

    /// Top region: what is playing. One line, never wider than the video.
    private var topBar: some View {
        HStack(spacing: 10) {
            if let onClose { IconButton(symbol: "chevron.down", help: "Back", action: onClose) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(playback.title).font(Typography.heading).lineLimit(1).truncationMode(.tail)
                    if playback.isLive { LiveBadge() }
                }
                if showStreamInfo, !technicalSummary.isEmpty {
                    Text(technicalSummary).font(Typography.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                } else if let program {
                    Text("Now: \(program.title)").font(Typography.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1).truncationMode(.tail)
                } else if let s = playback.subtitle, !s.isEmpty {
                    Text(s).font(Typography.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            IconButton(symbol: "magnifyingglass", help: "Search the catalog") { showSearch = true; visible = true }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 24)
        .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
    }

    /// Bottom region: progress on the first row, controls on the second. The second row picks the richest layout that fits
    /// the width it is given, so controls are never squeezed or stacked on top of each other.
    private var bottomBar: some View {
        VStack(spacing: 8) {
            progressRow
            ViewThatFits(in: .horizontal) {
                controlsRow(.full)
                controlsRow(.medium)
                controlsRow(.compact)
            }
        }
        .padding(.horizontal, 14).padding(.top, 24).padding(.bottom, 10)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom))
        .onHover { overControls = $0 }
    }

    @ViewBuilder private var progressRow: some View {
        if playback.isLive {
            if let p = program {
                HStack(spacing: 8) {
                    Text(TimeFormatter.time(p.start)).font(Typography.timestamp).foregroundStyle(.white.opacity(0.7))
                    ProgressBar(fraction: p.progress(), height: 3)
                    Text(TimeFormatter.time(p.end)).font(Typography.timestamp).foregroundStyle(.white.opacity(0.7))
                }
            }
        } else if let d = playback.duration {
            HStack(spacing: 10) {
                Text(DurationFormatter.clock(playback.position)).font(Typography.timestamp)
                SeekBar(position: playback.position, duration: d) { playback.seek(to: $0) }
                Text("Ends " + Date().addingTimeInterval(max(0, d - playback.position) / max(0.25, playback.rate)).formatted(date: .omitted, time: .shortened)).font(Typography.timestamp).foregroundStyle(.white.opacity(0.7))
                Text("-" + DurationFormatter.clock(max(0, d - playback.position))).font(Typography.timestamp)
            }.foregroundStyle(.white.opacity(0.85))
        }
    }

    private enum RowStyle { case full, medium, compact }

    private func controlsRow(_ style: RowStyle) -> some View {
        HStack(spacing: 8) {
            transport
            volume(slider: style == .full ? 84 : style == .medium ? 56 : nil)
            Spacer(minLength: 8)
            audioMenu
            subtitleMenu
            if style != .compact { qualityMenu; sizeMenu }
            switch style {
            case .full: extras
            case .medium: overflowMenu(includeTracks: false)
            case .compact: overflowMenu(includeTracks: true)
            }
            IconButton(symbol: isFullscreenPlayer ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: isFullscreenPlayer ? "Exit full screen" : "Full screen", action: onToggleFullscreen)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var transport: some View {
        HStack(spacing: 6) {
            if playback.isCatchup { Button { playback.goLiveFromCatchup() } label: { Label("Back to live", systemImage: "dot.radiowaves.left.and.right").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).frame(height: 30).background(ColorTokens.accentDefault, in: Capsule()) }.buttonStyle(.plain).help("Return to the live stream") }
            if playback.isLive, isFullscreenPlayer, playback.queue.count > 1 { IconButton(symbol: "list.bullet", help: "Channels and guide (Tab)", active: playback.showChannelSwitcher) { playback.toggleChannelSwitcher() } }
            if playback.isLive { IconButton(symbol: "backward.end.fill", help: "Previous channel") { playback.previousChannelInList() } }
            if playback.liveRewindAvailable {
                IconButton(symbol: "gobackward.10", help: "Back 10 seconds") { playback.rewindLive(by: 10) }
                livePill
            }
            else { IconButton(symbol: "gobackward.10", help: "Back 10 seconds") { playback.seek(by: -10) } }
            IconButton(symbol: playback.state == .playing || playback.state == .buffering ? "pause.fill" : "play.fill", help: "Play / Pause", size: 38) { playback.togglePause() }
            if playback.isLive { IconButton(symbol: "forward.end.fill", help: "Next channel") { playback.nextChannel() } }
            else {
                IconButton(symbol: "goforward.10", help: "Forward 10 seconds") { playback.seek(by: 10) }
                if playback.upNext != nil { IconButton(symbol: "forward.end.alt.fill", help: "Next episode") { playback.playNextEpisode() } }
            }
        }
    }

    /// "LIVE" at the live edge; otherwise how far behind, and a click to jump back.
    @ViewBuilder private var livePill: some View {
        let behind = playback.behindLive
        if behind > 4 {
            Button { playback.goToLiveEdge() } label: {
                Text("−\(Int(behind) / 60):\(String(format: "%02d", Int(behind) % 60)) · Go live").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).frame(height: 26)
                    .background(Color.white.opacity(0.14), in: Capsule())
            }.buttonStyle(.plain).help("Jump to the live broadcast")
        } else {
            HStack(spacing: 5) { Circle().fill(ColorTokens.live).frame(width: 7, height: 7); Text("LIVE").font(.system(size: 11, weight: .bold)).tracking(0.5) }.padding(.horizontal, 6)
        }
    }

    private var audioMenu: some View {
        ReddyAudioMenu(tracks: playback.audioTracks, delay: playback.audioDelay, delaySupported: playback.capabilities.audioDelay,
                       processing: playback.audioProcessing, processingSupported: playback.capabilities.audioProcessing,
                       onTrack: { playback.selectAudio($0) }, onDelay: { playback.setAudioDelay($0) }, onProcessing: { playback.setAudioProcessing($0) },
                       channelTrim: playback.isLive && playback.currentChannel != nil ? playback.channelVolumeTrim : nil, onTrim: { playback.setChannelVolumeTrim($0) })
    }

    private var subtitleMenu: some View {
        ReddySubtitleMenu(tracks: playback.subtitleTracks, delay: playback.subtitleDelay, delaySupported: playback.capabilities.subtitleDelay,
                          onTrack: { playback.selectSubtitle($0) }, onDelay: { playback.setSubtitleDelay($0) },
                          onLoadFile: playback.capabilities.externalSubtitles ? { chooseSubtitleFile() } : nil)
    }

    private var qualityMenu: some View {
        ReddyQualityMenu(options: playback.qualityOptions, selectedID: playback.selectedQualityID, supported: playback.capabilities.qualitySelection,
                         technical: technicalSummary, onSelect: { playback.selectQuality($0) })
    }

    private var sizeMenu: some View {
        ReddyVideoSizeMenu(layout: playback.videoLayout, hasOverride: playback.hasItemLayoutOverride,
                           onMode: { playback.setVideoSizeMode($0) }, onAspect: { playback.setAspectRatio($0) }, onZoom: { playback.setZoom($0) },
                           onReset: { playback.resetVideoLayout() }, onRemember: { playback.rememberLayoutForThisItem() },
                           onForget: { playback.removeItemLayoutOverride() }, onApplyGlobal: { playback.applyLayoutAsGlobalDefault() })
    }

    /// Less-used controls, shown inline when there is room.
    @ViewBuilder private var extras: some View {
        if !playback.isLive { speedMenu }
        if playback.availableEngines.count > 1 { engineMenu }
        if playback.activeEngine == .avPlayer, PiPManager.shared.isSupported { IconButton(symbol: "pip.enter", help: "Picture in Picture") { PiPManager.shared.toggle() } }
        if playback.activeEngine == .avPlayer { AirPlayButton().frame(width: 32, height: 32) }
        extrasMenu
        sleepMenu
        if playback.capabilities.pictureAdjustments { pictureButton }
        if hasTools { toolsMenu }
        if playback.canRecord || playback.recording != nil { recordChip }
        if !playback.isLive, let q = container?.watchQueue, !q.items.isEmpty { queueMenu(q) }
        if playback.screenshotSupported { IconButton(symbol: "camera", help: "Save screenshot") { saveScreenshot() } }
        IconButton(symbol: "info.circle", help: "Stream info", active: showDiagnostics) { showDiagnostics.toggle() }
    }

    /// The same controls gathered into one menu when the row is narrow.
    private func overflowMenu(includeTracks: Bool) -> some View {
        Menu {
            if includeTracks {
                if playback.capabilities.qualitySelection, !playback.qualityOptions.isEmpty {
                    Section("Quality") { ForEach(playback.qualityOptions) { q in Button { playback.selectQuality(q.id) } label: { Label(q.label, systemImage: playback.selectedQualityID == q.id ? "checkmark" : "") } } }
                }
                Section("Video size") { ForEach(VideoSizeMode.allCases) { m in Button { playback.setVideoSizeMode(m) } label: { Label(m.rawValue, systemImage: playback.videoLayout.mode == m ? "checkmark" : "") } } }
            }
            if !playback.isLive {
                Section("Speed") { ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Button { playback.setRate(r) } label: { Label(r == 1 ? "Normal" : "\(r.formatted())×", systemImage: playback.rate == r ? "checkmark" : "") } } }
            }
            if playback.availableEngines.count > 1 {
                Section("Engine") { ForEach(Array(playback.availableEngines).sorted { $0.rawValue < $1.rawValue }) { e in Button { playback.switchEngine(e) } label: { Label(e.rawValue, systemImage: e == playback.activeEngine ? "checkmark" : "") } } }
            }
            if playback.activeEngine == .avPlayer, PiPManager.shared.isSupported { Button("Picture in Picture") { PiPManager.shared.toggle() } }
            Section("This Title") { extrasItems }
            Menu("Sleep Timer") {
                ForEach(SleepTimer.presets, id: \.self) { m in Button("Stop after \(m) minutes") { playback.startSleepTimer(minutes: m) } }
                if playback.sleepTimer != nil { Divider(); Button("Cancel Sleep Timer") { playback.cancelSleepTimer() } }
            }
            ExternalPlayerMenu(playback: playback)
            if hasTools { Menu("More Tools") { toolItems } }
            if playback.screenshotSupported { Button("Save Screenshot") { saveScreenshot() } }
            Button(showDiagnostics ? "Hide Stream Info" : "Show Stream Info") { showDiagnostics.toggle() }
        } label: { chip("ellipsis") }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("More controls").accessibilityLabel("More controls")
    }

    // MARK: tools only some players have

    /// The one skip button offered right now: the recap, the opening or the credits.
    private var skipButton: (title: String, action: () -> Void)? {
        if playback.recapEnd != nil { return ("Skip Recap", { playback.skipRecap() }) }
        if playback.introEnd != nil { return ("Skip Intro", { playback.skipIntro() }) }
        if playback.creditsShowing { return ("Skip Credits", { playback.skipCredits() }) }
        return nil
    }

    private var hasTools: Bool { playback.capabilities.chapters || playback.capabilities.abLoop || playback.capabilities.frameStep || playback.capabilities.volumeBoost }

    /// The red dot that starts and stops recording the channel being watched; while it records it shows how long.
    private var recordChip: some View {
        Button {
            if playback.recording != nil { playback.stopRecording(); appState?.toasts.show("Recording saved. Find it in Settings > Library > Recordings.", symbol: "record.circle") }
            else { playback.startRecording { appState?.toasts.show($0, symbol: "exclamationmark.triangle.fill", kind: .warning) } }
        } label: {
            if let r = playback.recording {
                TimelineView(.periodic(from: r.since, by: 1)) { ctx in
                    HStack(spacing: 5) { Circle().fill(.red).frame(width: 8, height: 8); Text(DurationFormatter.clock(ctx.date.timeIntervalSince(r.since))).font(.system(size: 12, weight: .semibold).monospacedDigit()) }
                        .padding(.horizontal, 8).frame(height: 28)
                }
            } else { chip("record.circle") }
        }
        .buttonStyle(.plain).help(playback.recording != nil ? "Stop recording" : "Record this channel").accessibilityLabel(playback.recording != nil ? "Stop recording" : "Record this channel")
    }

    /// What is lined up to play next: each title can be taken out, or played now.
    private func queueMenu(_ q: WatchQueue) -> some View {
        Menu {
            Section("Up next (\(q.items.count))") {
                ForEach(q.items) { item in
                    Menu(item.title) {
                        Button("Play Now") { q.remove(item.id); if let c = container { PlayActions(container: c, toasts: appState?.toasts ?? ToastCenter()).play(item) } }
                        Button("Remove from Queue") { q.remove(item.id) }
                    }
                }
            }
            Button("Clear Queue", role: .destructive) { q.clear() }
        } label: { chip("list.bullet") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Up next: \(q.items.count) in the queue").accessibilityLabel("Queue")
    }

    private var toolsMenu: some View {
        Menu { toolItems } label: { chip("wand.and.stars") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Chapters, repeat, frame step, volume boost").accessibilityLabel("More tools")
    }

    @ViewBuilder private var toolItems: some View {
        if !playback.chapters.isEmpty {
            Section("Chapters") { ForEach(playback.chapters) { c in Button("\(c.title)  \(DurationFormatter.clock(c.time))") { playback.seek(to: c.time) } } }
        }
        if !playback.isLive, playback.capabilities.abLoop {
            Section("Repeat a part") {
                Button(loopA == nil ? "Set start here" : "Start: \(DurationFormatter.clock(loopA!))") { loopA = playback.position; applyLoop() }
                Button(loopB == nil ? "Set end here" : "End: \(DurationFormatter.clock(loopB!))") { loopB = playback.position; applyLoop() }.disabled(loopA == nil)
                if loopA != nil || loopB != nil { Button("Clear repeat") { loopA = nil; loopB = nil; applyLoop() } }
            }
        }
        if playback.capabilities.frameStep {
            Section("Frame by frame") {
                Button("Back one frame") { playback.frameStep(forward: false) }
                Button("Forward one frame") { playback.frameStep(forward: true) }
            }
        }
        if playback.capabilities.volumeBoost {
            Toggle("Volume boost (up to 130%)", isOn: Binding(get: { playback.volumeBoost }, set: { playback.volumeBoost = $0 }))
        }
    }

    private func applyLoop() { playback.setLoop(start: loopA, end: loopA != nil && loopB != nil ? loopB : nil) }

    // MARK: cards and the quiet line

    /// One small faint line along the bottom edge while the controls are hidden: picture size, format and sound.
    private var detailsLine: some View {
        let m = playback.metrics
        let audio = playback.audioTracks.first(where: { $0.isSelected }) ?? playback.audioTracks.first
        let name: String? = audio.flatMap { PlayerMath.isGenericTrackLabel($0.label) ? nil : $0.label } ?? m.audioCodec.map { PlayerMath.audioCodecLabel($0) }
        let parts: [String?] = [m.height > 0 ? PlayerMath.qualityLabel(width: m.width, height: m.height) : nil, m.videoCodec.map { PlayerMath.videoCodecLabel($0) }, name]
        return Text(parts.compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11, weight: .medium)).monospacedDigit()
            .foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.35), in: Capsule())
    }

    private func resumeCard(_ at: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle")
            Text("Resumed at \(DurationFormatter.clock(at))").font(Typography.bodyMedium)
            Button("Start over") { playback.seek(to: 0); withAnimation { resumedAt = nil } }.buttonStyle(.plain).foregroundStyle(ColorTokens.accentDefault).font(Typography.bodyMedium)
            Button { withAnimation { resumedAt = nil } } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8).background(.black.opacity(0.72), in: Capsule())
    }

    private func upNextCard(_ e: Episode) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Up next").font(Typography.caption).foregroundStyle(.white.opacity(0.7))
                Text("S\(e.seasonNumber) E\(e.episodeNumber) · \(e.title)").font(Typography.bodyMedium).lineLimit(1)
            }
            PrimaryButton(title: "Play now", symbol: "play.fill") { playback.playNextEpisode() }
            Button { upNextDismissedFor = playback.current?.itemID } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 10).background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func chip(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 32).background(Color.white.opacity(0.08), in: Circle())
    }

    @ViewBuilder private func volume(slider width: CGFloat?) -> some View {
        HStack(spacing: 6) {
            IconButton(symbol: playback.isMuted || playback.volume == 0 ? "speaker.slash.fill" : playback.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill", help: playback.isMuted ? "Unmute" : "Mute") { playback.isMuted.toggle() }
            if let width {
                Slider(value: Binding(get: { playback.isMuted ? 0 : playback.volume }, set: { playback.volume = $0; playback.isMuted = false }), in: 0...1)
                    .frame(width: width).controlSize(.small).accessibilityLabel("Volume")
            }
        }
    }

    private var technicalSummary: String {
        let m = playback.metrics
        var parts: [String] = []
        if m.width > 0 { parts.append(m.resolution) }
        if let f = m.frameRate, f > 0 { parts.append(String(format: "%.0f fps", f)) }
        if let v = m.videoCodec { parts.append(v) }
        if m.observedBitrate > 0 { parts.append(m.bitrateText) }
        return parts.joined(separator: " · ")
    }

    /// "Stop playback after…". While one is running the icon is lit and the menu says how long is left.
    @ViewBuilder private var extrasItems: some View {
        if !playback.isLive { Button("Go to Time…") { showGoTo = true } }
        Button("Find Subtitles Online…") { showOnlineSubs = true }
        Toggle("Remember Settings for This Title", isOn: Binding(get: { playback.remembersPerTitle }, set: { playback.remembersPerTitle = $0 }))
    }

    private var extrasMenu: some View {
        Menu { extrasItems } label: { chip("slider.horizontal.3") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Go to a time, subtitles online, remembered settings").accessibilityLabel("Title options")
    }

    private var sleepMenu: some View {
        Menu {
            if let t = playback.sleepTimer {
                TimelineView(.periodic(from: .now, by: 1)) { _ in Text("Stops in \(SleepTimer.label(forRemaining: t.remaining()))") }
                Button("Cancel Sleep Timer") { playback.cancelSleepTimer() }
                Divider()
            }
            ForEach(SleepTimer.presets, id: \.self) { m in Button("Stop after \(m) minutes") { playback.startSleepTimer(minutes: m) } }
            if !playback.isLive, playback.duration != nil { Button("Stop at the end") { playback.startSleepTimerAtEndOfItem() } }
        } label: {
            Image(systemName: playback.sleepTimer == nil ? "moon.zzz" : "moon.zzz.fill").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 32)
                .background(Color.white.opacity(0.08), in: Circle()).foregroundStyle(playback.sleepTimer == nil ? ColorTokens.textPrimary : ColorTokens.accentDefault)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Sleep timer").accessibilityLabel("Sleep timer")
    }

    private var pictureButton: some View {
        IconButton(symbol: "slider.horizontal.3", help: "Picture: brightness, contrast, colour", active: !playback.picture.isDefault) { showPicture.toggle() }
            .popover(isPresented: $showPicture, arrowEdge: .top) { ReddyPicturePanel(picture: playback.picture) { playback.setPicture($0) } }
    }

    /// Opens a file chooser for a subtitle file and hands the choice to the player.
    private func chooseSubtitleFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Subtitle File"
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt", "sub", "sup"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !playback.loadSubtitleFile(url) { NSSound.beep() }
    }

    private var engineMenu: some View {
        Menu {
            ForEach(Array(playback.availableEngines).sorted { $0.rawValue < $1.rawValue }) { e in
                Button { playback.switchEngine(e) } label: { Label(e.rawValue, systemImage: e == playback.activeEngine ? "checkmark" : "") }
            }
            if playback.isLive, playback.currentChannel != nil {
                Divider()
                Section("Always use for this channel") {
                    ForEach(PlaybackEnginePreference.allCases) { pref in
                        Button { playback.setChannelEnginePreference(pref == .automatic ? nil : pref) } label: {
                            Label(pref == .automatic ? "Follow playlist and app setting" : pref.rawValue, systemImage: (playback.channelEnginePreference ?? .automatic) == pref ? "checkmark" : "")
                        }
                    }
                }
            }
        } label: { Image(systemName: "cpu").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 32).background(Color.white.opacity(0.08), in: Circle()) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Player engine")
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                Button { playback.setRate(r) } label: { Label(r == 1 ? "Normal" : "\(r.formatted())×", systemImage: playback.rate == r ? "checkmark" : "") }
            }
        } label: {
            Text(playback.rate == 1 ? "1×" : "\(playback.rate.formatted())×").font(Typography.captionMedium).frame(width: 40, height: 32).background(Color.white.opacity(0.08), in: Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Playback speed")
    }

    // MARK: helpers

    private func reveal() {
        visible = true
        NSCursor.setHiddenUntilMouseMoves(false)
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled, !overControls, !menuOpen, !NSWorkspace.shared.isVoiceOverEnabled, !NSApplication.shared.isFullKeyboardAccessEnabled {
                visible = false
                if playback.state == .playing && isFullscreenPlayer { NSCursor.setHiddenUntilMouseMoves(true) }
            }
        }
    }

    private func saveScreenshot() {
        guard let img = playback.screenshot() else { return }
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("StreamSetu", isDirectory: true)
        StorageService.ensure(dir)
        let name = "\(playback.title) \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))).png".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let rep = NSBitmapImageRep(cgImage: img)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: dir.appendingPathComponent(name)) }
    }
}

struct DiagnosticsOverlay: View {
    let metrics: PlaybackMetrics
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Stream info").font(Typography.captionMedium)
            row("Engine", metrics.engine.rawValue); row("Container", metrics.container.rawValue.uppercased())
            row("Resolution", metrics.resolution); if let f = metrics.frameRate, f > 0 { row("Frame rate", String(format: "%.0f fps", f)) }
            row("Bitrate", metrics.bitrateText)
            if let v = metrics.videoCodec { row("Video", v) }; if let a = metrics.audioCodec { row("Audio", a) }
            row("Buffer", String(format: "%.1f s", metrics.bufferedAheadSeconds)); row("Stalls", "\(metrics.stallCount)")
            row("Dropped frames", "\(metrics.droppedFrames)")
            if let s = metrics.startupSeconds { row("Startup", String(format: "%.1f s", s)) }
            row("Host", metrics.host)
        }
        .font(Typography.mono).padding(Spacing.md)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: LayoutTokens.radius))
        .foregroundStyle(.white)
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.white.opacity(0.6)).frame(width: 110, alignment: .leading); Text(v) }
    }
}
