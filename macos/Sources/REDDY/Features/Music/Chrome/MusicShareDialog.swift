import SwiftUI

/// What the share dialog is about.
enum MusicShareSubject {
    case track(MusicTrack, playing: Bool)
    case album(MusicAlbum)
    case artist(MusicArtist)
    case playlist(MusicPlaylist)

    var title: String {
        switch self { case .track(let t, _): t.title; case .album(let a): a.title; case .artist(let a): a.name; case .playlist(let p): p.name }
    }
    var subtitle: String {
        switch self {
        case .track(let t, _): t.artistLine
        case .album(let a): a.artists.map(\.name).joined(separator: ", ")
        case .artist: "Artist"
        case .playlist(let p): MusicSourceText.clean(p.owner) ?? "Playlist"
        }
    }
    var thumbs: [MusicThumbnail] {
        switch self { case .track(let t, _): t.thumbnails; case .album(let a): a.thumbnails; case .artist(let a): a.thumbnails; case .playlist(let p): p.thumbnails }
    }
    var isArtist: Bool { if case .artist = self { return true }; return false }
    /// Local files and on-device items have no link to share.
    var isShareable: Bool {
        switch self {
        case .track(let t, _): t.providerID != MusicStatsRules.localProviderID
        case .album(let a): a.providerID != MusicStatsRules.localProviderID
        case .artist(let a): a.providerID != MusicStatsRules.localProviderID
        case .playlist(let p): p.providerID != MusicStatsRules.localProviderID
        }
    }
    var link: URL? {
        switch self {
        case .track(let t, _): MusicDeepLinks.link(track: t)
        case .album(let a): MusicDeepLinks.link(album: a)
        case .artist(let a): MusicDeepLinks.link(artist: a)
        case .playlist(let p): MusicDeepLinks.link(playlist: p)
        }
    }
}

/// The "start at" choice in the share dialog, as pure rules.
enum MusicShareStart: Equatable {
    case off
    case at(Int)
    case unparsable
    case tooLong(limitSeconds: Int)

    /// `text` is what the person typed ("1:23", "83"); `durationSeconds` is the song's length, 0 when unknown.
    static func evaluate(text: String, enabled: Bool, durationSeconds: Int) -> MusicShareStart {
        guard enabled else { return .off }
        guard let s = parse(text) else { return .unparsable }
        if durationSeconds > 0, s > durationSeconds { return .tooLong(limitSeconds: durationSeconds) }
        return s > 0 ? .at(s) : .off
    }

    /// "83", "1:23" or "1:02:03" as seconds; nil when it is not a time.
    static func parse(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let nums = parts.compactMap { Int($0) }
        guard nums.count == parts.count else { return nil }
        if parts.count > 1, nums.dropFirst().contains(where: { $0 > 59 }) { return nil }
        return nums.reduce(0) { $0 * 60 + $1 }
    }

    static func clock(_ seconds: Int) -> String { MusicTime.clock(TimeInterval(seconds)) }

    /// The link with `t=<seconds>` added when a start time is chosen.
    static func link(_ base: URL, start: MusicShareStart) -> URL {
        guard case .at(let s) = start, var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        var items = c.queryItems ?? []
        items.removeAll { $0.name == "t" }
        items.append(URLQueryItem(name: "t", value: String(s)))
        c.queryItems = items
        return c.url ?? base
    }
}

/// Share a song, album, artist or playlist: a preview, the link, a Copy button, and for the playing song an optional start time.
struct MusicShareDialog: View {
    let hub: MusicHub
    let subject: MusicShareSubject
    @Binding var isPresented: Bool

