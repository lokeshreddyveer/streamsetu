import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - remembered choices

/// What the player remembers per title: Fill or Fit.
enum PlayerMemory {
    private static func key(_ id: String) -> String { "player.fill." + id }

    static func fill(for id: String?) -> Bool? {
        guard let id, UserDefaults.standard.object(forKey: key(id)) != nil else { return nil }
        return UserDefaults.standard.bool(forKey: key(id))
    }

    static func setFill(_ on: Bool, for id: String?) {
        guard let id else { return }
        UserDefaults.standard.set(on, forKey: key(id))
    }
}

// MARK: - scrub bar

/// A larger seek bar: a thick track with a big touch area, a handle that grows while it is held, and a time shown above the finger.
struct ScrubBar: View {
    let position: Double
    let duration: Double
    @Binding var scrubbing: Double?
    /// Chapter starts, drawn as small ticks on the track.
    var marks: [Double] = []
    var began: () -> Void
    var ended: (Double) -> Void
    @State private var active = false

    var body: some View {
        GeometryReader { g in
            let value = scrubbing ?? position
            let fraction = duration > 0 ? min(1, max(0, value / duration)) : 0
            let thick: CGFloat = active ? 10 : 6
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: thick)
                Capsule().fill(ColorTokens.accentDefault).frame(width: max(thick, g.size.width * fraction), height: thick)
                ForEach(marks.filter { $0 > 1 && $0 < duration - 1 }, id: \.self) { m in
                    Rectangle().fill(.white.opacity(0.85)).frame(width: 2, height: thick + 4).offset(x: g.size.width * min(1, m / max(1, duration)) - 1)
                }
                Circle().fill(.white).frame(width: active ? 24 : 16, height: active ? 24 : 16)
                    .offset(x: min(max(0, g.size.width * fraction - (active ? 12 : 8)), g.size.width - (active ? 24 : 16)))
                    .shadow(color: .black.opacity(0.4), radius: 3)
                if active {
                    Text(DurationFormatter.clock(value)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.7), in: Capsule())
                        .offset(x: min(max(0, g.size.width * fraction - 24), g.size.width - 52), y: -30)
                }
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !active { active = true; began() }
                    scrubbing = min(1, max(0, v.location.x / max(1, g.size.width))) * duration
                }
                .onEnded { v in
                    let t = min(1, max(0, v.location.x / max(1, g.size.width))) * duration
                    active = false
                    ended(t)
                })
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Seek")
        .accessibilityValue("\(DurationFormatter.clock(position)) of \(DurationFormatter.clock(duration))")
        .accessibilityAdjustableAction { direction in
            let step = 10.0
            switch direction {
            case .increment: ended(min(duration, position + step))
            case .decrement: ended(max(0, position - step))
            @unknown default: break
            }
        }
    }
}

/// A thin line along the bottom edge that shows progress while the controls are hidden.
struct ProgressLine: View {
    let position: Double
    let duration: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.18))
                Rectangle().fill(ColorTokens.accentDefault).frame(width: g.size.width * min(1, max(0, duration > 0 ? position / duration : 0)))
            }
        }
        .frame(height: 3).allowsHitTesting(false).accessibilityHidden(true)
    }
}

// MARK: - gesture indicator

/// What the brightness, volume, speed and fill gestures are doing right now.
struct GestureHUD: Equatable {
    var symbol: String
    var label: String
    /// 0...1 for brightness and volume, nil for a one-off message.
    var level: Double?
}

struct GestureHUDView: View {
    let hud: GestureHUD
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hud.symbol).font(.system(size: 18, weight: .semibold))
            if let level = hud.level {
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white).frame(width: 110 * level)
                }.frame(width: 110, height: 5)
            }
            Text(hud.label).font(.system(size: 14, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 11)
        .background(.black.opacity(0.62), in: Capsule()).allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - cards on the picture

/// "Resumed at 42:10 · Start over", shown briefly when a movie or episode continues where it stopped.
struct ResumeCard: View {
    let position: Double
    var startOver: () -> Void
    var dismiss: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle").font(.system(size: 20))
            Text("Resumed at \(DurationFormatter.clock(position))").font(.system(size: 14, weight: .medium))
            Button("Start over") { startOver() }.font(.system(size: 14, weight: .semibold)).foregroundStyle(ColorTokens.accentDefault)
                .frame(minHeight: 44)
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 32, height: 44) }.accessibilityLabel("Dismiss")
        }
        .foregroundStyle(.white).padding(.horizontal, 14)
        .background(.black.opacity(0.72), in: Capsule())
    }
}

