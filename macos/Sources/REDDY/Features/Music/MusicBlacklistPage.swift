import SwiftUI

// The "Never play" list: tracks and artists the person has blocked, with readable names where the library knows them.

enum MusicBlacklistLogic {
    enum Kind: Hashable, Sendable { case track, artist, unknown }
    struct Entry: Hashable, Identifiable, Sendable {
        var key: String
        var kind: Kind
        var name: String
        var detail: String
        var thumbnails: [MusicThumbnail]
        var id: String { key }
    }

    /// Turns the stored keys (track uids and artist ids) into rows. Names come from tracks the library has seen; a key it has never seen shows as is.
    static func entries(keys: Set<String>, known tracks: [MusicTrack]) -> [Entry] {
        var byUID: [String: MusicTrack] = [:]
        var artists: [String: MusicArtistRef] = [:]
        for t in tracks {
            if byUID[t.uid] == nil { byUID[t.uid] = t }
            for a in t.artists where artists[a.id] == nil { artists[a.id] = a }
        }
        return keys.map { k -> Entry in
            if let t = byUID[k] { return Entry(key: k, kind: .track, name: t.title, detail: t.artistLine, thumbnails: t.thumbnails) }
            if let a = artists[k] { return Entry(key: k, kind: .artist, name: a.name, detail: "Artist", thumbnails: a.thumbnails) }
            return Entry(key: k, kind: .unknown, name: k, detail: "Not in your history", thumbnails: [])
        }
        .sorted { ($0.name.lowercased(), $0.key) < ($1.name.lowercased(), $1.key) }
    }

    static func filter(_ entries: [Entry], query: String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.name.lowercased().contains(q) || $0.detail.lowercased().contains(q) }
    }
}

struct MusicBlacklistPage: View {
    let hub: MusicHub
    @State private var query = ""
    @State private var confirmClear = false
    @Environment(\.reddyAccent) private var accent

    private var all: [MusicBlacklistLogic.Entry] {
        let library = hub.library
        let known = library.history.map(\.track) + library.liked + library.playlists.flatMap(\.tracks) + hub.player.queue
        return MusicBlacklistLogic.entries(keys: library.blacklist, known: known)
    }

    var body: some View {
        let all = self.all
        let shown = MusicBlacklistLogic.filter(all, query: query)
        MusicScreen(title: Localized.string("Never Play"), trailing: {
            Button("Clear All") { confirmClear = true }
                .musicButton(.destructive).disabled(all.isEmpty).accessibilityLabel("Clear the whole never-play list").atlas("control.music.blockedSongsClearTheWholeNeverPlayList")
        }) {
            VStack(alignment: .leading, spacing: MusicSpace.md) {
                Text("Skipped everywhere in Music until you remove them.")
                    .musicText(.body).foregroundStyle(ColorTokens.textSecondary)
                if all.isEmpty {
                    MusicEmptyState(glyph: .emptyLibrary, title: Localized.string("Nothing is blocked"), message: Localized.string("Choose Never Play This Track on any song to add it here."))
                } else {
                    HStack(spacing: MusicSpace.xs) {
                        Image(systemName: "magnifyingglass").foregroundStyle(ColorTokens.textTertiary)
                        TextField("Filter", text: $query).textFieldStyle(.plain).musicText(.body).accessibilityLabel("Filter the never-play list")
                    }
                    .padding(.horizontal, MusicSpace.sm).frame(height: MusicButtonSize.regular.height)
                    .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous))
                    .musicContrastBorder(cornerRadius: MusicCorner.control)
                    if shown.isEmpty {
                        Text("No matches").musicText(.body).foregroundStyle(ColorTokens.textTertiary)
                    } else {
                        LazyVStack(spacing: 0) { ForEach(Array(shown.enumerated()), id: \.element.id) { i, e in
                            if i > 0 { Divider().overlay(ColorTokens.line) }
                            row(e)
                        } }
                    }
                }
            }
        }
        .confirmationDialog("Clear the never-play list?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) { clearAll() }.atlas("control.music.blockedSongsClearAll")
            Button("Cancel", role: .cancel) {}.atlas("control.music.blockedSongsCancel")
        } message: { Text("Everything on it can be played again.") }
    }

    private func row(_ e: MusicBlacklistLogic.Entry) -> some View {
        HStack(spacing: MusicSpace.sm) {
            if e.thumbnails.isEmpty {
                Image(systemName: e.kind == .artist ? "person.fill" : "nosign").font(.system(size: MusicIconSize.medium)).foregroundStyle(ColorTokens.textTertiary)
                    .frame(width: MusicSpace.huge, height: MusicSpace.huge).background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous)).accessibilityHidden(true)
            } else { MusicArtwork(e.thumbnails, size: MusicSpace.huge, corner: e.kind == .artist ? MusicSpace.lg : MusicCorner.control) }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: e.name).font(Typography.bodyMedium).lineLimit(1)
                Text(verbatim: e.detail).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(verbatim: e.kind == .artist ? "Artist" : e.kind == .track ? "Track" : "").font(Typography.micro).foregroundStyle(ColorTokens.textTertiary)
            Button("Remove") { remove(e) }.musicButton(.secondary, size: .compact, accentText: true)
                .accessibilityLabel("Allow \(e.name) again").atlas("control.music.blockedSongsAllowAgain")
        }
        .padding(.vertical, MusicSpace.xs)
        .accessibilityElement(children: .contain)
    }

    /// The library toggles by key, so a key that is on the list comes off it.
    private func remove(_ e: MusicBlacklistLogic.Entry) {
        if hub.library.blacklist.contains(e.key) { hub.library.toggleBlacklist(artist: MusicArtistRef(id: e.key, name: e.name)) }
    }

    private func clearAll() {
        for k in hub.library.blacklist { hub.library.toggleBlacklist(artist: MusicArtistRef(id: k, name: "")) }
    }
}
