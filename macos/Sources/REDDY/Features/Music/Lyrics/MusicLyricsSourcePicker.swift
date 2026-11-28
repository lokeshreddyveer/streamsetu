import SwiftUI

// The source name under the lyrics and the popover behind it: which service answered, what the others have for this song, pinning one,
// going back to Automatic, searching by title, rating the live community lyric, and the way into the editor.

enum MusicLyricsAttribution {
    /// The always-visible button label. Owner rule: no source or credit caption on the page, so it never names a service or an author; the source is
    /// shown only inside the popover this button opens.
    static func caption(_ l: MusicLyrics?) -> String {
        guard let l, !l.isEmpty else { return Localized.string("Find lyrics") }
        if l.instrumental { return Localized.string("Instrumental") }
        return Localized.string("Lyrics")
    }
}

/// What one source row says. Pure, so the wording is tested.
enum MusicLyricsSourceRowState: Equatable, Sendable {
    case idle
    case loading
    case found(kind: MusicLyricsKind, translated: Bool)
    case notFound
    case unreachable

    static func status(_ s: MusicLyricsSourceRowState, enabled: Bool, current: Bool) -> String {
        if current { return Localized.string("Showing now") }
        switch s {
        case .idle: return Localized.string(enabled ? "Tap to check" : "Off · Check")
        case .loading: return Localized.string("Looking...")
        case .found(let kind, _): return kind.label
        case .notFound: return Localized.string("Not found")
        case .unreachable: return Localized.string("Unreachable · Try again")
        }
    }

    var usable: Bool { if case .found = self { return true } else { return false } }
}

@MainActor
enum MusicLyricsContribution {
    /// The highlighted row: "Sync these lyrics" (no word timings yet), "Improve these lyrics", or "Continue your draft".
    nonisolated static func entryTitle(lyrics: MusicLyrics?, draft: MusicLyricsDraft?) -> String {
        if let d = draft { return Localized.string("Continue your draft (%1$@ of %2$@ lines timed)", String(d.doneCount), String(d.total)) }
        return Localized.string((lyrics?.isWordTimed ?? false) ? "Improve these lyrics" : "Sync these lyrics")
    }

    /// Not offered for local files, a typed search, or a track with no usable video id.
    static func videoID(for track: MusicTrack, hub: MusicHub) -> String? {
        let r = MusicLyricsRequest.make(track: track, videoID: hub.lyrics.videoIDResolver?(track))
        guard !r.isLocal, let v = r.videoID, MusicLyricsSubmissionBody.isValidFiledID(v) else { return nil }
        return v
    }
}

@MainActor @Observable
final class MusicLyricsSourcePickerModel {
    private(set) var rows: [String: MusicLyricsSourceRowState] = [:]
    private(set) var answers: [String: MusicLyrics] = [:]
    private(set) var live: MusicLyricsLiveState?
    private(set) var canContribute = false
    private(set) var draft: MusicLyricsDraft?
    private(set) var voteError: String?
    private(set) var busy = false
    var searching = false
    var title = ""
    var artist = ""

    private let hub: MusicHub
    private let track: MusicTrack
    private let client: MusicLyricsSubmissionClient
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    static nonisolated(unsafe) private var anonymousSupport: Bool?

    init(hub: MusicHub, track: MusicTrack, client: MusicLyricsSubmissionClient = MusicLyricsSubmissionClient()) {
        self.hub = hub; self.track = track; self.client = client
    }

    var query: MusicLyricsQuery? { searching && !title.isEmpty ? MusicLyricsQuery(title: title, artists: artist) : nil }

    func state(_ id: String) -> MusicLyricsSourceRowState { rows[id] ?? .idle }

    /// Opening asks every source that is ON, once, except the one on screen (its answer is reused).
    func opened(current: MusicLyrics?) {
        cancel()
        if title.isEmpty {
            let v = MusicLyricsQueryBuilder.variants(for: MusicLyricsRequest.make(track: track)).first
            title = v?.title ?? MusicLyricsText.searchTitle(track.title)
            artist = v?.artists ?? track.artistLine
        }
        let enabled = hub.lyrics.sourceEntries.filter(\.enabled).map(\.id)
        for id in enabled where id != current?.providerID && rows[id] == nil { check(id) }
        if let c = current { answers[c.providerID] = c; rows[c.providerID] = .found(kind: c.kind, translated: c.hasTranslation) }
        loadContribution(current: current)
    }