/// "Up next" near the end of an episode.
struct NextEpisodeCard: View {
    let episode: Episode
    var play: () -> Void
    var dismiss: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Up next").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                Text("S\(episode.seasonNumber) E\(episode.episodeNumber) · \(episode.title)").font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            Button { play() } label: { Label("Play Now", systemImage: "play.fill").font(.system(size: 14, weight: .semibold)) }
                .buttonStyle(.borderedProminent).tint(ColorTokens.accentDefault)
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 32, height: 44) }.accessibilityLabel("Dismiss")
        }
        .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The channel just tuned: number, name and what is on now.
struct ChannelBanner: View {
    let channel: Channel
    let number: Int?
    let programme: EPGProgram?
    var body: some View {
        HStack(spacing: 12) {
            ChannelLogo(url: channel.logoURL, name: channel.name, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if let number { Text("\(number)").font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(.white.opacity(0.7)) }
                    Text(channel.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                }
                if let p = programme {
                    Text(p.title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    ProgressView(value: min(1, max(0, Date().timeIntervalSince(p.start) / max(1, p.end.timeIntervalSince(p.start))))).tint(ColorTokens.accentDefault).frame(maxWidth: 180)
                }
            }
        }
        .foregroundStyle(.white).padding(12)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Now and next for the channel, from the guide.
struct MiniGuideCard: View {
    let programmes: [EPGProgram]
    var reminded: Set<Int64> = []
    var remind: (EPGProgram) -> Void = { _ in }
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("On this channel").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 32, height: 32) }.accessibilityLabel("Close guide")
            }
            if programmes.isEmpty { Text("No guide information for this channel.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)) }
            ForEach(programmes.prefix(4), id: \.start) { p in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(p.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.white.opacity(0.65)).frame(width: 64, alignment: .leading)
                    Text(p.title).font(.system(size: 14, weight: p.isLive() ? .semibold : .regular)).lineLimit(1)
                    if p.isLive() { Text("NOW").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2).background(.red, in: Capsule()) }
                    Spacer(minLength: 0)
                    if p.start > Date() {
                        Button { remind(p) } label: { Image(systemName: reminded.contains(p.id) ? "bell.fill" : "bell").frame(width: 36, height: 36) }.accessibilityLabel(reminded.contains(p.id) ? "Reminder set" : "Remind me")
                    }
                }
            }
        }
        .foregroundStyle(.white).padding(14).frame(maxWidth: 360)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Channels as a panel that slides in from the side.
struct ChannelSidePanel: View {
    let playback: PlaybackCoordinator
    var leading = false
    var close: () -> Void
    @State private var query = ""
    @State private var folder: String?

    private var folders: [String] { Array(Set(playback.queue.compactMap(\.categoryName))).sorted() }
    private var shown: [(Int, Channel)] {
        playback.queue.enumerated().map { ($0.offset + 1, $0.element) }.filter { n, c in
            (folder == nil || c.categoryName == folder) && (query.isEmpty || c.name.localizedCaseInsensitiveContains(query) || String(n) == query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Channels").font(.system(size: 16, weight: .semibold))
                Spacer()
                if folders.count > 1 {
                    Menu {
                        Button { folder = nil } label: { Label("All channels", systemImage: folder == nil ? "checkmark" : "") }
                        ForEach(folders, id: \.self) { f in Button { folder = f } label: { Label(f, systemImage: folder == f ? "checkmark" : "") } }
                    } label: { Image(systemName: "folder").frame(width: 44, height: 44) }.accessibilityLabel("Folders")
                }
                Button { close() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 44, height: 44) }.accessibilityLabel("Close channel list")
            }.padding(.leading, 16)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                TextField("Search or number", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .padding(10).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 12).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown, id: \.1.id) { n, c in
                            Button { playback.play(channel: c); close() } label: {
                                ChannelRow(channel: c, isPlaying: playback.currentChannel?.id == c.id, number: n)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(playback.currentChannel?.id == c.id ? Color.white.opacity(0.1) : .clear)
                            }.buttonStyle(.plain).id(c.id)
                        }
                    }
                }
                .onAppear { if let id = playback.currentChannel?.id { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .foregroundStyle(.white)
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.88))
    }
}

