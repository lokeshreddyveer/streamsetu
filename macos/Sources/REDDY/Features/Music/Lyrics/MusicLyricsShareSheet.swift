import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Sharing picked lines as a picture card or as text. The card is 1080 wide and at most 1920 tall; the 250-character budget and the row
// building are decided by `MusicLyricsShareCard` (service side); this file draws it and hands over the image.

struct MusicLyricsCardView: View {
    let card: MusicLyricsShareCard
    let artwork: CGImage?
    let story: Bool
    private typealias M = MusicLyricsShareCard.Measure

    var body: some View {
        let width = M.width
        let height = story ? min(M.storyMaxHeight, MusicLyricsShareCard.cardHeight(rowCount: card.rows.count)) : MusicLyricsShareCard.cardHeight(rowCount: card.rows.count)
        let size = min(48.0, max(26.0, (height - 2 * M.margin - M.artwork) / Double(max(1, card.rows.count)) / (M.lineAdvanceRatio * 2)))
        ZStack {
            LinearGradient(colors: [Color(white: 0.13), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 24) {
                    if let artwork {
                        Image(decorative: artwork, scale: 1).resizable().scaledToFill().frame(width: story ? M.storyArtwork : M.artwork, height: story ? M.storyArtwork : M.artwork)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: card.title).font(.system(size: 34, weight: .bold)).lineLimit(2)
                        Text(verbatim: card.artist).font(.system(size: 28)).opacity(0.7).lineLimit(1)
                    }
                    Spacer()
                }
                Spacer(minLength: 30)
                VStack(alignment: .leading, spacing: size * 0.5) {
                    ForEach(card.rows.indices, id: \.self) { i in
                        let r = card.rows[i]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: r.isEllipsis ? "..." : r.text).font(.system(size: size * 1.6, weight: .heavy)).tracking(size * 1.6 * M.trackingRatio)
                                .frame(maxWidth: .infinity, alignment: r.isEllipsis ? .center : .leading)
                            if let s = r.sub { Text(verbatim: s).font(.system(size: size * 1.6 * M.subRatio, weight: .bold)).opacity(0.85) }
                        }
                    }
                }
                Spacer(minLength: 30)
                if card.showLogo { Text(verbatim: Localized.string("StreamSetu")).font(.system(size: 26, weight: .semibold)).opacity(0.55) }
            }
            .foregroundStyle(.white)
            .padding(story ? M.storyPadding : M.margin)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: story ? M.storyRadius : 0))
    }
}

struct MusicLyricsShareSheet: View {
    let track: MusicTrack
    let lines: [MusicLyricLine]
    let picked: [Int]
    let subLines: MusicLyricsSubLines?
    let onClose: () -> Void

    @State private var story = false
    @State private var showLogo = true
    @State private var artwork: CGImage?
    @State private var rendered: Image?
    @State private var copied = false
    @Environment(\.displayScale) private var displayScale

    private var card: MusicLyricsShareCard? {
        MusicLyricsShareCard.build(lines: lines, picked: Set(picked), title: track.title, artist: track.artistLine, subLines: subLines, showLogo: showLogo)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: Localized.string("Share lyrics")).font(Typography.heading)
            if let card {
                MusicLyricsCardView(card: card, artwork: artwork, story: story)
                    .scaleEffect(300 / MusicLyricsShareCard.Measure.width, anchor: .topLeading)
                    .frame(width: 300, height: 300 / MusicLyricsShareCard.Measure.width * MusicLyricsShareCard.cardHeight(rowCount: card.rows.count))
                    .accessibilityLabel("Preview of the lyrics card")
                Text(verbatim: "\(card.characterCount) of \(MusicLyricsShareCard.characterBudget) characters").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                Toggle("Story layout", isOn: $story).accessibilityLabel("Use the story layout").atlas("control.music.lyricsUseTheStoryLayout")
                Toggle("Show the app name", isOn: $showLogo).accessibilityLabel("Show the app name on the card").atlas("control.music.lyricsShowTheAppNameOnThe")
                HStack {
                    if let rendered {
                        ShareLink(item: rendered, preview: SharePreview("\(track.title) lyrics", image: rendered)) { Label("Share image", systemImage: "square.and.arrow.up") }
                    }
                    Button { copy(Self.plainText(card)); copied = true } label: { Label(Localized.string(copied ? "Copied" : "Copy text"), systemImage: "doc.on.doc") }
                        .accessibilityLabel("Copy the lyrics as text").atlas("control.music.lyricsCopyTheLyricsAsText")
                    Spacer()
                    Button("Done", action: onClose).musicButton(.secondary).atlas("control.music.lyricsDone")
                }
            } else {
                Text(verbatim: Localized.string("Nothing is picked.")).font(Typography.body)
                Button("Done", action: onClose).musicButton(.secondary).atlas("control.music.lyricsDone")
            }
        }
        .padding(18).frame(width: 360)
        .task(id: track.uid) { await loadArtwork() }
        .task(id: RenderKey(story: story, logo: showLogo, picked: picked, hasArt: artwork != nil)) { await render() }
    }

    private struct RenderKey: Hashable { var story: Bool; var logo: Bool; var picked: [Int]; var hasArt: Bool }

    static func plainText(_ card: MusicLyricsShareCard) -> String {
        let body = card.rows.map { $0.isEllipsis ? "..." : $0.text }.joined(separator: "\n")
        return "\(body)\n\n\(card.title) - \(card.artist)"
    }

    private func loadArtwork() async {
        guard let url = track.thumbnails.best(minSide: 300), let img = await MusicArtworkService.shared.load(url, targetPixelSize: 320) else { return }
        artwork = img.cg
    }

    private func render() async {
        guard let card else { rendered = nil; return }
        let r = ImageRenderer(content: MusicLyricsCardView(card: card, artwork: artwork, story: story))
        r.scale = 1
        #if os(macOS)
        if let ns = r.nsImage { rendered = Image(nsImage: ns) }
        #else
        if let ui = r.uiImage { rendered = Image(uiImage: ui) }
        #endif
    }

    private func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
}
