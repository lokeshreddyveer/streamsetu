import SwiftUI

private struct MenuChip: ViewModifier {
    var label: String
    func body(content: Content) -> some View {
        content.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help(label).accessibilityLabel(label)
    }
}

private func chipIcon(_ symbol: String, active: Bool = false) -> some View {
    Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 32)
        .background(Color.white.opacity(active ? 0.2 : 0.08), in: Circle())
}

/// Video size, aspect ratio and zoom. Presentation scaling only — it never changes the stream.
struct ReddyVideoSizeMenu: View {
    let layout: VideoLayoutSettings
    let hasOverride: Bool
    var onMode: (VideoSizeMode) -> Void
    var onAspect: (AspectRatioOption) -> Void
    var onZoom: (Double) -> Void
    var onReset: () -> Void
    var onRemember: () -> Void
    var onForget: () -> Void
    var onApplyGlobal: () -> Void

    var body: some View {
        Menu {
            Section("Video Size") {
                ForEach(VideoSizeMode.allCases) { m in Button { onMode(m) } label: { Label(m.rawValue, systemImage: layout.mode == m ? "checkmark" : "") } }
            }
            Section("Aspect Ratio") {
                ForEach(AspectRatioOption.presets) { a in Button { onAspect(a) } label: { Label(a.title, systemImage: layout.aspect == a ? "checkmark" : "") } }
                Button { onAspect(.custom(width: 5, height: 4)) } label: { Label("Custom 5:4", systemImage: layout.aspect == .custom(width: 5, height: 4) ? "checkmark" : "") }
            }
            Section("Zoom") {
                ForEach(VideoLayoutSettings.zoomPresets, id: \.self) { z in
                    Button { onZoom(z) } label: { Label("\(Int(z * 100))%", systemImage: abs(layout.zoom - z) < 0.001 ? "checkmark" : "") }
                }
                Button("Zoom In") { onZoom(layout.zoom + 0.05) }.disabled(layout.zoom >= VideoLayoutSettings.zoomRange.upperBound)
                Button("Zoom Out") { onZoom(layout.zoom - 0.05) }.disabled(layout.zoom <= VideoLayoutSettings.zoomRange.lowerBound)
            }
            Divider()
            Button("Reset Video Size", action: onReset).disabled(layout.isDefault)
            Button("Remember for This Channel", action: onRemember)
            if hasOverride { Button("Forget This Channel's Setting", action: onForget) }
            Button("Apply as Global Default", action: onApplyGlobal)
        } label: { chipIcon("arrow.up.left.and.down.right.magnifyingglass", active: !layout.isDefault) }
        .modifier(MenuChip(label: "Video size and zoom"))
    }
}

/// Only lists renditions the stream actually offers.
struct ReddyQualityMenu: View {
    let options: [QualityOption]
    let selectedID: String?
    let supported: Bool
    let technical: String
    var onSelect: (String?) -> Void

    var body: some View {
        Menu {
            if options.count > 1 {
                Button { onSelect(nil) } label: { Label("Auto", systemImage: selectedID == nil ? "checkmark" : "") }
                ForEach(options) { o in Button { onSelect(o.id) } label: { Label(o.label, systemImage: selectedID == o.id ? "checkmark" : "") } }
            } else {
                Text(supported ? "Single quality stream" : "Quality selection isn't available for this engine")
            }
            if !technical.isEmpty { Divider(); Text(technical) }
        } label: { chipIcon("dial.medium", active: selectedID != nil) }
        .modifier(MenuChip(label: "Quality"))
    }
}

struct ReddyAudioMenu: View {
    let tracks: [AudioTrack]
    let delay: Double
    let delaySupported: Bool
    let processing: AudioProcessingMode
    let processingSupported: Bool
    var onTrack: (String?) -> Void
    var onDelay: (Double) -> Void
    var onProcessing: (AudioProcessingMode) -> Void
    /// This channel's loudness trim (−0.5…+0.5), or nil when what is playing isn't a live channel.
    var channelTrim: Double?
    var onTrim: (Double) -> Void = { _ in }

