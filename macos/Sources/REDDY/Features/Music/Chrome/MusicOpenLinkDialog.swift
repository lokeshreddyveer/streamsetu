import SwiftUI

/// What a pasted link points at. Opening one only shows a page; nothing here starts playback.
enum MusicLink: Equatable, Sendable {
    /// A link the app already understands: its own, or a Spotify address.
    case known(MusicLinkTarget)
    case youTubeTrack(id: String, startSeconds: Int?)
    case youTubePlaylist(id: String)
    case youTubeAlbum(id: String)
    case youTubeArtist(id: String)
}

enum MusicLinkParser {
    /// Parses text from the open-link box, a launch argument or an open-URL event. Nil when it is not a music link.
    static func parse(_ raw: String) -> MusicLink? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 400 else { return nil }
        // A Spotify address wins over everything else.
        // YouTube addresses are read below, so a start offset and the exact kind of page are kept.
        if let t = MusicDeepLinks.parse(text: text), t.providerID != YTM.providerID { return .known(t) }
        guard let url = webURL(text) else { return nil }
        if let t = MusicDeepLinks.parse(url), t.providerID != YTM.providerID { return .known(t) }
        guard let host = url.host?.lowercased() else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        let start = (value("t") ?? value("start")).flatMap(startOffset)
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        if host == "youtu.be" {
            guard let id = parts.first, MusicDeepLinks.isValidItemID(id) else { return nil }
            return .youTubeTrack(id: id, startSeconds: start)
        }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        // The track is what was shared, even when a list parameter rides along.
        if let v = value("v"), MusicDeepLinks.isValidItemID(v) { return .youTubeTrack(id: v, startSeconds: start) }
        if parts.first == "watch" || parts.isEmpty || parts.first == "playlist", let list = value("list"), MusicDeepLinks.isValidItemID(stripVL(list)) {
            return .youTubePlaylist(id: stripVL(list))
        }
        if parts.count >= 2, parts[0] == "channel", MusicDeepLinks.isValidItemID(parts[1]) { return .youTubeArtist(id: parts[1]) }
        if parts.count >= 2, parts[0] == "browse", MusicDeepLinks.isValidItemID(parts[1]) {
            let id = parts[1]
            if id.hasPrefix("MPRE") { return .youTubeAlbum(id: id) }
            if id.hasPrefix("VL") { return .youTubePlaylist(id: stripVL(id)) }
            if id.hasPrefix("UC") { return .youTubeArtist(id: id) }
        }
        return nil
    }

    static func stripVL(_ id: String) -> String { id.hasPrefix("VL") ? String(id.dropFirst(2)) : id }

    /// A bare host without a scheme is accepted.
    private static func webURL(_ text: String) -> URL? {
        if text.contains("://") { return URL(string: text) }
        guard !text.contains(" "), text.contains(".") else { return nil }
        return URL(string: "https://" + text)
    }

    /// "90", "1m30s", "1h2m3s" become seconds; zero or unparsable gives nil.
    static func startOffset(_ s: String) -> Int? {
        let t = s.lowercased().trimmingCharacters(in: .whitespaces)
        if let n = Int(t) { return n > 0 ? n : nil }
        var total = 0, number = ""
        for ch in t {
            if ch.isNumber { number.append(ch); continue }
            guard let n = Int(number) else { return nil }
            switch ch { case "h": total += n * 3600; case "m": total += n * 60; case "s": total += n; default: return nil }
            number = ""
        }
        guard number.isEmpty else { return nil }
        return total > 0 ? total : nil
    }

    /// The page target for a parsed link on the YouTube Music source, or nil for links needing no lookup.
    static func target(for link: MusicLink) -> MusicLinkTarget? {
        switch link {
        case .known(let t): t
        case .youTubeTrack(let id, _): MusicLinkTarget(kind: .track, providerID: YTM.providerID, id: id)
        case .youTubePlaylist(let id): MusicLinkTarget(kind: .playlist, providerID: YTM.providerID, id: id)
        case .youTubeAlbum(let id): MusicLinkTarget(kind: .album, providerID: YTM.providerID, id: id)
        case .youTubeArtist(let id): MusicLinkTarget(kind: .artist, providerID: YTM.providerID, id: id)
        }
    }

    /// The first argument that parses wins; flags, process-serial arguments and a leading word such as "open" are skipped.
    static func firstLink(inArguments args: [String]) -> MusicLink? {
        let spotifyFirst = args.compactMap { a -> MusicLink? in
            if a.hasPrefix("-") { return nil }
            guard let l = parse(a) else { return nil }
            if case .known = l { return l }
            return nil
        }.first
        if let spotifyFirst { return spotifyFirst }
        return args.lazy.filter { !$0.hasPrefix("-") }.compactMap(parse).first
    }
}

/// The open-link box. A good link closes it and opens the page; anything else leaves it open with a short message.
struct MusicOpenLinkDialog: View {
    let hub: MusicHub
    @Binding var isPresented: Bool
    @State private var text = ""
    @State private var message: String?
    @FocusState private var focused: Bool

    private var blank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Open a link").font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
            Text("Paste a link to a song, album, artist or playlist. It opens its page and never starts playing.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            TextField("music.youtube.com or open.spotify.com link", text: $text)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit(submit)
                .accessibilityLabel("Link to open")
            if let message { Text(verbatim: message).font(Typography.caption).foregroundStyle(ColorTokens.danger).accessibilityLabel(message) }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.musicButton(.secondary).keyboardShortcut(.cancelAction).atlas("control.music.openALinkCancel")
                Button("Open", action: submit).musicButton(.primary).keyboardShortcut(.defaultAction).disabled(blank).atlas("control.music.openALinkOpen")
            }
        }
        .padding(Spacing.xl).frame(width: MusicTokens.sheetWidth)
        .onAppear { text = ""; message = nil; focused = true }
    }

    private func submit() {
        guard !blank else { return }
        guard let link = MusicLinkParser.parse(text), let target = MusicLinkParser.target(for: link) else {
            message = Localized.string("That is not a recognised link.")
            MusicToasts.shared.error("That is not a recognised link.")
            return
        }
        isPresented = false
        Task { await hub.openLink(target) }
    }
}
