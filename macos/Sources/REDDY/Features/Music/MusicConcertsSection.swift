import SwiftUI

/// "Concerts" on an artist's page: the latest shows from setlist.fm with the songs they played, and one button that queues the ones you already have, in the played order.
/// Hidden when the artist has no MusicBrainz id, setlist.fm has nothing, or the build carries no setlist.fm key.
struct MusicConcertsSection: View {
    let hub: MusicHub
    let person: MusicEntityID
    let name: String
    @State private var concerts: [MusicConcert] = []
    @State private var opened: String?
    @State private var showAll = false
    @Environment(\.reddyAccent) private var accent
    @Environment(\.openURL) private var openURL

    private static let shownFirst = 3

    var body: some View {
        // A task on an empty view never runs, so a zero-height line always exists to hold it until there is something to show.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if !concerts.isEmpty { content }
        }
        // While there is nothing to show, the holder of the task must not add a row gap to the page column (it would double the spacing above and below an empty line).
        .padding(.bottom, concerts.isEmpty ? -MusicSpace.lg : 0)
        .task(id: person) { await load() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text(Localized.string("Concerts")).font(MusicTokens.rowTitle).accessibilityAddTraits(.isHeader)
            ForEach(showAll ? concerts : Array(concerts.prefix(Self.shownFirst))) { c in row(c) }
            if concerts.count > Self.shownFirst {
                Button(showAll ? Localized.string("Show fewer") : Localized.string("Show more concerts")) { showAll.toggle() }
                    .buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).atlas("control.music.concertsMore")
            }
        }
    }

    private func row(_ c: MusicConcert) -> some View {
        let open = opened == c.id
        let mine = SetlistMatcher.match(c, artist: name, pool: pool)
        return VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            Button { opened = open ? nil : c.id } label: {
                HStack(alignment: .top, spacing: MusicSpace.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: c.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "").font(Typography.captionMedium).foregroundStyle(accent)
                        Text(verbatim: c.place).font(Typography.body).lineLimit(2).multilineTextAlignment(.leading)
                        if let t = c.tour { Text(verbatim: t).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(Text(verbatim: c.place)).atlas("control.music.concertRow")
            if open {
                if c.songs.isEmpty {
                    Text(Localized.string("No songs have been added to this setlist yet.")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                } else {
                    ForEach(Array(c.songs.enumerated()), id: \.offset) { i, s in
                        Text(verbatim: "\(i + 1). \(s.name)" + (s.coverOf.map { " (\($0))" } ?? "")).font(Typography.caption)
                            .foregroundStyle(SetlistMatcher.match(.init(id: "", date: nil, venue: "", city: "", country: "", tour: nil, songs: [s], url: nil), artist: name, pool: pool).isEmpty ? ColorTokens.textTertiary : ColorTokens.textPrimary)
                    }
                    HStack(spacing: MusicSpace.sm) {
                        if !mine.isEmpty {
                            Button { hub.play(mine, at: 0, sourceName: "\(name) · \(c.place)") } label: {
                                Label(Localized.string("Play the songs I have (%@)", String(mine.count)), systemImage: "play.fill")
                            }.musicButton(.secondary, size: .compact).atlas("control.music.concertPlay")
                        }
                        if let u = c.url {
                            Button(Localized.string("Open the full setlist")) { openURL(u) }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).atlas("control.music.concertOpen")
                        }
                    }
                }
            }
        }
        .padding(MusicSpace.sm)
        .background(RoundedRectangle(cornerRadius: MusicCorner.control).fill(ColorTokens.surface))
    }

    /// What the person already has: liked songs first, then what they played.
    private var pool: [MusicTrack] { hub.library.liked + hub.library.history.map(\.track) }

    private func load() async {
        let client = SetlistFMClient()
        guard client.isAvailable else { concerts = []; return }
        let ids = (try? await MusicEntityRuntime.shared.store.graph.externalIDs(of: person)) ?? []
        guard let mbid = ids.first(where: { $0.scheme == .mbid })?.value else { concerts = []; return }
        do { concerts = try await client.recentConcerts(mbid: mbid) }
        catch { MusicDebugLog.log("concerts", "setlist.fm unavailable") ; concerts = [] }
    }
}