    func cancel() {
        tasks.forEach { $0.cancel() }; tasks = []
        for (id, st) in rows where st == .loading { rows[id] = nil }   // a check that was cancelled is asked again next time
    }

    func check(_ id: String) {
        rows[id] = .loading
        let t = Task { [weak self] in
            guard let self else { return }
            let a = await self.hub.lyrics.ask(providerID: id, for: self.track, query: self.query)
            guard !Task.isCancelled else { return }
            switch a {
            case .hit(let l): self.answers[id] = l; self.rows[id] = .found(kind: l.kind, translated: l.hasTranslation)
            case .none: self.rows[id] = .notFound
            case .error: self.rows[id] = .unreachable
            }
        }
        tasks.append(t)
    }

    /// Searching by title asks everything again with the typed words.
    func search() {
        cancel()    // checks still running for the old words must not write their answers into the new search
        rows = [:]; answers = [:]
        for e in hub.lyrics.sourceEntries where e.enabled && e.id != MusicLyricsCommunity.providerID { check(e.id) }
    }

    func pick(_ id: String) async -> MusicLyrics? {
        busy = true; defer { busy = false }
        return await hub.lyrics.choose(providerID: id, for: track, query: query)
    }

    func automatic() async -> MusicLyrics? {
        busy = true; defer { busy = false }
        return await hub.lyrics.choose(providerID: nil, for: track)
    }

    // MARK: contribution and rating

    private func loadContribution(current: MusicLyrics?) {
        guard let vid = MusicLyricsContribution.videoID(for: track, hub: hub), query == nil,
              hub.lyrics.sourceEntries.contains(where: { $0.id == MusicLyricsCommunity.providerID && $0.enabled }) else { canContribute = false; return }
        draft = MusicLyricsDraftStore(directory: MusicLyricsDraftStore.defaultDirectory()).load(videoID: vid)
        let t = Task { [weak self] in
            guard let self else { return }
            if Self.anonymousSupport == nil { Self.anonymousSupport = await self.client.supportsAnonymous() }
            self.canContribute = Self.anonymousSupport ?? false
            if current?.providerID == MusicLyricsCommunity.providerID, self.canContribute, let s = try? await self.client.state(videoID: current?.communityID ?? vid) {
                self.live = s
            }
        }
        tasks.append(t)
    }

    /// Only the live revision is rated: a cached older copy or a hand-picked older revision is not offered.
    func canRate(_ current: MusicLyrics?) -> Bool {
        guard let c = current, c.providerID == MusicLyricsCommunity.providerID, let live, let r = live.revision else { return false }
        return c.revision == r
    }

    func vote(_ value: Int, current: MusicLyrics?) async {
        guard let vid = current?.communityID ?? MusicLyricsContribution.videoID(for: track, hub: hub), let l = live else { return }
        let target = l.myVote == value ? 0 : value
        let before = l
        live?.myVote = target
        do {
            let r = try await client.vote(filedID: vid, value: target)
            live?.up = r.up; live?.down = r.down; live?.myVote = r.mine; voteError = nil
        } catch let e as MusicLyricsSubmissionError { live = before; voteError = e.message } catch { live = before; voteError = MusicLyricsSubmissionError.unavailable.message }
    }

    func report(_ reason: MusicLyricsReportReason, note: String, current: MusicLyrics?) async -> Bool {
        guard let vid = current?.communityID ?? MusicLyricsContribution.videoID(for: track, hub: hub) else { return false }
        do { try await client.report(filedID: vid, reason: reason, note: note); voteError = nil; return true }
        catch let e as MusicLyricsSubmissionError { voteError = e.message; return false } catch { voteError = MusicLyricsSubmissionError.unavailable.message; return false }
    }
}

struct MusicLyricsSourcePicker: View {
    let hub: MusicHub
    let track: MusicTrack
    let lyrics: MusicLyrics?
    let onChanged: (MusicLyrics?) -> Void
    let onOpenEditor: () -> Void
    /// Bumped by the panel's primary "Find lyrics" button: opens the search sheet with the cleaned title filled in.
    var findRequest = 0
    /// With no lyrics the panel shows its own button, so the small attribution link goes away.
    var showsLabel = true

