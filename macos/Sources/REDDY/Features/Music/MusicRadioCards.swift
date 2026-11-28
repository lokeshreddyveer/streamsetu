import SwiftUI

// What makes a station look like a station and not an album: a square cover with radio waves spreading from one corner, a label that names the kind
// of radio, and a play disc that is always there. Stations of the same kind share a cover with Explore (genres, languages) or use a real song or artist picture.

/// Concentric arcs spreading from the top-right corner of its frame.
struct MusicRadioWaves: Shape {
    var rings = 3
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let centre = CGPoint(x: rect.maxX, y: rect.minY)
        let step = rect.width * 0.2
        for i in 1...max(rings, 1) {
            p.addArc(center: centre, radius: step * CGFloat(i) + step * 0.5, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        return p
    }
}

/// The cover of a station: the genre or language cover, or the song's or artist's picture, with the wave overlay and the kind label.
struct MusicStationArt: View {
    let station: MusicStation
    var showsBadge = true
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        ZStack {
            cover
            LinearGradient(colors: [MusicInk.clear, MusicInk.scrim(.medium)], startPoint: .center, endPoint: .bottom)
            MusicRadioWaves().stroke(MusicInk.onArtworkTertiary, style: StrokeStyle(lineWidth: 2, lineCap: .round)).allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) { if showsBadge { badge.padding(MusicSpace.xs) } }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var cover: some View {
        if station.thumbs.isEmpty, let c = station.category {
            MusicCategoryArt(category: c)
        } else if station.thumbs.isEmpty {
            MusicCoverFallback(seed: station.id, kind: .station)
        } else {
            MusicCoverImage(thumbs: station.thumbs, artworkClass: .tile, corner: 0, seed: station.id)
        }
    }

    private var badge: some View {
        HStack(spacing: MusicSpace.xxs) {
            MusicIcon(glyph: .radio, size: 12, tint: .custom(MusicInk.onArtwork))
            Text(verbatim: station.badge).musicText(.micro).lineLimit(1)
        }
        .foregroundStyle(MusicInk.onArtwork)
        .padding(.horizontal, MusicSpace.xs).padding(.vertical, MusicSpace.xxs)
        .background(MusicInk.scrim(.strong), in: Capsule())
    }
}