/// Over the picture while a stream is starting or being retried: what is happening and, when waiting on the provider, what to do.
struct StatusCard: View {
    let state: PlaybackState
    let message: String?
    var offline = false
    var stop: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large).tint(.white)
            Text(headline).font(.system(size: 15, weight: .semibold))
            if let message, !message.isEmpty { Text(message.loc).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center) }
            if state == .recovering { Button("Stop waiting") { stop() }.buttonStyle(.bordered).tint(.white) }
        }
        .foregroundStyle(.white).padding(20).frame(maxWidth: 320)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if offline { return "No internet connection" }
        switch state {
        case .recovering: return "Waiting for your provider…"
        case .seeking: return "Jumping…"
        case .buffering: return "Buffering…"
        default: return "Starting…"
        }
    }
}

/// The picture when a stream has failed for good: what happened, and what can be done.
struct FailureCard: View {
    let error: PlaybackError
    let isLive: Bool
    let canZap: Bool
    @Binding var logNote: String?
    var retry: () -> Void
    var nextChannel: () -> Void
    var sendLog: () -> Void
    var close: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
            Text(error.message).multilineTextAlignment(.center).font(.system(size: 16, weight: .semibold))
            Text(error.advice).multilineTextAlignment(.center).font(.footnote).foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 10) {
                Button("Try Again") { retry() }.buttonStyle(.borderedProminent).tint(ColorTokens.accentDefault)
                if isLive && canZap { Button("Next Channel") { nextChannel() }.buttonStyle(.bordered).tint(.white) }
                Button("Close") { close() }.buttonStyle(.bordered).tint(.white)
            }
            Button { sendLog() } label: { Label(logNote ?? "Send My Log", systemImage: "paperplane") }.font(.footnote).tint(.white).disabled(logNote != nil)
        }
        .foregroundStyle(.white).padding(24).frame(maxWidth: 380)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - options sheet

/// Everything adjustable while watching, in one place: sound, subtitles, speed, picture, chapters and stream details.
struct PlayerOptionsSheet: View {
    let playback: PlaybackCoordinator
    @Binding var aspect: AspectRatioOption
    @Binding var zoom: Double
    @Binding var fill: Bool
    @Binding var loopA: Double?
    @Binding var loopB: Double?
    @Binding var controlSeconds: Double
    @Binding var leftHanded: Bool
    @Binding var streamInfo: Bool
    var setFill: (Bool) -> Void
    var setSpeed: (Double) -> Void
    var saveFrame: () -> String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container
    @State private var frameNote: String?
    @State private var importingSubtitle = false
    @State private var subtitleNote: String?
    @State private var audioDelayMS = 0
    @State private var subtitleDelayMS = 0
    @State private var subtitleSize = 100.0
    @State private var showOnlineSubs = false
    @State private var goToText = ""
    @State private var picture = PictureAdjustments()
    @State private var remember = ItemMemory().enabled

