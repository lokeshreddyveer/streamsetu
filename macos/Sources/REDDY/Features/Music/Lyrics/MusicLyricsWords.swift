import SwiftUI

// Drawing blocks of the animated lyrics: the wrapping layout, one sung word (sweep, lift), a held word that swells letter by letter,
// the interlude dots and the loading skeleton. Everything here is a pure function of the lyric time it is given; nothing keeps its own clock.

struct MusicLyricsLook: Equatable {
    var ink: Color = .white
    var fontSize: Double = 30
    var wide = false
    var glow = true
    var reduceMotion = false
    var rtl = false
    /// The person's alignment choice (`MusicLyricsAlignment`): automatic follows the duet side, or all lines start, centre or end.
    var align = MusicLyricsAlignment.automatic

    var font: Font { .system(size: fontSize, weight: .heavy, design: .default) }
    var subFont: Font { .system(size: fontSize * 20 / 34, weight: .bold) }
    var backFont: Font { .system(size: fontSize * 23 / 34, weight: .heavy) }
    var lineAdvance: Double { fontSize * 41 / 34 }

    var animation: Animation? {
        reduceMotion ? nil : .timingCurve(MusicLyricsMotion.bezier.x1, MusicLyricsMotion.bezier.y1, MusicLyricsMotion.bezier.x2, MusicLyricsMotion.bezier.y2, duration: MusicLyricsMotion.duration)
    }
}

/// Words flow left to right and wrap; trailing alignment right-aligns each wrapped row. Right-to-left lines mirror the placement.
struct MusicLyricsFlowLayout: Layout {
    var rowSpacing: CGFloat = 2
    var trailing = false
    var mirrored = false
    var centered = false

    struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var out: [Row] = [Row()]
        for (i, s) in subviews.enumerated() {
            let size = s.sizeThatFits(.unspecified)
            if let last = out.last, !last.items.isEmpty, last.width + size.width > maxWidth + 0.5 { out.append(Row()) }
            out[out.count - 1].items.append(i)
            out[out.count - 1].width += size.width
            out[out.count - 1].height = max(out[out.count - 1].height, size.height)
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        let r = rows(subviews, maxWidth: maxW.isFinite ? maxW : .greatestFiniteMagnitude)
        let w = r.map(\.width).max() ?? 0
        let h = r.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(0, r.count - 1))
        return CGSize(width: maxW.isFinite ? min(maxW, max(w, 0)) : w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = rows(subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in r {
            let flush = trailing != mirrored
            var x = flush ? bounds.maxX - row.width : bounds.minX
            if centered { x = bounds.minX + max(0, (bounds.width - row.width) / 2) }
            let order = mirrored ? Array(row.items.reversed()) : row.items
            if mirrored && !centered { x = trailing ? bounds.minX : bounds.maxX - row.width }
            for i in order {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width
            }
            y += row.height + rowSpacing
        }
    }
}

/// Dim copy underneath, bright copy on top clipped to the revealed part with a feathered leading edge.
struct MusicLyricsSweepText: View {
    let text: String
    let progress: Double
    let look: MusicLyricsLook
    var font: Font? = nil
    var dimAlpha = MusicLyricsMotion.unsungAlpha

    var body: some View {
        let f = font ?? look.font
        ZStack(alignment: .leading) {
            Text(verbatim: text).font(f).foregroundStyle(look.ink.opacity(dimAlpha))
            if progress >= 1 {
                Text(verbatim: text).font(f).foregroundStyle(look.ink)
            } else if progress > 0 {
                Text(verbatim: text).font(f).foregroundStyle(look.ink).mask(alignment: .leading) { edge(progress) }
            }
        }
        .fixedSize()
    }

    private func edge(_ p: Double) -> some View {
        GeometryReader { g in
            let feather = min(1, MusicLyricsMotion.featherPoints / max(1, g.size.width))
            let e = p * (1 + feather)
            let solid = min(1, max(0, e - feather)), clear = min(1, max(solid, e))
            LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: solid), .init(color: .clear, location: clear)],
                           startPoint: look.rtl ? .trailing : .leading, endPoint: look.rtl ? .leading : .trailing)
        }
    }
}

/// One sung word: sweep plus a small lift that rises over the word and settles after it.
struct MusicLyricsWordView: View {
    let word: MusicLyricWord
    let ms: Int64
    let look: MusicLyricsLook
    var lifted = true

