import SwiftUI

struct PlaybackSettingsPage: View {
    @Environment(\.container) private var container
    @Environment(AppSettings.self) private var settings
    @State private var engines: [EngineReport] = []
    @State private var versions = LibraryVersions()
    @State private var layout = VideoLayoutSettings()
    @State private var loadedLayout = false
    @State private var confirmReset = false

    private static let languages: [(String, String)] = [("", "No preference"), ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("pl", "Polish"), ("ru", "Russian"), ("tr", "Turkish"), ("ar", "Arabic"), ("hi", "Hindi"), ("te", "Telugu"), ("ta", "Tamil"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean")]

    private var mpv: EngineReport? { engines.first { $0.kind == .mpv } }
    private var mpvUsable: Bool { mpv?.available ?? false }

    var body: some View {
        @Bindable var s = settings
        SettingsPage {
            engineGroup()

            SettingsGroup(title: "Video") {
                SettingsRow(title: "Hardware decoding", detail: s.hardwareDecoding.explanation,
                            note: "AVPlayer manages decoding itself using macOS media capabilities, with hardware acceleration where the format allows. This choice applies to streams MPV plays.") {
                    Picker("Hardware decoding", selection: $s.hardwareDecoding) { ForEach(HardwareDecoding.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: "Preferred quality", detail: s.videoQuality.explanation, note: "Chooses between the quality variants of adaptive (HLS) streams. Other streams play as provided. Scaling quality is under Advanced video.") {
                    Picker("Preferred quality", selection: $s.videoQuality) { ForEach(VideoQualityPreference.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: "Default video size", detail: "Fit keeps the whole picture, Fill crops to fill the window, Original Size doesn't scale, Stretch ignores the aspect ratio.") {
                    Picker("Default video size", selection: layoutBinding(\.mode)) { ForEach(VideoSizeMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: "Default aspect ratio", detail: "Overrides the stream's own ratio. Each channel or title can set its own from the player's Video menu.", divider: false) {
                    Picker("Default aspect ratio", selection: layoutBinding(\.aspect)) { ForEach(AspectRatioOption.presets) { Text($0.title).tag($0) } }.pickerStyle(.menu).fixedSize()
                }
            }

            SettingsGroup(title: "Live TV") {
                SettingsRow(title: "Pause and rewind live TV", detail: "Keeps a few minutes of the channel in memory so you can pause it and wind back. Uses up to about 400 MB while a channel plays.",
                            note: mpvUsable ? "Applies to channels MPV plays, from the next channel you start." : "Needs the MPV engine, which isn't available on this Mac.", divider: false) {
                    Toggle("Pause and rewind live TV", isOn: $s.liveRewind).disabled(!mpvUsable)
                }
            }

            SettingsGroup(title: "Buffering", footer: "A playlist can use its own buffering and player engine: open Playlists and choose its Connection section.") {
                SettingsRow(title: "Mode", detail: s.bufferingMode.explanation, note: "AVPlayer's forward buffer and MPV's cache are set from the same choice.", divider: false) {
                    Picker("Buffering mode", selection: $s.bufferingMode) { ForEach(BufferingMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu).fixedSize()
                }
            }

            SettingsGroup(title: "Audio") {
                SettingsRow(title: "Preferred language", detail: "Chosen automatically when a stream offers several audio tracks. You can still switch inside the player.") {
                    Picker("Preferred audio language", selection: $s.preferredAudioLanguage) { ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) } }.pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: "Output device", divider: false) {
                    Picker("Output device", selection: $s.audioOutputUID) {
                        Text("System default").tag("")
                        ForEach(AudioDevices.outputs()) { Text($0.name).tag($0.uid) }
                    }.pickerStyle(.menu).fixedSize()
                }
            }

            SettingsGroup(title: "Subtitles") {
                SettingsRow(title: "Preferred language") {
                    Picker("Preferred subtitle language", selection: $s.preferredSubtitleLanguage) { ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) } }.pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: "Show by default", detail: "Turns subtitles on when a track in your language exists.") { Toggle("Show subtitles by default", isOn: $s.subtitlesByDefault) }
                SettingsRow(title: "Size") {
                    HStack { Slider(value: $s.subtitleSize, in: 60...200, step: 10).frame(width: 180); Text("\(Int(s.subtitleSize))%").monospacedDigit().frame(width: 44, alignment: .trailing) }
                        .onChange(of: s.subtitleSize) { _, _ in container?.playback.applySubtitleStyle() }
                }
                SettingsRow(title: "Background opacity") {
                    HStack { Slider(value: $s.subtitleBackground, in: 0...1).frame(width: 180); Text("\(Int(s.subtitleBackground * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing) }
                        .onChange(of: s.subtitleBackground) { _, _ in container?.playback.applySubtitleStyle() }
                }
                SettingsRow(title: "Text colour") {
                    Picker("Text colour", selection: $s.subtitleColor) { ForEach(SubtitleColor.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).fixedSize()
                        .onChange(of: s.subtitleColor) { _, _ in container?.playback.applySubtitleStyle() }
                }
                let positionOK = container?.playback.capabilities(of: .mpv)?.subtitlePosition ?? false
                SettingsRow(title: "Vertical position", note: positionOK ? nil : "Needs the MPV engine, which isn't available on this Mac.") {
                    Slider(value: $s.subtitlePosition, in: 0...1).frame(width: 180).disabled(!positionOK)
                        .onChange(of: s.subtitlePosition) { _, _ in container?.playback.applySubtitleStyle() }
                }
                let outlineOK = container?.playback.capabilities(of: .mpv) != nil
                SettingsRow(title: "Outline and shadow", detail: "Keeps text readable over bright scenes.", note: outlineOK ? nil : "Needs the MPV engine, which isn't available on this Mac.") {
                    Toggle("Outline and shadow", isOn: $s.subtitleOutline).disabled(!outlineOK)
                        .onChange(of: s.subtitleOutline) { _, _ in container?.playback.applySubtitleStyle() }
                }
                SettingsRow(title: "Preview", detail: "How subtitles will look.", divider: false) { SubtitlePreview(style: s.subtitleStyle) }
            }

            SettingsGroup(title: "Subtitles online", footer: "From OpenSubtitles, using your own free account and API key (opensubtitles.com). They stay in the Keychain on this device and are sent only to OpenSubtitles when you ask for subtitles in the player.") {
                OpenSubtitlesFields()
            }

            SettingsGroup(title: "Remembered choices", footer: "Audio language, subtitles, speed and timing come back the next time you play the same title or channel.") {
                SettingsRow(title: "Remember settings for each title") { Toggle("", isOn: Binding(get: { ItemMemory().enabled }, set: { ItemMemory().enabled = $0 })).labelsHidden() }
            }

            SettingsGroup(title: "Behaviour") {
                SettingsRow(title: "Play next episode automatically", detail: "Only continues within the series you are watching.") { Toggle("Play next episode automatically", isOn: $s.autoPlayNextEpisode) }
                SettingsRow(title: "Remember playback position", detail: "Saves where you stop in movies and episodes so Continue Watching works. Live channels have no position to save. Off means no resume points are written.") { Toggle("Remember playback position", isOn: $s.rememberPosition) }
                SettingsRow(title: "Resume automatically", detail: s.rememberPosition ? "Continue a partly watched title where it stopped instead of from the start." : "Needs “Remember playback position”.") {
                    Toggle("Resume automatically", isOn: $s.resumeAutomatically).disabled(!s.rememberPosition)
                }
            }

            SettingsDisclosure(title: "Advanced video", footer: "These change how MPV processes video. Most people never need them; AVPlayer ignores them.") {
                SettingsRow(title: "Scaling quality", detail: s.renderingProfile.explanation, note: mpvUsable ? "Applies to streams MPV plays, from the next stream you start." : "Needs the MPV engine, which isn't available on this Mac.") {
                    Picker("Scaling quality", selection: $s.renderingProfile) { ForEach(RenderingProfile.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).fixedSize().disabled(!mpvUsable)
                }
                SettingsRow(title: "HDR tone mapping", detail: s.toneMapping.explanation, note: mpvUsable ? "How HDR video is shown on a normal display. From the next stream you start." : "Needs the MPV engine, which isn't available on this Mac.") {
                    Picker("HDR tone mapping", selection: $s.toneMapping) { ForEach(HDRToneMapping.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).fixedSize().disabled(!mpvUsable)
                }
                SettingsRow(title: "Picture", detail: s.picture.isDefault ? "Brightness, contrast, saturation, gamma and hue are at their defaults. Adjust them from the player's picture button." : "Adjusted from the player's picture button.",
                            note: mpvUsable ? nil : "Needs the MPV engine, which isn't available on this Mac.") {
                    Button("Reset Picture") { s.picture = PictureAdjustments() }.disabled(s.picture.isDefault)
                }
                SettingsRow(title: "Deinterlacing", detail: "Automatic turns it on for live TV, where interlaced broadcast video is common, and leaves films alone. Choose On for an interlaced recording.",
                            note: mpvUsable ? "Applies to streams MPV plays." : "Needs the MPV engine, which isn't available on this Mac.", divider: false) {
                    Picker("Deinterlacing", selection: $s.deinterlace) { ForEach(DeinterlaceMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).fixedSize().disabled(!mpvUsable)
                }
            }

            SettingsDisclosure(title: "Advanced audio", footer: "Only MPV can process audio this way. AVPlayer plays audio as the stream provides it.") {
                SettingsRow(title: "Volume normalization", detail: s.audioProcessing.explanation,
                            note: mpvUsable ? "Applies to streams MPV plays." : "Needs the MPV engine, which isn't available on this Mac.") {
                    Picker("Volume normalization", selection: $s.audioProcessing) { ForEach(AudioProcessingMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu).fixedSize().disabled(!mpvUsable)
                        .onChange(of: s.audioProcessing) { _, m in container?.playback.setAudioProcessing(m) }
                }
                SettingsRow(title: "Downmix to stereo", detail: "Mixes 5.1 and 7.1 audio down to two channels, for speakers and headphones.",
                            note: mpvUsable ? "Applies from the next stream you start." : "Needs the MPV engine, which isn't available on this Mac.", divider: false) {
                    Toggle("Downmix to stereo", isOn: $s.stereoDownmix).disabled(!mpvUsable)
                }
            }

            SettingsDisclosure(title: "Troubleshooting", footer: "Details come from the stream playing right now. Nothing here is sent anywhere.") {
                SettingsRow(title: "Show stream information", detail: "A small overlay with resolution, bitrate and dropped frames.") { Toggle("Show stream information", isOn: $s.showDiagnosticsOverlay) }
                PlaybackDetailsPanel()
                SettingsActions {
                    Button(role: .destructive) { confirmReset = true } label: { Label("Restore Playback Defaults…", systemImage: "arrow.uturn.backward") }
                }
            }
        }
        .confirmationDialog("Restore all playback settings to their defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Restore Defaults", role: .destructive) { settings.resetPlayback() }
        } message: { Text("Engine, video, buffering, audio, subtitle and behaviour settings go back to their defaults. Your playlists, favorites, history and library are not touched.") }
        .task { refreshEngines(); if !loadedLayout, let c = container { layout = c.videoPrefs.globalLayout(); loadedLayout = true } }
        .task { versions = await Task.detached { EngineInfoService.libraryVersions() }.value; refreshEngines() }
    }

    private func refreshEngines() {
        guard let p = container?.playback else { return }
        engines = EngineInfoService.reports(p).map { var r = $0; if r.kind == .mpv { r.version = versions.mpv }; return r }
    }

    private func layoutBinding<V>(_ key: WritableKeyPath<VideoLayoutSettings, V>) -> Binding<V> {
        Binding(get: { layout[keyPath: key] }, set: { layout[keyPath: key] = $0; container?.videoPrefs.setGlobalLayout(layout) })
    }

    @ViewBuilder
    private func engineGroup() -> some View {
        @Bindable var s = settings
        SettingsGroup(title: "Player engine", footer: "Automatic uses AVPlayer for HLS and MP4, and MPV for MKV, raw MPEG-TS, RTSP and DASH. If a stream's format isn't supported, StreamSetu tries the other engine once; a sign-in problem is reported instead of retried.") {
            SettingsRow(title: "Engine", detail: "Automatic is recommended.", divider: !engines.isEmpty) {
                Picker("Engine", selection: $s.enginePreference) { ForEach(PlaybackEnginePreference.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).fixedSize()
            }
            ForEach(AppSettings.ViewingKind.allCases) { kind in
                SettingsRow(title: "For \(kind.title)", detail: kind == .live ? "A playlist's or channel's own choice still comes first." : nil) {
                    Picker(kind.title, selection: Binding(get: { settings.engineChoice(for: kind) }, set: { settings.setEngineChoice($0, for: kind) })) {
                        Text("Use the engine above").tag(PlaybackEnginePreference?.none)
                        ForEach(PlaybackEnginePreference.allCases) { Text($0.rawValue).tag(PlaybackEnginePreference?.some($0)) }
                    }.pickerStyle(.menu).fixedSize()
                }
            }
            if s.enginePreference == .mpv, !mpvUsable, let problem = mpv?.problem {
                MessageLine(message: .init(text: "MPV is selected but unavailable, so AVPlayer will be used. \(problem)", kind: .failure))
            }
            ForEach(Array(engines.enumerated()), id: \.element.id) { i, e in
                EngineCard(report: e, isActive: container?.playback.activeEngine == e.kind && container?.playback.current != nil)
            }
        }
    }
}

private struct EngineCard: View {
    let report: EngineReport
    let isActive: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                Text(report.available ? "Available" : "Not available").foregroundStyle(.secondary)
            } label: {
                HStack(spacing: 6) {
                    StatusDot(color: report.available ? ColorTokens.success : ColorTokens.warning)
                    Text(report.title)
                    if let v = report.version { Text(v).foregroundStyle(.secondary) }
                    if isActive { Text("Playing now").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let p = report.problem { Text(p).font(.callout).foregroundStyle(ColorTokens.warning).fixedSize(horizontal: false, vertical: true) }
            let supported = report.capabilities.filter(\.value).keys.sorted()
            if !supported.isEmpty {
                Text("Supports " + supported.joined(separator: ", ").lowercased() + ".").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SubtitlePreview: View {
    let style: SubtitleStyle
    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(hex: 0x2A3346), Color(hex: 0x141922)], startPoint: .top, endPoint: .bottom)
            Text("Subtitles look like this")
                .font(.system(size: 14 * style.sizePercent / 100, weight: .medium))
                .foregroundStyle(Color(red: style.color.rgb.0, green: style.color.rgb.1, blue: style.color.rgb.2))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.black.opacity(style.backgroundOpacity), in: RoundedRectangle(cornerRadius: 4))
                .padding(.bottom, 10)
        }
        .frame(width: 260, height: 70).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("Subtitle preview, \(Int(style.sizePercent)) percent size, \(style.color.rawValue) text")
    }
}


/// What the stream playing right now looks like to the player, read from the engine itself.
private struct PlaybackDetailsPanel: View {
    @Environment(\.container) private var container

    var body: some View {
        if let p = container?.playback, p.current != nil {
            let m = p.metrics
            Group {
                SettingsValueRow(title: "Player engine", value: p.activeEngine.rawValue)
                SettingsValueRow(title: "Stream type", value: m.container.rawValue.uppercased())
                SettingsValueRow(title: "Provider host", value: m.host.isEmpty ? "—" : m.host)
                SettingsValueRow(title: "Video", value: [m.videoCodec, m.resolution, m.frameRate.map { String(format: "%.0f fps", $0) }].compactMap { $0 }.filter { $0 != "—" }.joined(separator: " · ").nonEmptyOr("—"))
                SettingsValueRow(title: "Audio", value: m.audioCodec ?? "—")
                SettingsValueRow(title: "Bitrate", value: m.bitrateText)
                SettingsValueRow(title: "Buffered ahead", value: String(format: "%.1f s", m.bufferedAheadSeconds))
                SettingsValueRow(title: "Dropped frames", value: m.droppedFrames.formatted(), tone: m.droppedFrames > 30 ? .warning : .normal)
                SettingsValueRow(title: "Stalls", value: m.stallCount == 0 ? "None" : "\(m.stallCount) (\(String(format: "%.1f", m.totalStallSeconds)) s)", tone: m.stallCount > 2 ? .warning : .normal)
                SettingsValueRow(title: "Start-up time", value: m.startupSeconds.map { String(format: "%.1f s", $0) } ?? "—")
            }
        } else {
            Text("Start a channel or title to see how the player is handling it.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}