    var body: some View {
        NavigationStack {
            List {
                if !playback.audioTracks.isEmpty {
                    Section("Audio") {
                        ForEach(playback.audioTracks) { t in
                            Button { playback.selectAudio(t.id) } label: { HStack { Text(t.label); Spacer(); if t.isSelected { Image(systemName: "checkmark") } } }
                        }
                    }
                }
                Section {
                    nudge("Sound sync", ms: $audioDelayMS, range: -5000...5000) { playback.setAudioDelay(Double($0) / 1000) }
                } header: { Text("Sound out of sync?") } footer: { Text("Positive plays the sound later, negative earlier. Steps of 50 ms.") }
                if playback.capabilities.audioProcessing {
                    Section("Sound") {
                        Picker("Loudness", selection: Binding(get: { playback.audioProcessing }, set: { playback.setAudioProcessing($0) })) {
                            ForEach(AudioProcessingMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if playback.capabilities.volumeBoost {
                            Toggle("Volume boost (up to 130%)", isOn: Binding(get: { playback.volumeBoost }, set: { playback.volumeBoost = $0 }))
                        }
                    }
                }
                if !playback.subtitleTracks.isEmpty {
                    Section("Subtitles") {
                        Button { playback.selectSubtitle(nil) } label: { HStack { Text("Off"); Spacer(); if !playback.subtitleTracks.contains(where: { $0.isSelected }) { Image(systemName: "checkmark") } } }
                        ForEach(playback.subtitleTracks) { t in
                            Button { playback.selectSubtitle(t.id) } label: { HStack { Text(t.label); Spacer(); if t.isSelected { Image(systemName: "checkmark") } } }
                        }
                        nudge("Subtitle timing", ms: $subtitleDelayMS, range: -10000...10000) { playback.setSubtitleDelay(Double($0) / 1000) }
                        VStack(alignment: .leading) {
                            Text("Size \(Int(subtitleSize))%").font(.subheadline)
                            Slider(value: $subtitleSize, in: 60...200, step: 10) { e in if !e { applySubtitle { $0.subtitleSize = subtitleSize } } }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack { ForEach(SubtitlePreset.all) { p in Button(p.name) { applySubtitle(p.apply); subtitleSize = container?.settings.subtitleSize ?? 100 }.buttonStyle(.bordered) } }
                        }
                    }
                }
                Section {
                    Button { importingSubtitle = true } label: { Label("Add subtitle file…", systemImage: "doc.badge.plus") }
                    if let subtitleNote { Text(subtitleNote).font(.footnote).foregroundStyle(.secondary) }
                } header: { if playback.subtitleTracks.isEmpty { Text("Subtitles") } } footer: { Text("Choose an .srt, .vtt or .ass file from Files. It works while this video plays.") }
                if !playback.isLive {
                    Section("Speed") {
                        Picker("Speed", selection: Binding(get: { playback.rate }, set: { setSpeed($0) })) {
                            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text($0 == 1 ? "Normal" : String(format: "%g×", $0)).tag($0) }
                        }.pickerStyle(.segmented)
                        if playback.currentSeries != nil { Text("Remembered for this series.").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if !playback.chapters.isEmpty {
                    Section("Chapters") {
                        ForEach(playback.chapters) { c in
                            Button { playback.seek(to: c.time); dismiss() } label: { HStack { Text(c.title); Spacer(); Text(DurationFormatter.clock(c.time)).foregroundStyle(.secondary).monospacedDigit() } }
                        }
                    }
                }
                if !playback.isLive, playback.capabilities.abLoop {
                    Section("Repeat") {
                        HStack {
                            Button(loopA == nil ? "Set start" : "Start \(DurationFormatter.clock(loopA!))") { loopA = playback.position; apply() }.buttonStyle(.bordered)
                            Button(loopB == nil ? "Set end" : "End \(DurationFormatter.clock(loopB!))") { loopB = playback.position; apply() }.buttonStyle(.bordered).disabled(loopA == nil)
                            if loopA != nil || loopB != nil { Button("Clear", role: .destructive) { loopA = nil; loopB = nil; apply() } }
                        }
                    }
                }
                if playback.capabilities.frameStep {
                    Section("Frame by frame") {
                        HStack(spacing: 20) {
                            Button { playback.frameStep(forward: false) } label: { Label("Back", systemImage: "backward.frame") }
                            Button { playback.frameStep(forward: true) } label: { Label("Forward", systemImage: "forward.frame") }
                        }.buttonStyle(.bordered)
                    }
                }
                Section("This Title") {
                    if !playback.isLive {
                        HStack {
                            TextField("Go to time, for example 1:23:45", text: $goToText).keyboardType(.numbersAndPunctuation).submitLabel(.go).onSubmit { goTo() }
                            Button("Go") { goTo() }.disabled(PlaybackCoordinator.parseTime(goToText) == nil)
                        }
                    }
                    Button { showOnlineSubs = true } label: { Label("Find subtitles online", systemImage: "captions.bubble") }
                    Toggle("Remember settings for this title", isOn: Binding(get: { remember }, set: { remember = $0; ItemMemory().enabled = $0 }))
                }
                if playback.capabilities.pictureAdjustments {
                    Section("Picture tuning") {
                        tuning("Brightness", $picture.brightness); tuning("Contrast", $picture.contrast); tuning("Saturation", $picture.saturation); tuning("Gamma", $picture.gamma)
                        if !picture.isDefault { Button("Reset picture tuning", role: .destructive) { picture = PictureAdjustments(); playback.setPicture(picture) } }
                    }
                } else {
                    Section("Picture tuning") { Text("Brightness, contrast, saturation and gamma work in the MPV player. Switch the player in the Player section.").font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Picture") {
                    Picker("Size", selection: Binding(get: { fill }, set: { setFill($0) })) { Text("Fit").tag(false); Text("Fill").tag(true) }.pickerStyle(.segmented)
                    Picker("Shape", selection: $aspect) { ForEach(AspectRatioOption.presets) { Text($0.title).tag($0) } }
                    VStack(alignment: .leading) {
                        Text("Zoom \(String(format: "%.2g", zoom))×").font(.subheadline)
                        Slider(value: $zoom, in: 1...3, step: 0.25)
                    }
                    if zoom > 1 || aspect != .original { Button("Reset picture") { zoom = 1; aspect = .original }.foregroundStyle(.red) }
                    if playback.capabilities.screenshot {
                        Button { frameNote = saveFrame() } label: { Label("Save frame to Photos", systemImage: "camera") }
                        if let frameNote { Text(frameNote).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                Section("Controls") {
                    Picker("Hide controls after", selection: $controlSeconds) { Text("3 s").tag(3.0); Text("5 s").tag(5.0); Text("8 s").tag(8.0); Text("Never").tag(0.0) }
                    Toggle("Show stream details on the picture", isOn: $streamInfo)
                    Toggle("Left-handed layout", isOn: $leftHanded)
                }
                Section("Stream details") {
                    detail("Player", playback.activeEngine.rawValue)
                    detail("Picture", playback.metrics.resolution + (playback.metrics.videoCodec.map { " · \($0)" } ?? ""))
                    if let a = playback.metrics.audioCodec { detail("Audio", a) }
                    detail("Speed of the stream", playback.metrics.bitrateText)
                    detail("Buffered ahead", String(format: "%.0f s", playback.metrics.bufferedAheadSeconds))
                    detail("Pauses to buffer", "\(playback.metrics.stallCount)")
                }
            }
            .fileImporter(isPresented: $importingSubtitle, allowedContentTypes: [.item]) { addSubtitle($0) }
            .sheet(isPresented: $showOnlineSubs) { OnlineSubtitleSheet().presentationDetents([.medium, .large]) }
            .navigationTitle("Options").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                picture = container?.settings.picture ?? PictureAdjustments()
                audioDelayMS = Int((playback.audioDelay * 1000).rounded()); subtitleDelayMS = Int((playback.subtitleDelay * 1000).rounded())
                subtitleSize = container?.settings.subtitleSize ?? 100
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addSubtitle(_ result: Result<URL, Error>) { subtitleNote = SubtitleImport.load(result, into: playback) }

    private func apply() { playback.setLoop(start: loopA, end: loopA != nil && loopB != nil ? loopB : nil) }

    private func applySubtitle(_ change: (AppSettings) -> Void) {
        guard let s = container?.settings else { return }
        change(s); playback.applySubtitleStyle()
    }

    private func nudge(_ title: String, ms: Binding<Int>, range: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button { ms.wrappedValue = max(range.lowerBound, ms.wrappedValue - 50); set(ms.wrappedValue) } label: { Image(systemName: "minus.circle").frame(width: 40, height: 40) }.buttonStyle(.plain).accessibilityLabel("\(title) earlier")
            Text("\(ms.wrappedValue > 0 ? "+" : "")\(ms.wrappedValue) ms").monospacedDigit().frame(minWidth: 84)
            Button { ms.wrappedValue = min(range.upperBound, ms.wrappedValue + 50); set(ms.wrappedValue) } label: { Image(systemName: "plus.circle").frame(width: 40, height: 40) }.buttonStyle(.plain).accessibilityLabel("\(title) later")
        }
    }

    private func goTo() {
        guard let t = PlaybackCoordinator.parseTime(goToText) else { return }
        playback.goTo(t); goToText = ""; dismiss()
    }

    private func tuning(_ name: String, _ value: Binding<Int>) -> some View {
        VStack(alignment: .leading) {
            Text("\(name)  \(value.wrappedValue > 0 ? "+" : "")\(value.wrappedValue)").font(.subheadline)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0); playback.setPicture(picture) }), in: -100...100, step: 5)
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() }
    }
}

/// Ready-made subtitle looks.
struct SubtitlePreset: Identifiable {
    let name: String
    let apply: @MainActor (AppSettings) -> Void
    var id: String { name }

    @MainActor static var all: [SubtitlePreset] { [
        SubtitlePreset(name: "Default") { $0.subtitleSize = 100; $0.subtitleColor = .white; $0.subtitleBackground = 0.5; $0.subtitleOutline = true },
        SubtitlePreset(name: "Large") { $0.subtitleSize = 150; $0.subtitleColor = .white; $0.subtitleBackground = 0.6; $0.subtitleOutline = true },
        SubtitlePreset(name: "Yellow") { $0.subtitleSize = 120; $0.subtitleColor = .yellow; $0.subtitleBackground = 0.3; $0.subtitleOutline = true },
        SubtitlePreset(name: "Cinema") { $0.subtitleSize = 100; $0.subtitleColor = .white; $0.subtitleBackground = 0; $0.subtitleOutline = true },
    ] }
}

// MARK: - more remembered choices

extension PlayerMemory {
    /// Playback speed remembered for a whole series (episodes of one show tend to want the same speed).
    static func speed(forSeries id: String?) -> Double? {
        guard let id, let v = UserDefaults.standard.object(forKey: "player.speed." + id) as? Double else { return nil }
        return v
    }
    static func setSpeed(_ v: Double, forSeries id: String?) {
        guard let id else { return }
        if v == 1 { UserDefaults.standard.removeObject(forKey: "player.speed." + id) } else { UserDefaults.standard.set(v, forKey: "player.speed." + id) }
    }
}

/// "9:42 PM" and the battery, shown in landscape beside the title.
struct ClockBattery: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(spacing: 8) {
                Text(ctx.date.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                Label(batteryText, systemImage: "battery.75").labelStyle(.titleAndIcon).monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
        }
        .onAppear { UIDevice.current.isBatteryMonitoringEnabled = true }
        .accessibilityHidden(true)
    }

    private var batteryText: String {
        let l = UIDevice.current.batteryLevel
        return l < 0 ? "–" : "\(Int((l * 100).rounded()))%"
    }
}

/// A number pad to jump to a channel by its place in the list.
struct ChannelNumberPad: View {
    let playback: PlaybackCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""

    var body: some View {
        VStack(spacing: 14) {
            Text(entry.isEmpty ? "Channel number" : entry).font(.system(size: 34, weight: .semibold)).monospacedDigit().frame(maxWidth: .infinity, minHeight: 50)
            if let n = Int(entry), let c = PlaybackCoordinator.channel(number: n, in: playback.queue) { Text(c.name).font(.callout).foregroundStyle(.secondary) }
            else if !entry.isEmpty { Text("No channel \(entry) in this list (1–\(playback.queue.count))").font(.callout).foregroundStyle(.secondary) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "Go"], id: \.self) { k in
                    Button { press(k) } label: { Text(k).font(.system(size: 24, weight: .medium)).frame(maxWidth: .infinity, minHeight: 56).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)) }
                        .buttonStyle(.plain).accessibilityLabel(k == "⌫" ? "Delete" : k)
                }
            }
        }
        .padding(20).presentationDetents([.height(430)])
    }