    @State private var model: MusicLyricsSourcePickerModel
    @State private var shown = false
    @State private var finding = false
    @State private var reporting = false
    @State private var reportReason: MusicLyricsReportReason = .timing
    @State private var reportNote = ""
    @State private var reportSent = false
    @Environment(\.reddyAccent) private var accent

    init(hub: MusicHub, track: MusicTrack, lyrics: MusicLyrics?, findRequest: Int = 0, showsLabel: Bool = true,
         onChanged: @escaping (MusicLyrics?) -> Void, onOpenEditor: @escaping () -> Void) {
        self.hub = hub; self.track = track; self.lyrics = lyrics; self.onChanged = onChanged; self.onOpenEditor = onOpenEditor
        self.findRequest = findRequest; self.showsLabel = showsLabel
        _model = State(initialValue: MusicLyricsSourcePickerModel(hub: hub, track: track))
    }

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 5) {
                if lyrics?.pinned == true { Image(systemName: "pin.fill").font(.system(size: 10)) }
                Text(verbatim: MusicLyricsAttribution.caption(lyrics)).font(Typography.caption).underline()
                if let l = lyrics, l.offsetMs != 0 { Text(verbatim: MusicLyricsMotion.offsetLabel(l.offsetMs)).font(Typography.caption) }
            }
            .foregroundStyle(ColorTokens.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Localized.string("Lyrics options. Choose another source"))
        .opacity(showsLabel ? 1 : 0).frame(width: showsLabel ? nil : 0, height: showsLabel ? nil : 0).allowsHitTesting(showsLabel)
        .popover(isPresented: $shown, arrowEdge: .top) { popover }
        .musicFocusGuard(isPresented: $shown)
        .sheet(isPresented: $finding) { findSheet }
        .onChange(of: findRequest) { _, _ in model.searching = true; finding = true }
        .onChange(of: finding) { _, on in if on { model.opened(current: lyrics) } else { model.cancel() } }
        .onChange(of: shown) { _, on in if on { model.opened(current: lyrics) } else { model.cancel() } }
        .onChange(of: track.uid) { _, _ in shown = false; model.cancel() }.atlas("control.music.lyricsLyricsSourceChooseAnother")
    }

    /// The small "Find lyrics" sheet: type another title and artist, search every source, pick a result.
    private var findSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: Localized.string("Find lyrics")).font(Typography.heading)
                Spacer()
                Button(Localized.string("Done")) { finding = false }.musicButton(.secondary).keyboardShortcut(.cancelAction).atlas("control.music.lyricsDone")
            }.padding(14)
            popover
        }
        .frame(width: 360, height: 560)
        .background(ColorTokens.surface)
    }

    private var popover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: Localized.string("Lyrics source")).font(Typography.heading)
                Text(verbatim: Localized.string("Just for this song. The default order is in Settings.")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                automaticRow
                ForEach(hub.lyrics.sourceEntries, id: \.id) { e in sourceRow(e) }
                searchBlock
                if model.canRate(lyrics) { rateBlock }
                if model.canContribute { contributionRow }
                if let err = model.voteError { Text(verbatim: err).font(Typography.caption).foregroundStyle(ColorTokens.warning) }
            }
            .padding(14)
        }
        .frame(width: 330, height: 460)
    }

    private var automaticRow: some View {
        Button { Task { onChanged(await model.automatic()); shown = false } } label: {
            HStack {
                Image(systemName: lyrics?.pinned == true ? "circle" : "checkmark.circle.fill").foregroundStyle(accent)
                VStack(alignment: .leading) {
                    Text(verbatim: Localized.string("Automatic")).font(Typography.bodyMedium)
                    Text(verbatim: lyrics.map { Localized.string("Showing %@", $0.sourceName) } ?? Localized.string("First match in your order")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                }
                Spacer()
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(Localized.string("Automatic: first match in your order")).atlas("control.music.lyricsAutomaticFirstMatchInYourOrder")
    }

    private func sourceRow(_ e: MusicLyricsSources.Entry) -> some View {
        let st = model.state(e.id)
        let current = lyrics?.providerID == e.id
        return Button {
            switch st {
            case .found: Task { onChanged(await model.pick(e.id)); shown = false; finding = false }
            case .idle, .unreachable: model.check(e.id)
            default: break
            }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(current ? accent : .clear).frame(width: 8, height: 8).overlay(Circle().strokeBorder(ColorTokens.line))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: MusicLyricsSources.name(e.id)).font(Typography.bodyMedium)
                    if let via = model.answers[e.id]?.via { Text(verbatim: Localized.string("via %@", via)).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
                }
                Spacer()
                if st == .loading { MusicLoadingIcon(size: MusicIconSize.small) }
                else {
                    if case .found(_, true) = st { Image(systemName: "translate").font(.system(size: 11)) }
                    Text(verbatim: MusicLyricsSourceRowState.status(st, enabled: e.enabled, current: current)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                }
            }
            .opacity(st == .notFound ? 0.45 : 1).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(e.enabled ? "" : Localized.string("Turned off in Settings. Check it for this song anyway?"))
        .disabled(st == .notFound || st == .loading)
        .accessibilityLabel(Text(verbatim: "\(MusicLyricsSources.name(e.id)): \(MusicLyricsSourceRowState.status(st, enabled: e.enabled, current: current))")).atlas("control.music.lyricsVia")
    }

    private var searchBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(Localized.string(model.searching ? "Back to this song" : "Wrong song? Search by title")) {
                model.searching.toggle()
                if !model.searching { model.title = MusicLyricsText.searchTitle(track.title); model.artist = track.artistLine; model.opened(current: lyrics) }
            }.buttonStyle(.plain).foregroundStyle(accent).font(Typography.caption).atlas("control.music.lyricsBackToThisSong")
            if model.searching {
                TextField("Title", text: $model.title).textFieldStyle(.roundedBorder).accessibilityLabel("Song title")
                TextField("Artist", text: $model.artist).textFieldStyle(.roundedBorder).accessibilityLabel("Artist")
                Button("Search") { model.search() }.musicButton(.secondary).accessibilityLabel("Search sources with these words").atlas("control.music.lyricsSearchSourcesWithTheseWords")
                Text(verbatim: Localized.string("Results for %@", model.title)).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            }
        }
    }

    private var rateBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { Task { await model.vote(1, current: lyrics) } } label: { Image(systemName: model.live?.myVote == 1 ? "hand.thumbsup.fill" : "hand.thumbsup") }
                    .accessibilityLabel("Good lyrics").atlas("control.music.lyricsGoodLyrics")
                Text(verbatim: "\(model.live?.up ?? 0)").font(Typography.caption)
                Button { Task { await model.vote(-1, current: lyrics) } } label: { Image(systemName: model.live?.myVote == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown") }
                    .accessibilityLabel("Bad lyrics").atlas("control.music.lyricsBadLyrics")
                Text(verbatim: "\(model.live?.down ?? 0)").font(Typography.caption)
                Spacer()
                Button(reporting ? "Cancel" : "Report") { reporting.toggle(); reportSent = false }.font(Typography.caption).accessibilityLabel("Report a problem with these lyrics").atlas("control.music.lyricsReportAProblemWithTheseLyrics")
            }
            .buttonStyle(.plain)
            if reporting {
                Picker("Reason", selection: $reportReason) { ForEach(MusicLyricsReportReason.allCases) { Text(verbatim: $0.label).tag($0) } }.labelsHidden().atlas("control.music.lyricsReason")
                TextField("Note (optional)", text: $reportNote).textFieldStyle(.roundedBorder).accessibilityLabel("Optional note")
                Button(Localized.string(reportSent ? "Sent" : "Send report")) {
                    Task { reportSent = await model.report(reportReason, note: reportNote, current: lyrics) }
                }.musicButton(.secondary).disabled(reportSent).atlas("control.music.lyricsSent")
            }
        }
    }

    private var contributionRow: some View {
        Button { shown = false; onOpenEditor() } label: {
            HStack {
                Image(systemName: "waveform.badge.plus")
                Text(verbatim: MusicLyricsContribution.entryTitle(lyrics: lyrics, draft: model.draft)).font(Typography.bodyMedium)
                Spacer()
            }
            .padding(10).background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(MusicLyricsContribution.entryTitle(lyrics: lyrics, draft: model.draft)).atlas("control.music.lyricsMusiclyricssourcepickercontributionrowButton")
    }
}
