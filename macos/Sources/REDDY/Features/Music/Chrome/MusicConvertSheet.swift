import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// Audio tools for your own files: convert (one file or many), join, split a CD image by its CUE sheet, pull out or store cover pictures, and import a disc you own.
/// Every result is a new file; your originals are never changed here. Only convert music you own or are allowed to convert.
struct MusicConvertSheet: View {
    enum Tab: Hashable { case convert, join, split, artwork, disc }

    let hub: MusicHub
    var initial: [URL] = []
    let close: () -> Void
    @State private var tab: Tab = .convert
    @State private var files: [URL] = []
    @State private var presetID = "phone"
    @State private var custom: [MusicConversionPreset] = MusicConvertPresets.load()
    @State private var format: MusicConvertFormat = .aac
    @State private var rate: Double = 0
    @State private var channels = 0
    @State private var depth = 16
    @State private var bitrate = 256
    @State private var folder: URL = MusicConvertPresets.defaultFolder
    @State private var trimStart = ""
    @State private var trimEnd = ""
    @State private var joinName = "Joined"
    @State private var presetName = ""
    @State private var note: String?
    @State private var chapters: [MusicChapter] = []
    @State private var disc: [URL] = []
    @State private var queue = MusicConversionQueue.shared
    @Environment(\.reddyAccent) private var accent

    private var allPresets: [MusicConversionPreset] { MusicConversionPreset.builtIn + custom }

