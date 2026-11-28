import SwiftUI
import UniformTypeIdentifiers

/// Bringing playlists over from Spotify: link, data export (zip or JSON) or CSV, then matching, review and creation as local playlists. Nothing leaves the device
/// except searches in the person's own active music source and the public Spotify page for a pasted link.
@MainActor
struct MusicImportPage: View {
    let hub: MusicHub
    @Bindable var job: SpotifyImportJob
    var onClose: (() -> Void)? = nil

    @State private var link = ""
    @State private var picking = false
    @State private var dropTargeted = false
    @State private var tab = ImportTier.check
    @State private var names: [Int: String] = [:]
    @State private var keepUpdated = false
    @State private var changing: ImportRow?
    @State private var tick = Date()
    @Environment(\.reddyAccent) private var accent
    @State private var scheduler = MusicImportScheduler.shared

    init(hub: MusicHub, job: SpotifyImportJob = .shared, onClose: (() -> Void)? = nil) { self.hub = hub; self.job = job; self.onClose = onClose }

    var body: some View {
        MusicPageColumn(spacing: MusicSpace.md) {
                HStack(spacing: MusicSpace.sm) {
                    Text("Import from Spotify").font(Typography.pageTitle).accessibilityAddTraits(.isHeader)
                    MusicStatusChip(title: "Experimental", symbol: "flask")
                    Spacer()
                    if let onClose { Button("Close", action: onClose).musicButton(.secondary).keyboardShortcut(.cancelAction).atlas("control.music.importClose") }
                }
                switch job.phase {
                case .idle, .cancelled: source(note: job.phase == .cancelled ? String(localized: "Import stopped. What was found is remembered, so starting again resumes.") : nil)
                case .reading: HStack { MusicLoadingIcon(size: MusicIconSize.small); Text("Reading…") }
                case .pick: pick
                case .matching: matching
                case .review: review
                case .creating: creating
                case .done: done
                case .failed(let e): failed(e)
                }
        }
        .background(ColorTokens.background)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip, .json, .commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            read(url)
        }
        .dropDestination(for: URL.self) { urls, _ in
            if let u = urls.first(where: { !$0.isFileURL }) { link = u.absoluteString; job.load(link: link); return true }
            guard let f = urls.first(where: \.isFileURL) else { return false }
            read(f); return true
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: MusicCorner.compactCardLarge, style: .continuous).strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [6])).padding(MusicSpace.xs).allowsHitTesting(false) } }
        .sheet(item: $changing) { row in ChangePicker(job: job, row: row) { changing = nil } }
        .task(id: job.phase) { while !Task.isCancelled, job.phase == .matching || job.phase == .failed(.busy) { try? await Task.sleep(for: .seconds(15)); tick = Date() } }
    }

    private func read(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let d = try? Data(contentsOf: url) else { job.load(file: Data(), name: url.lastPathComponent); return }
        job.load(file: d, name: url.lastPathComponent)
    }

    // MARK: steps

    private func source(note: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let note { Text(note).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
            Text("Paste a public playlist or album link").musicText(.section)
            HStack {
                TextField("https://open.spotify.com/playlist/…", text: $link).textFieldStyle(.roundedBorder).onSubmit { job.load(link: link) }
                    .accessibilityLabel("Spotify link")
                Button("Continue") { job.load(link: link) }.disabled(link.trimmingCharacters(in: .whitespaces).isEmpty).musicButton(.primary).atlas("control.music.importContinue")
            }
            Divider()
            Text("Use your Spotify data").musicText(.section)
            HStack(spacing: MusicSpace.xs) {
                Text("Private playlists and Liked Songs come from your Spotify data export.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                MusicInfoButton(title: "Use your Spotify data", text: "Private playlists and Liked Songs come from the data export you request from Spotify. It arrives by email, usually within a few days. You can also use a CSV from an export tool.")
            }
            HStack {
                Link("Request your data", destination: URL(string: "https://www.spotify.com/account/privacy/")!)
                Button("Choose file…") { picking = true }.musicButton(.secondary).atlas("control.music.importChooseFile")
            }
            Text("You can also drop a .zip, .json or .csv file anywhere on this window.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            autoUpdateSection
            if let c = job.cooldownEnds { Text("Searches are resting until \(c.formatted(date: .omitted, time: .shortened)).").font(Typography.caption).foregroundStyle(ColorTokens.warning) }
        }
    }

    /// Imports made from a link can be read again. Auto-update is off until switched on here; it checks at launch and then at most once an hour.
    @ViewBuilder private var autoUpdateSection: some View {
        let ids = job.sources.records.keys.compactMap(UUID.init(uuidString:)).filter { hub.library.playlist(id: $0) != nil }
            .sorted { (hub.library.playlist(id: $0)?.name ?? "").localizedCaseInsensitiveCompare(hub.library.playlist(id: $1)?.name ?? "") == .orderedAscending }
        if !ids.isEmpty {
            Divider()
            Text("Update from Spotify").musicText(.section)
            HStack(spacing: MusicSpace.xs) {
                Text("Off until you switch it on.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                MusicInfoButton(title: "Update from Spotify", text: "Playlists you brought over from a link can follow the Spotify list. Nothing is checked unless you switch it on.")
            }
            ForEach(ids, id: \.self) { id in autoUpdateRow(id, name: hub.library.playlist(id: id)?.name ?? "") }
        }
    }

    private func autoUpdateRow(_ id: UUID, name: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Typography.bodyMedium).lineLimit(1)
                if let o = scheduler.outcome(for: id) {
                    Text("\(o.summary) · \(o.at.formatted(date: .abbreviated, time: .shortened))").font(Typography.caption).foregroundStyle(o.kind == .failed ? ColorTokens.warning : ColorTokens.textSecondary)
                }
            }
            Spacer()
            Toggle("Update automatically", isOn: Binding(get: { scheduler.isAutoUpdate(id) }, set: { scheduler.setAutoUpdate($0, for: id) }))
                .toggleStyle(.switch).labelsHidden().accessibilityLabel("Update \(name) automatically").atlas("control.music.importUpdateAutomatically")
        }
    }

    private var pick: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lists found").musicText(.section)
                Spacer()
                Button("Select all") { job.selected = Set(job.lists.indices) }.musicButton(.tertiary, size: .compact).atlas("control.music.importSelectAll")
                Button("Select none") { job.selected = [] }.musicButton(.tertiary, size: .compact).atlas("control.music.importSelectNone")
            }
            ForEach(Array(job.lists.enumerated()), id: \.offset) { i, l in
                Toggle(isOn: Binding(get: { job.selected.contains(i) }, set: { on in if on { job.selected.insert(i) } else { job.selected.remove(i) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.name).font(Typography.bodyMedium)
                        Text("\(l.tracks.count) songs" + (l.owner.map { " · " + $0 } ?? "")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                        if l.truncated { Text("Only the first 100 songs were shared. Use your Spotify data to bring over all of them.").font(Typography.caption).foregroundStyle(ColorTokens.warning) }
                    }
                }.atlas("control.music.importSongs")
            }
            let n = job.selected.reduce(0) { $0 + job.lists[$1].tracks.count }
            HStack {
                Button("Back") { job.reset() }.musicButton(.secondary).atlas("control.music.importBack")
                Button("Find \(n) songs") { job.startMatching() }.musicButton(.primary).disabled(job.selected.isEmpty).atlas("control.music.importFindSongs")
            }
        }
    }

    private var matching: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Matching songs").musicText(.section)
            ProgressView(value: Double(job.done), total: Double(max(1, job.total)))
            Text("\(job.done) of \(job.total)" + (job.minutesLeft(now: tick).map { " · about \($0) min left" } ?? "")).font(Typography.caption).monospacedDigit()
            HStack(spacing: 16) {
                counter("Matched", job.count(.matched)); counter("To check", job.count(.check)); counter("Not found", job.count(.missing))
            }
            ForEach(job.recentMatched) { r in
                HStack { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent); Text(r.source.title).lineLimit(1); Text(r.source.artists.first ?? "").foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }.font(Typography.row)
            }
            Text("About one song every two seconds, so the service is not hammered.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            if let w = job.waitingUntil { Text("Taking a break. Resuming at \(w.formatted(date: .omitted, time: .shortened)).").font(Typography.caption).foregroundStyle(ColorTokens.warning) }
            HStack {
                if let onClose { Button("Keep browsing", action: onClose).musicButton(.secondary).atlas("control.music.importKeepBrowsing") }
                Button("Stop", role: .destructive) { job.cancel() }.musicButton(.destructive).atlas("control.music.importStop")
            }
        }
    }

    private func counter(_ title: String, _ n: Int) -> some View {
        VStack(alignment: .leading) { Text("\(n)").font(.system(size: MusicIconSize.row, weight: .semibold)).monospacedDigit(); Text(title.loc).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
    }

    // MARK: review

    private var review: some View {
        let initial: ImportTier = job.count(.check) > 0 ? .check : job.count(.missing) > 0 ? .missing : .matched
        let rows = job.rows(in: tab)
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Show", selection: $tab) {
                Text("To check (\(job.count(.check)))").tag(ImportTier.check)
                Text("Not found (\(job.count(.missing)))").tag(ImportTier.missing)
                Text("Matched (\(job.count(.matched)))").tag(ImportTier.matched)
            }.pickerStyle(.segmented).labelsHidden().atlas("control.music.importShow")
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { r in reviewRow(r) }
                if rows.isEmpty { Text("Nothing here.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
            }
            Divider()
            creationOptions
        }
        .onAppear { tab = initial }
    }

    private func reviewRow(_ r: ImportRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.source.title).font(Typography.rowMedium).lineLimit(1)
                Text(([r.source.artists.joined(separator: ", "), r.source.album ?? ""]).filter { !$0.isEmpty }.joined(separator: " · ")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let p = r.pick {
                HStack(spacing: 6) {
                    MusicArtwork(p.thumbnails, size: 30, corner: 4)
                    VStack(alignment: .leading, spacing: 0) { Text(p.title).font(Typography.row).lineLimit(1); Text(p.displayArtistLine).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else { Text("No match").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).frame(maxWidth: .infinity, alignment: .leading) }
            if r.pick != nil && r.tier == .check { Button("Looks right") { job.confirm(r.key) }.musicButton(.secondary, size: .compact).atlas("control.music.importLooksRight") }
            Button("Change") { changing = r }.musicButton(.tertiary, size: .compact).atlas("control.music.importChange")
            if r.pick != nil { Button("Leave out") { job.leaveOut(r.key) }.musicButton(.tertiary, size: .compact).atlas("control.music.importLeaveOut") }
        }
        .font(Typography.caption).padding(MusicSpace.xs).background(RoundedRectangle(cornerRadius: MusicCorner.controlLarge, style: .continuous).fill(ColorTokens.elevated))
    }

    private var creationOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create playlists on this device").musicText(.section)
            if job.selected.count == 1, let i = job.selected.first {
                TextField("Playlist name", text: Binding(get: { names[i] ?? job.lists[i].name }, set: { names[i] = $0 })).textFieldStyle(.roundedBorder)
            }
            if job.selected.contains(where: { job.lists[$0].shareURL != nil }) { Toggle("Keep up to date with Spotify", isOn: $keepUpdated).atlas("control.music.importKeepUpToDateWithSpotify") }
            HStack {
                Button("Start over") { job.reset() }.musicButton(.secondary).atlas("control.music.importStartOver")
                Button("Create") { job.create(names: names, keepUpdated: keepUpdated) }.musicButton(.primary).atlas("control.music.importCreate")
            }
        }
    }

    private var creating: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Creating playlists").musicText(.section)
            ProgressView(value: Double(job.done), total: Double(max(1, job.total)))
            Text("\(job.done) of \(job.total) done").font(Typography.caption).monospacedDigit()
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import done").musicText(.section)
            ForEach(job.results) { r in
                HStack {
                    VStack(alignment: .leading) {
                        Text(r.name).font(Typography.bodyMedium)
                        Text("\(r.added) songs" + (r.notFound > 0 ? " · \(r.notFound) not found" : "")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    }
                    Spacer()
                    Button("Open") { hub.open(.localPlaylist(r.id)); onClose?() }.musicButton(.secondary, size: .compact).atlas("control.music.importOpen")
                }
                if scheduler.canUpdate(r.id) { Toggle("Update automatically", isOn: Binding(get: { scheduler.isAutoUpdate(r.id) }, set: { scheduler.setAutoUpdate($0, for: r.id) })).font(Typography.caption).atlas("control.music.importUpdateAutomatically") }
            }
            HStack {
                if !job.missingText.isEmpty { Button("Copy missing songs") { Self.copy(job.missingText) }.musicButton(.secondary).atlas("control.music.importCopyMissingSongs") }
                Button("Import another") { job.reset() }.musicButton(.primary).atlas("control.music.importImportAnother")
            }
        }
    }

    private func failed(_ e: ImportError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ImportMessages.text(e)).font(Typography.body)
            Text("Songs that were already found are remembered, so trying again picks up where it stopped.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            if case .cooldown(let until) = e { Button("Try again at \(until.formatted(date: .omitted, time: .shortened))") { job.reset() }.musicButton(.primary).disabled(until > tick).atlas("control.music.importTryAgainAt") }
            else { Button("Try again") { job.reset() }.musicButton(.primary).atlas("control.music.importTryAgain") }
        }
    }

    private static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// The candidates for one row, and a search of the active source to find the right song.