    var body: some View {
        let hold = Double(word.endMs - word.startMs)
        if !look.reduceMotion, MusicLyricsMotion.qualifiesForSwell(text: word.text, holdMs: hold), ms >= word.startMs - 50 {
            MusicLyricsSwellWord(word: word, ms: ms, look: look)
        } else {
            let lift = lifted && !look.reduceMotion ? MusicLyricsMotion.lift(word, at: ms) * MusicLyricsMotion.liftPoints : 0
            MusicLyricsSweepText(text: word.text, progress: MusicLyricsMotion.wordProgress(word, at: ms), look: look).offset(y: -lift)
        }
    }
}

/// A short held word drawn letter by letter: each letter swells, leans away from the word centre and glows while it is held.
struct MusicLyricsSwellWord: View {
    let word: MusicLyricWord
    let ms: Int64
    let look: MusicLyricsLook

    var body: some View {
        let body = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(word.text.dropFirst(word.text.prefix(while: { !$0.isWhitespace }).count))
        let letters = Array(body)
        let hold = Double(max(1, word.endMs - word.startMs))
        let peaks = MusicLyricsMotion.letterPeaks(length: letters.count, holdMs: hold)
        let p = MusicLyricsMotion.wordProgress(word, at: ms)
        let baseLift = MusicLyricsMotion.lift(word, at: ms)
        HStack(spacing: 0) {
            ForEach(letters.indices, id: \.self) { i in
                let move = MusicLyricsMotion.letterMove(wordStartMs: word.startMs, index: i, holdMs: hold, at: ms)
                let cover = min(1, max(0, p * Double(letters.count) - Double(i)))
                let pk = peaks[i]
                let ch = String(letters[i])
                Text(verbatim: ch).font(look.font)
                    .foregroundStyle(look.ink.opacity(MusicLyricsMotion.unsungAlpha + (1 - MusicLyricsMotion.unsungAlpha) * cover))
                    .background {
                        if look.glow, move > 0.01 {
                            Text(verbatim: ch).font(look.font).foregroundStyle(look.ink).blur(radius: 6).opacity(min(1, pk.bloom) * 0.62 * move)
                        }
                    }
                    .scaleEffect(1 + (pk.scale - 1) * move)
                    .offset(x: pk.shiftEm * look.fontSize * move, y: -MusicLyricsMotion.liftPoints * (baseLift + pk.rise * move))
            }
            if !tail.isEmpty { Text(verbatim: tail).font(look.font).foregroundStyle(.clear) }
        }
        .fixedSize()
    }
}

/// The three-dot break. Each dot owns a third of the break and fills left to right.
struct MusicLyricsInterludeDots: View {
    let progress: Double
    let ink: Color
    var body: some View {
        let fills = MusicLyricsMotion.dotFills(progress: progress)
        HStack(spacing: MusicLyricsMotion.interludeGap) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(ink).frame(width: MusicLyricsMotion.interludeDot, height: MusicLyricsMotion.interludeDot).opacity(fills[i])
            }
        }
        .scaleEffect(0.76 + 0.24 * progress, anchor: .leading)
        .frame(height: 40, alignment: .leading)
        .accessibilityElement().accessibilityLabel("Instrumental")
    }
}

/// Placeholder bars while lyrics load. The shimmer runs only while this is on screen, which is only while loading.
struct MusicLyricsSkeleton: View {
    static let blocks: [[Double]] = [[0.97, 0.54], [0.92, 0.99, 0.41], [0.68], [0.95, 0.73], [0.89, 0.96, 0.37]]
    let ink: Color
    var body: some View {
        MusicFrameClock(minimumInterval: 1.0 / 20) { ctx in
            let phase = (ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4)) / 1.4
            GeometryReader { g in
                VStack(alignment: .leading, spacing: 35) {
                    ForEach(Self.blocks.indices, id: \.self) { b in
                        VStack(alignment: .leading, spacing: 15) {
                            ForEach(Self.blocks[b].indices, id: \.self) { r in
                                RoundedRectangle(cornerRadius: 4).fill(ink.opacity(0.10)).frame(width: g.size.width * Self.blocks[b][r], height: 26)
                            }
                        }
                    }
                }
                .padding(.top, 40)
                .overlay {
                    LinearGradient(colors: [.clear, ink.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.45)
                        .offset(x: (phase * 1.45 - 0.45) * g.size.width - g.size.width * 0.275)
                        .blendMode(.plusLighter).allowsHitTesting(false)
                }
                .clipped()
            }
        }
        .accessibilityLabel("Loading lyrics")
    }
}

enum MusicLyricsDirection {
    /// A line reads right to left when it holds more strongly right-to-left letters than left-to-right ones.
    static func isRTL(_ text: String) -> Bool {
        var rtl = 0, ltr = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: rtl += 1
            default: if u.properties.isAlphabetic { ltr += 1 }
            }
        }
        return rtl > ltr
    }
}