    private var preset: MusicConversionPreset {
        MusicConversionPreset(id: "now", name: "", format: format, sampleRate: rate > 0 ? rate : nil, channels: channels > 0 ? channels : nil, bitDepth: depth, bitrateKbps: bitrate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Audio tools")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.convertClose")
            }
            Picker("", selection: $tab) {
                Text(Localized.string("Convert")).tag(Tab.convert)
                Text(Localized.string("Join")).tag(Tab.join)
                Text(Localized.string("Split a CD image")).tag(Tab.split)
                Text(Localized.string("Cover pictures")).tag(Tab.artwork)
                Text(Localized.string("Import a disc")).tag(Tab.disc)
            }.pickerStyle(.segmented).labelsHidden().atlas("control.music.convertTab")
            Text(Localized.string("Only convert music you own or are allowed to convert. Your original files are never changed.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            if let note { Text(verbatim: note).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: MusicSpace.md) {
                    switch tab {
                    case .convert, .join: sourceBox; settingsBox; if tab == .convert { trimBox }; actionRow
                    case .split: splitBox
                    case .artwork: artworkBox
                    case .disc: discBox
                    }
                    jobsBox
                }
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 600)
        .onAppear { if files.isEmpty { files = initial }; apply(presetID) }
    }

    // MARK: source and settings

    private var sourceBox: some View {
        MusicSheetCard {
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                HStack {
                    Text(Localized.string("Files")).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                    Spacer()
                    #if os(macOS)
                    Button(Localized.string("Choose files…")) { files += MusicConvertPanels.chooseAudio(); }.musicButton(.secondary, size: .compact).atlas("control.music.convertChoose")
                    #endif
                    if !files.isEmpty { Button(Localized.string("Clear")) { files = [] }.buttonStyle(.plain).foregroundStyle(accent).atlas("control.music.convertClearFiles") }
                }
                if files.isEmpty { Text(Localized.string("No files chosen.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
                ForEach(files, id: \.self) { u in
                    HStack { Image(systemName: "music.note").font(MusicTokens.iconSmall); Text(verbatim: u.lastPathComponent).lineLimit(1); Spacer(minLength: 0) }.font(Typography.caption)
                }
            }
        }
    }

    private var settingsBox: some View {
        MusicSheetCard {
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                HStack {
                    Picker(Localized.string("Preset"), selection: Binding(get: { presetID }, set: { presetID = $0; apply($0) })) {
                        ForEach(allPresets) { Text(Localized.string($0.name)).tag($0.id) }
                    }.fixedSize().atlas("control.music.convertPreset")
                    Spacer()
                }
                HStack(spacing: MusicSpace.sm) {
                    Picker(Localized.string("Format"), selection: $format) { ForEach(MusicConvertFormat.allCases) { Text($0.title).tag($0) } }.fixedSize().atlas("control.music.convertFormat")
                    Picker(Localized.string("Sample rate"), selection: $rate) {
                        Text(Localized.string("Keep")).tag(0.0)
                        ForEach([22050.0, 32000, 44100, 48000, 88200, 96000], id: \.self) { Text(verbatim: String(format: "%g kHz", $0 / 1000)).tag($0) }
                    }.fixedSize().atlas("control.music.convertRate")
                    Picker(Localized.string("Channels"), selection: $channels) {
                        Text(Localized.string("Keep")).tag(0); Text(Localized.string("Mono")).tag(1); Text(Localized.string("Stereo")).tag(2)
                    }.fixedSize().atlas("control.music.convertChannels")
                }
                HStack(spacing: MusicSpace.sm) {
                    if format.hasBitDepth {
                        Picker(Localized.string("Bit depth"), selection: $depth) { ForEach(format == .wav || format == .aiff ? [16, 24, 32] : [16, 24], id: \.self) { Text(verbatim: "\($0)-bit").tag($0) } }.fixedSize().atlas("control.music.convertDepth")
                    }
                    if format.isLossy {
                        Picker(Localized.string("Quality"), selection: $bitrate) { ForEach([96, 128, 192, 256, 320], id: \.self) { Text(verbatim: "\($0) kbps").tag($0) } }.fixedSize().atlas("control.music.convertBitrate")
                    }
                }
                HStack {
                    TextField(Localized.string("Save these settings as…"), text: $presetName).textFieldStyle(.roundedBorder).frame(maxWidth: 240).atlas("control.music.convertPresetName")
                    Button(Localized.string("Save preset")) { savePreset() }.musicButton(.secondary, size: .compact).disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty).atlas("control.music.convertSavePreset")
                }
                HStack {
                    Text(Localized.string("Save to")).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                    Text(verbatim: folder.path).font(Typography.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    #if os(macOS)
                    Button(Localized.string("Choose folder…")) { if let u = MusicConvertPanels.chooseFolder() { folder = u } }.musicButton(.secondary, size: .compact).atlas("control.music.convertFolder")
                    #endif
                }
            }
        }
    }

    private var trimBox: some View {
        MusicSheetCard {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                Text(Localized.string("Keep only a part (one file)")).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                HStack {
                    TextField("0:30", text: $trimStart).textFieldStyle(.roundedBorder).frame(width: 90).atlas("control.music.convertTrimStart")
                    Text(Localized.string("to")).font(Typography.caption)
                    TextField("2:45", text: $trimEnd).textFieldStyle(.roundedBorder).frame(width: 90).atlas("control.music.convertTrimEnd")
                    Text(Localized.string("Leave empty to keep everything.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: MusicSpace.sm) {
            if tab == .convert {
                Button { startConvert() } label: { Label(Localized.string("Convert"), systemImage: "arrow.triangle.2.circlepath") }
                    .musicButton(.primary, size: .compact).disabled(files.isEmpty).atlas("control.music.convertStart")
            } else {
                TextField(Localized.string("Name of the joined file"), text: $joinName).textFieldStyle(.roundedBorder).frame(maxWidth: 220).atlas("control.music.convertJoinName")
                Button { startJoin() } label: { Label(Localized.string("Join into one file"), systemImage: "link") }
                    .musicButton(.primary, size: .compact).disabled(files.count < 2).atlas("control.music.convertJoin")
            }
        }
    }

    private func apply(_ id: String) {
        guard let p = allPresets.first(where: { $0.id == id }) else { return }
        format = p.format; rate = p.sampleRate ?? 0; channels = p.channels ?? 0; depth = p.bitDepth; bitrate = p.bitrateKbps
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        var p = preset; p.id = UUID().uuidString; p.name = name
        custom.append(p); MusicConvertPresets.save(custom); presetID = p.id; presetName = ""
    }

    private func startConvert() {
        let range: ClosedRange<Double>? = {
            guard files.count == 1, let a = MusicTrackMarkRules.parse(trimStart.isEmpty ? "0" : trimStart) else { return nil }
            guard let b = MusicTrackMarkRules.parse(trimEnd), b > a else { return trimEnd.isEmpty && !trimStart.isEmpty ? a...86_400 : nil }
            return a...b
        }()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let p = preset
        Task { @MainActor in
            let index = await LocalLibraryStore.shared.currentIndex()
            let jobs = files.map { u in
                MusicConversionQueue.Job(title: u.deletingPathExtension().lastPathComponent, inputs: [u], output: MusicConverter.output(for: u, in: folder, format: p.format), preset: p, range: files.count == 1 ? range : nil,
                                         entry: index.entries.first { $0.path == u.path })
            }
            queue.add(jobs)
            note = Localized.plural(jobs.count, one: "Started %@ conversion.", other: "Started %@ conversions.")
        }
    }

    private func startJoin() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = joinName.trimmingCharacters(in: .whitespaces).isEmpty ? "Joined" : joinName
        queue.add(MusicConversionQueue.Job(title: name, inputs: files, output: MusicConverter.output(for: files[0], in: folder, format: preset.format, name: name), preset: preset))
        note = Localized.string("Started joining %@ files.", String(files.count))
    }

    // MARK: split

    private var splitBox: some View {
        MusicSheetCard {
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                Text(Localized.string("Choose an audio file that has a CUE sheet with the same name next to it. Each track of the sheet becomes its own file.")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                #if os(macOS)
                Button(Localized.string("Choose the audio file…")) {
                    if let u = MusicConvertPanels.chooseAudio().first { files = [u]; chapters = MusicCueSheet.chapters(for: u); note = chapters.isEmpty ? Localized.string("No CUE sheet with tracks was found next to this file.") : nil }
                }.musicButton(.secondary, size: .compact).atlas("control.music.convertSplitChoose")
                #endif
                ForEach(chapters) { c in
                    HStack { Text(verbatim: MusicTrackMarkRules.clock(c.start)).font(Typography.timestamp).foregroundStyle(ColorTokens.textTertiary); Text(verbatim: c.title).lineLimit(1); Spacer(minLength: 0) }.font(Typography.caption)
                }
                if !chapters.isEmpty {
                    Picker(Localized.string("Format"), selection: $format) { ForEach(MusicConvertFormat.allCases) { Text($0.title).tag($0) } }.fixedSize().atlas("control.music.convertSplitFormat")
                    Button { startSplit() } label: { Label(Localized.plural(chapters.count, one: "Split into %@ track", other: "Split into %@ tracks"), systemImage: "scissors") }
                        .musicButton(.primary, size: .compact).atlas("control.music.convertSplit")
                }
            }
        }
    }

    private func startSplit() {
        guard let audio = files.first else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            let secs = (try? await AVURLAsset(url: audio).load(.duration).seconds) ?? 0
            let jobs = MusicConvertTools.splitJobs(audio: audio, chapters: chapters, duration: secs, preset: preset, folder: folder, album: audio.deletingPathExtension().lastPathComponent, artist: nil)
            queue.add(jobs)
            note = Localized.plural(jobs.count, one: "Started %@ track.", other: "Started %@ tracks.")
        }
    }

    // MARK: artwork

    private var artworkBox: some View {
        MusicSheetCard {
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                Text(Localized.string("Save the cover picture a song carries as an image file, or store a picture inside an AAC or Apple Lossless file.")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                #if os(macOS)
                HStack {
                    Button(Localized.string("Save cover from a file…")) { extractCover() }.musicButton(.secondary, size: .compact).atlas("control.music.convertExtractCover")
                    Button(Localized.string("Store a picture in a file…")) { embedCover() }.musicButton(.secondary, size: .compact).disabled(MusicCollectionSafety.isReadOnly()).atlas("control.music.convertEmbedCover")
                }
                if MusicCollectionSafety.isReadOnly() { Text(Localized.string("Storing a picture changes the file, so it needs the collection to be writable (Library health).")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
                #endif
            }
        }
    }

    #if os(macOS)
    private func extractCover() {
        guard let u = MusicConvertPanels.chooseAudio().first else { return }
        Task { @MainActor in
            let items = (try? await AVURLAsset(url: u).load(.commonMetadata)) ?? []
            guard let art = items.first(where: { $0.commonKey == .commonKeyArtwork }), let data = try? await art.load(.dataValue) else { note = Localized.string("This file has no cover picture."); return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = data.starts(with: [0x89, 0x50]) ? "png" : "jpg"
            var dest = folder.appendingPathComponent(MusicRenameTemplate.clean(u.deletingPathExtension().lastPathComponent) + "." + ext), n = 2
            while FileManager.default.fileExists(atPath: dest.path) { dest = folder.appendingPathComponent(MusicRenameTemplate.clean(u.deletingPathExtension().lastPathComponent) + " \(n)." + ext); n += 1 }
            do { try data.write(to: dest); note = Localized.string("Saved %@.", dest.lastPathComponent) } catch { note = Localized.string("The picture could not be saved.") }
        }
    }

    private func embedCover() {
        guard !MusicCollectionSafety.isReadOnly(), let a = MusicConvertPanels.chooseAudio(types: [UTType(filenameExtension: "m4a")!]).first, let img = MusicConvertPanels.chooseImage(), let data = try? Data(contentsOf: img) else { return }
        guard MusicCollectionSafety.verdict(for: a.path) == .allowed else { note = Localized.string("This file is locked."); return }
        Task { @MainActor in
            let rec = MusicCollectionSafety.keepsBackups() ? MusicChangeJournal.shared.backup(of: a, summary: "cover picture") : nil
            let ok = await MusicConvertTools.embedArtwork(data, into: a)
            if !ok, let r = rec { MusicChangeJournal.shared.discard(r.id) }
            note = ok ? Localized.string("Stored the picture in the file.") : Localized.string("The picture could not be stored in this file.")
        }
    }
    #endif

    // MARK: disc

    private var discBox: some View {
        MusicSheetCard {
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                Text(Localized.string("Put an audio CD you own in your drive. Its tracks appear here, and you can save them as files.")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                Button(Localized.string("Look for a disc")) { disc = MusicConvertTools.discTracks(); if disc.isEmpty { note = Localized.string("No audio disc was found.") } }.musicButton(.secondary, size: .compact).atlas("control.music.convertDiscLook")
                ForEach(disc, id: \.self) { u in Text(verbatim: u.lastPathComponent).font(Typography.caption) }
                if !disc.isEmpty {
                    Picker(Localized.string("Format"), selection: $format) { ForEach(MusicConvertFormat.allCases) { Text($0.title).tag($0) } }.fixedSize().atlas("control.music.convertDiscFormat")
                    Button { importDisc() } label: { Label(Localized.plural(disc.count, one: "Import %@ track", other: "Import %@ tracks"), systemImage: "opticaldisc") }.musicButton(.primary, size: .compact).atlas("control.music.convertDiscImport")
                }
            }
        }
    }

    private func importDisc() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let p = preset
        queue.add(disc.enumerated().map { i, u in
            MusicConversionQueue.Job(title: u.deletingPathExtension().lastPathComponent, inputs: [u], output: MusicConverter.output(for: u, in: folder, format: p.format, name: String(format: "%02d - Track", i + 1)), preset: p)
        })
        note = Localized.plural(disc.count, one: "Importing %@ track.", other: "Importing %@ tracks.")
    }

    // MARK: jobs

    @ViewBuilder private var jobsBox: some View {
        if !queue.jobs.isEmpty {
            MusicSheetCard {
                VStack(alignment: .leading, spacing: MusicSpace.sm) {
                    HStack {
                        Text(Localized.string("Conversions")).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                        Spacer()
                        if queue.isBusy { Button(Localized.string("Cancel all")) { queue.cancelAll() }.buttonStyle(.plain).foregroundStyle(accent).atlas("control.music.convertCancelAll") }
                        else { Button(Localized.string("Clear list")) { queue.clearFinished() }.buttonStyle(.plain).foregroundStyle(accent).atlas("control.music.convertClearList") }
                    }
                    ForEach(queue.jobs) { j in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(verbatim: j.title).font(Typography.bodyMedium).lineLimit(1)
                                Spacer()
                                switch j.state {
                                case .waiting: Text(Localized.string("Waiting")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                                case .running: Text(verbatim: "\(Int(j.progress * 100))%").font(Typography.timestamp)
                                case .done: Label(Localized.string("Done"), systemImage: "checkmark.circle.fill").font(Typography.caption).foregroundStyle(.green)
                                case .failed: Text(Localized.string("Failed")).font(Typography.caption).foregroundStyle(.red)
                                case .cancelled: Text(Localized.string("Cancelled")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                                }
                                if j.state == .waiting || j.state == .running {
                                    Button { queue.cancel(j.id) } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).accessibilityLabel(Localized.string("Cancel")).atlas("control.music.convertCancel")
                                }
                                #if os(macOS)
                                if j.state == .done { Button(Localized.string("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([j.output]) }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).atlas("control.music.convertReveal") }
                                #endif
                            }
                            if j.state == .running { ProgressView(value: j.progress) }
                            if case .failed(let m) = j.state { Text(verbatim: m).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                        }
                    }
                }
            }
        }
    }
}

enum MusicConvertPresets {
    static let key = "music.convert.presets"
    static var defaultFolder: URL { FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first?.appendingPathComponent("StreamSetu Converted") ?? FileManager.default.temporaryDirectory }
    static func load(_ d: UserDefaults = .standard) -> [MusicConversionPreset] { d.data(forKey: key).flatMap { try? JSONDecoder().decode([MusicConversionPreset].self, from: $0) } ?? [] }
    static func save(_ p: [MusicConversionPreset], _ d: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(p) { d.set(data, forKey: key) } }
}

#if os(macOS)
enum MusicConvertPanels {
    @MainActor static func chooseAudio(types: [UTType] = [.audio]) -> [URL] {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false; p.allowedContentTypes = types
        return p.runModal() == .OK ? p.urls : []
    }
    @MainActor static func chooseImage() -> URL? {
        let p = NSOpenPanel(); p.allowedContentTypes = [.jpeg, .png]; p.canChooseDirectories = false
        return p.runModal() == .OK ? p.url : nil
    }
    @MainActor static func chooseFolder() -> URL? {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        return p.runModal() == .OK ? p.url : nil
    }
}
#endif