private struct ChangePicker: View {
    let job: SpotifyImportJob
    let row: ImportRow
    let close: () -> Void
    @State private var query = ""
    @State private var found: [MusicTrack] = []
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Change song for \"\(row.source.title)\"").musicText(.section)
            HStack {
                TextField("Search your music source", text: $query).textFieldStyle(.roundedBorder).onSubmit(run)
                Button("Search", action: run).musicButton(.secondary).disabled(query.trimmingCharacters(in: .whitespaces).count < 2).atlas("control.music.importSearch")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(found.isEmpty ? row.candidates : found, id: \.uid) { t in
                        Button { job.choose(row.key, t); close() } label: {
                            HStack(spacing: 8) {
                                MusicArtwork(t.thumbnails, size: 34, corner: 4)
                                VStack(alignment: .leading, spacing: 0) { Text(t.title).font(Typography.rowMedium).lineLimit(1); Text(t.displayArtistLine).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                                Spacer()
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).atlas("control.music.importChangepickerbodyButton")
                    }
                    if searching { MusicLoadingIcon(size: MusicIconSize.small) }
                }
            }.frame(minHeight: 200)
            HStack { Spacer(); Button("Cancel", action: close).musicButton(.secondary).keyboardShortcut(.cancelAction).atlas("control.music.importCancel") }
        }
        .padding(MusicSpace.lg).frame(width: MusicTokens.setupCardWidth, height: MusicTokens.settingsHeight - MusicSpace.huge * 3)
        .onAppear { query = ([row.source.title] + row.source.artists.prefix(1)).joined(separator: " ") }
    }

    private func run() {
        let q = query
        searching = true
        Task { found = await job.search(q); searching = false }
    }
}