    @State private var useStart = false
    @State private var startText = ""
    @State private var copied = false
    @State private var isPublic = false
    @State private var privacyBusy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var playingDuration: Int {
        if case .track(let t, _) = subject, hub.player.current?.uid == t.uid, hub.player.duration > 0 { return Int(hub.player.duration) }
        if case .track(let t, _) = subject { return Int(t.durationMs / 1000) }
        return 0
    }
    private var isPlayingTrack: Bool { if case .track(_, let playing) = subject { return playing }; return false }
    private var start: MusicShareStart { MusicShareStart.evaluate(text: startText, enabled: useStart, durationSeconds: playingDuration) }
    private var shownLink: URL? { subject.link.map { MusicShareStart.link($0, start: start) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                Text("Share").font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { isPresented = false } label: { Image(systemName: "xmark").font(MusicTokens.iconSmall).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle()) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close").atlas("control.music.shareClose")
            }
            HStack(spacing: Spacing.md) {
                MusicArtwork(subject.thumbs, size: MusicTokens.previewArtwork, corner: subject.isArtist ? MusicTokens.previewArtwork / 2 : MusicTokens.radiusRow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: subject.title).font(MusicTokens.rowTitle).lineLimit(2)
                    Text(verbatim: subject.subtitle).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            linkRow
            if isPlayingTrack { startRow }
            if case .playlist(let p) = subject { privacyRows(p) }
        }
        .padding(Spacing.xl).frame(width: MusicTokens.sheetWidth)
        .onAppear { if case .playlist(let p) = subject { isPublic = p.isPublic } }
    }

    private var linkRow: some View {
        HStack(spacing: Spacing.sm) {
            Text(verbatim: shownLink?.absoluteString ?? "").font(Typography.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .padding(.horizontal, Spacing.md).frame(maxWidth: .infinity, minHeight: MusicTokens.hitTarget, alignment: .leading)
                .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicTokens.radiusRow, style: .continuous))
                .accessibilityLabel("Link")
            Button(action: copy) {
                Label(copied ? "Done" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc").labelStyle(.titleAndIcon)
            }
            .musicButton(.primary).atlas("control.music.share").disabled(shownLink == nil).accessibilityLabel(copied ? "Link copied" : "Copy link")
        }
    }

    private var startRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Toggle("Start at", isOn: $useStart).toggleStyle(.checkbox).font(Typography.body).atlas("control.music.shareStartAt")
                TextField("0:00", text: $startText).textFieldStyle(.plain).frame(width: 64).multilineTextAlignment(.center)
                    .onChange(of: startText) { _, new in if !new.isEmpty { useStart = true } }
                    .accessibilityLabel("Start time")
                Spacer()
            }
            switch start {
            case .unparsable: Text("Enter a time like 1:23.").font(Typography.caption).foregroundStyle(ColorTokens.warning)
            case .tooLong(let limit): Text(Localized.string("The song is only %@ long.", MusicShareStart.clock(limit))).font(Typography.caption).foregroundStyle(ColorTokens.warning)
            default: EmptyView()
            }
        }
        .onAppear { startText = MusicShareStart.clock(Int(hub.player.position)) }
    }

    @ViewBuilder private func privacyRows(_ p: MusicPlaylist) -> some View {
        if !p.isPublic {
            Label("Anyone with this link will get an error until the playlist is public.", systemImage: "exclamationmark.triangle")
                .font(Typography.caption).foregroundStyle(ColorTokens.warning)
        }
        if !p.isPublic, p.providerID == YTM.providerID, YTMIDs.isEditable(p.id), let manager = YouTubeMusicAccountBuiltIns.manager, manager.isSignedIn {
            Toggle(isOn: Binding(get: { isPublic }, set: { setPublic($0, playlist: p, manager: manager) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Public").font(Typography.body)
                    Text(isPublic ? "Anyone with the link can open it." : "Only you can open it.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                }
            }
            .toggleStyle(.switch).disabled(privacyBusy).atlas("control.music.sharePublic")
        }
    }

    private func copy() {
        guard let url = shownLink else { return }
        MusicShare.copy(url)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
    }

    /// Optimistic: the switch moves at once and goes back, with a toast, if the write fails.
    private func setPublic(_ on: Bool, playlist p: MusicPlaylist, manager: YouTubeMusicAccountManager) {
        let before = isPublic
        isPublic = on
        privacyBusy = true
        Task {
            do {
                try await manager.writer.update(p.id, details: YTMPlaylistDetailsEdit(privacy: on ? .public : .private))
            } catch {
                isPublic = before
                MusicToasts.shared.error(error)
            }
            privacyBusy = false
        }
    }
}