    private func press(_ k: String) {
        switch k {
        case "⌫": if !entry.isEmpty { entry.removeLast() }
        case "Go":
            if let n = Int(entry), let c = PlaybackCoordinator.channel(number: n, in: playback.queue) { playback.play(channel: c); dismiss() }
        default: if entry.count < 4 { entry += k }
        }
    }
}

/// Episodes of the series now playing, by season.
struct EpisodeListSheet: View {
    let playback: PlaybackCoordinator
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [Episode] = []
    @State private var season: Int?

    var body: some View {
        NavigationStack {
            List {
                if seasons.count > 1 {
                    Picker("Season", selection: Binding(get: { season ?? seasons.first ?? 1 }, set: { season = $0 })) { ForEach(seasons, id: \.self) { Text("Season \($0)").tag($0) } }
                        .pickerStyle(.segmented)
                }
                ForEach(shown) { e in
                    Button { if let s = playback.currentSeries { playback.play(episode: e, series: s); dismiss() } } label: {
                        HStack {
                            Text("E\(e.episodeNumber)").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                            Text(e.title).lineLimit(2)
                            Spacer()
                            if e.id == playback.currentEpisodeID { Image(systemName: "waveform").foregroundStyle(ColorTokens.accentDefault) }
                        }
                    }
                }
            }
            .navigationTitle(playback.currentSeries?.title ?? "Episodes").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task {
            guard let c = container, let s = playback.currentSeries else { return }
            episodes = await Task.detached { (try? c.catalog.episodes(seriesID: s.id)) ?? [] }.value
            season = episodes.first { $0.id == playback.currentEpisodeID }?.seasonNumber ?? episodes.first?.seasonNumber
        }
    }

    private var seasons: [Int] { Array(Set(episodes.map(\.seasonNumber))).sorted() }
    private var shown: [Episode] { episodes.filter { $0.seasonNumber == (season ?? seasons.first ?? 1) }.sorted { $0.episodeNumber < $1.episodeNumber } }
}

// MARK: - always-visible stream info

/// What is playing, kept on screen: the picture size, the sound language, the subtitle language, the speed and the player. The sound and
/// subtitle chips open their choices with one tap, so nothing has to be looked for in a menu.
struct StreamInfoChips: View {
    @Environment(\.container) private var container
    let playback: PlaybackCoordinator
    var fill = false
    var setFill: (Bool) -> Void = { _ in }
    var setSpeed: (Double) -> Void = { _ in }
    var addSubtitle: () -> Void = {}