    var body: some View {
        Menu {
            if let trim = channelTrim {
                Section("This Channel's Loudness: \(trim == 0 ? "normal" : String(format: "%+d%%", Int((trim * 100).rounded())))") {
                    Button("Louder") { onTrim(trim + 0.1) }.disabled(trim >= ChannelPlaybackPref.trimRange.upperBound - 0.001)
                    Button("Quieter") { onTrim(trim - 0.1) }.disabled(trim <= ChannelPlaybackPref.trimRange.lowerBound + 0.001)
                    Button("Reset") { onTrim(0) }.disabled(trim == 0)
                }
            }
            Section("Audio Track") {
                if tracks.isEmpty { Text("No alternative audio tracks") }
                ForEach(tracks) { t in Button { onTrack(t.id) } label: { Label(t.label, systemImage: t.isSelected ? "checkmark" : "") } }
            }
            Section("Sound") {
                ForEach(AudioProcessingMode.allCases) { m in
                    Button { onProcessing(m) } label: { Label(m.rawValue, systemImage: processing == m ? "checkmark" : "") }.disabled(!processingSupported && m != .off)
                }
                if !processingSupported { Text("Loudness processing needs the MPV engine") }
            }
            Section("Audio Delay: \(Int(delay * 1000)) ms") {
                Button("Delay +100 ms") { onDelay(delay + 0.1) }.disabled(!delaySupported)
                Button("Delay −100 ms") { onDelay(delay - 0.1) }.disabled(!delaySupported)
                Button("Reset Delay") { onDelay(0) }.disabled(!delaySupported || delay == 0)
                if !delaySupported { Text("Audio delay needs the MPV engine") }
            }
        } label: { chipIcon("speaker.wave.2.bubble", active: processing != .off || delay != 0 || (channelTrim ?? 0) != 0) }
        .modifier(MenuChip(label: "Audio"))
    }
}

struct ReddySubtitleMenu: View {
    let tracks: [SubtitleTrack]
    let delay: Double
    let delaySupported: Bool
    var onTrack: (String?) -> Void
    var onDelay: (Double) -> Void
    /// Nil when the engine can't load external subtitle files.
    var onLoadFile: (() -> Void)?

    var body: some View {
        Menu {
            Button { onTrack(nil) } label: { Label("Off", systemImage: tracks.contains { $0.isSelected } ? "" : "checkmark") }
            ForEach(tracks) { t in Button { onTrack(t.id) } label: { Label(t.label, systemImage: t.isSelected ? "checkmark" : "") } }
            if tracks.isEmpty { Text("No subtitle tracks in this stream") }
            Divider()
            if let onLoadFile { Button("Load Subtitle File…", action: onLoadFile) } else { Text("Loading a subtitle file needs the MPV engine") }
            Divider()
            Button("Delay +100 ms") { onDelay(delay + 0.1) }.disabled(!delaySupported)
            Button("Delay −100 ms") { onDelay(delay - 0.1) }.disabled(!delaySupported)
            Button("Reset Delay") { onDelay(0) }.disabled(!delaySupported || delay == 0)
            if !delaySupported { Text("Subtitle delay needs the MPV engine") }
        } label: { chipIcon("captions.bubble", active: tracks.contains { $0.isSelected }) }
        .modifier(MenuChip(label: "Subtitles"))
    }
}


/// Brightness, contrast, saturation, gamma and hue, for MPV. Changes apply at once and are kept for every stream.
struct ReddyPicturePanel: View {
    let picture: PictureAdjustments
    var onChange: (PictureAdjustments) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Picture").font(.headline)
            slider("Brightness", \.brightness)
            slider("Contrast", \.contrast)
            slider("Saturation", \.saturation)
            slider("Gamma", \.gamma)
            slider("Hue", \.hue)
            HStack { Spacer(); Button("Reset") { onChange(PictureAdjustments()) }.disabled(picture.isDefault) }
        }
        .padding(16).frame(width: 280)
    }

    private func slider(_ title: String, _ key: WritableKeyPath<PictureAdjustments, Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.callout); Spacer(); Text(picture[keyPath: key] == 0 ? "0" : String(format: "%+d", picture[keyPath: key])).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
            Slider(value: Binding(get: { Double(picture[keyPath: key]) }, set: { var p = picture; p[keyPath: key] = Int($0.rounded()); onChange(p) }), in: -100...100, step: 1)
                .controlSize(.small).accessibilityLabel(title)
        }
    }
}