    /// Every chip that has something to choose opens a small pop-up menu with only those choices, never the whole options screen.
    var body: some View {
        let m = playback.metrics
        HStack(spacing: 6) {
            if m.height > 0 { pictureChip(PlayerMath.qualityLabel(width: m.width, height: m.height)) }
            if let v = m.videoCodec, !v.isEmpty { chipLabel(PlayerMath.videoCodecLabel(v), nil) }
            audioChip
            subtitleChip
            if !playback.isLive { speedChip }
            shareChip
            if m.stallCount > 0 { chipLabel("\(m.stallCount) pause\(m.stallCount == 1 ? "" : "s")", "exclamationmark.circle") }
            chipLabel(playback.activeEngine == .mpv ? "MPV" : "Apple", nil)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
    }

    /// Picture: the quality choices when the stream offers several, and Fit or Fill.
    private func pictureChip(_ title: String) -> some View {
        Menu {
            if !playback.qualityOptions.isEmpty {
                Section("Quality") {
                    ForEach(playback.qualityOptions) { o in
                        Button { playback.selectQuality(o.id) } label: { Label(o.label, systemImage: playback.selectedQualityID == o.id ? "checkmark" : "") }
                    }
                }
            }
            Section("Size") {
                Button { setFill(false) } label: { Label("Fit", systemImage: fill ? "" : "checkmark") }
                Button { setFill(true) } label: { Label("Fill", systemImage: fill ? "checkmark" : "") }
            }
        } label: { chipLabel(title + " ▾", "rectangle.on.rectangle") }
            .accessibilityLabel("Picture \(title). Choose size or quality.")
    }

    /// Sound: the audio languages only. A file with one track still shows it, ticked.
    @ViewBuilder private var audioChip: some View {
        let current = playback.audioTracks.first { $0.isSelected } ?? playback.audioTracks.first
        let name = Self.languageName(current) ?? playback.metrics.audioCodec.map { PlayerMath.audioCodecLabel($0) } ?? "Audio"
        if playback.audioTracks.isEmpty {
            chipLabel(name, "speaker.wave.2")
        } else {
            Menu {
                Section("Audio") {
                    ForEach(playback.audioTracks) { t in
                        Button { playback.selectAudio(t.id) } label: { Label(Self.trackTitle(t), systemImage: t.isSelected ? "checkmark" : "") }
                    }
                }
            } label: { chipLabel(name + " ▾", "speaker.wave.2") }
                .accessibilityLabel("Audio: \(name). Choose another.")
        }
    }

    /// Subtitles: Off, each language, and a way to add a file. Nothing else.
    private var subtitleChip: some View {
        let current = playback.subtitleTracks.first { $0.isSelected }
        let name = playback.subtitleTracks.isEmpty ? "No subs"
            : (current == nil ? "Subs off" : (Self.languageName(current.map { AudioTrack(id: $0.id, label: $0.label, language: $0.language, isSelected: true) }) ?? "Subs on"))
        return Menu {
            Section("Subtitles") {
                if !playback.subtitleTracks.isEmpty {
                    Button { playback.selectSubtitle(nil) } label: { Label("Off", systemImage: current == nil ? "checkmark" : "") }
                    ForEach(playback.subtitleTracks) { t in
                        Button { playback.selectSubtitle(t.id) } label: { Label(Self.trackTitle(AudioTrack(id: t.id, label: t.label, language: t.language, isSelected: t.isSelected)), systemImage: t.isSelected ? "checkmark" : "") }
                    }
                }
                Button { addSubtitle() } label: { Label("Add subtitle file…", systemImage: "doc.badge.plus") }
            }
        } label: { chipLabel(name + " ▾", "captions.bubble") }
            .accessibilityLabel("Subtitles: \(name). Choose another or add a file.")
    }

    /// Watch Together: shown when the film or channel can be shared over FaceTime.
    @ViewBuilder private var shareChip: some View {
        if let c = container, SharePlayService.shared.shareable(c) != nil || SharePlayService.shared.active {
            Button {
                if SharePlayService.shared.active { SharePlayService.shared.leave() } else { Task { await SharePlayService.shared.start(c) } }
            } label: { chipLabel(SharePlayService.shared.active ? "Leave SharePlay" : "Watch Together", "shareplay") }
                .accessibilityLabel(SharePlayService.shared.active ? "Leave SharePlay" : "Watch together over FaceTime")
        }
    }

    private var speedChip: some View {
        Menu {
            Section("Speed") {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Button { setSpeed(r) } label: { Label(r == 1 ? "Normal" : String(format: "%g×", r), systemImage: playback.rate == r ? "checkmark" : "") }
                }
            }
        } label: { chipLabel((playback.rate == 1 ? "1×" : String(format: "%g×", playback.rate)) + " ▾", "speedometer") }
            .accessibilityLabel("Speed. Choose another.")
    }

    private func chipLabel(_ text: String, _ symbol: String?) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(.white).padding(.horizontal, 10).frame(minHeight: 32)
        .background(.black.opacity(0.55), in: Capsule()).contentShape(Capsule())
    }

    /// The line shown for a track in a menu: its language when known, else its own label.
    static func trackTitle(_ t: AudioTrack) -> String { languageName(t) ?? t.label }

    static func quality(width: Int, height: Int) -> String { PlayerMath.qualityLabel(width: width, height: height) }

    static func codec(_ raw: String) -> String { PlayerMath.videoCodecLabel(raw) }

    /// The language of a sound track when the file names one; nil when all there is is "Track 1".
    static func languageName(_ t: AudioTrack?) -> String? {
        guard let t else { return nil }
        if let code = t.language, !code.isEmpty, code.lowercased() != "und" {
            let base = code.split(separator: "-").first.map(String.init) ?? code
            if let name = Locale.current.localizedString(forLanguageCode: base) { return name }
        }
        return PlayerMath.isGenericTrackLabel(t.label) ? nil : t.label
    }

    static func language(_ t: AudioTrack?) -> String { languageName(t) ?? "Audio" }
}


/// One small, faint line along the bottom edge while the controls are hidden: it never covers a broadcaster's own scoreboard.
struct StreamInfoLine: View {
    let playback: PlaybackCoordinator

    var body: some View {
        let m = playback.metrics
        let audio = StreamInfoChips.languageName(playback.audioTracks.first { $0.isSelected } ?? playback.audioTracks.first)
            ?? m.audioCodec.map { PlayerMath.audioCodecLabel($0) }
        let subs = playback.subtitleTracks.first { $0.isSelected }
        let parts: [String?] = [
            m.height > 0 ? PlayerMath.qualityLabel(width: m.width, height: m.height) : nil,
            m.videoCodec.map { PlayerMath.videoCodecLabel($0) },
            audio,
            playback.subtitleTracks.isEmpty ? nil : (subs == nil ? "Subs off" : (StreamInfoChips.languageName(subs.map { AudioTrack(id: $0.id, label: $0.label, language: $0.language, isSelected: true) }) ?? "Subs on")),
        ]
        Text(parts.compactMap { $0 }.joined(separator: " · "))
            .font(.system(size: 10, weight: .medium)).monospacedDigit()
            .foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.35), in: Capsule()).allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}


/// Loading a subtitle file the person picked from Files: copied somewhere the player can read, then added to the stream.
@MainActor enum SubtitleImport {
    static func load(_ result: Result<URL, Error>, into playback: PlaybackCoordinator) -> String {
        guard case .success(let url) = result else { return "Couldn't open that file." }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("sub-\(UUID().uuidString)-\(url.lastPathComponent)")
        do { try FileManager.default.copyItem(at: url, to: copy) } catch { return "Couldn't read that file." }
        return playback.loadSubtitleFile(copy) ? "Subtitles added" : "This player can't load subtitle files. Switch to MPV in Settings → Playback."
    }
}


/// Shown once, the first time something plays: the gestures nobody would guess.
struct GestureTour: View {
    let isLive: Bool
    var done: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea().onTapGesture { done() }
            VStack(alignment: .leading, spacing: 14) {
                Text("Quick tour").font(.system(size: 20, weight: .bold))
                row("hand.tap", isLive ? "Tap to show or hide the controls" : "Double-tap left or right to skip 10 seconds (tap again to add more)")
                if !isLive { row("arrow.left.and.right", "Swipe along the picture to move through the movie") }
                row("sun.max", "Swipe up or down on the left side for brightness, right side for volume")
                if !isLive { row("hand.point.up.left", "Touch and hold for 2× speed") }
                if isLive { row("arrow.up.arrow.down", "Swipe in the middle to change channel") }
                row("arrow.up.left.and.arrow.down.right", "Pinch to fill the screen, pinch again to zoom")
                row("ellipsis.circle", "Everything else is under the ⋯ button")
                Button { done() } label: { Text("Got it").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 48) }
                    .buttonStyle(.borderedProminent).tint(ColorTokens.accentDefault).padding(.top, 6)
            }
            .foregroundStyle(.white).padding(22).frame(maxWidth: 440)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(24)
        }
        .accessibilityAddTraits(.isModal)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 28)
            Text(text).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
