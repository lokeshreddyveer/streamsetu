import SwiftUI

/// A Music cover. The designed tile (a gradient in a stable hue per name) is under the picture from the first frame, so nothing flashes empty and a loading
/// cover and a missing one look alike. A cover already in memory is drawn on the first frame with no animation; one that really arrives from the network
/// fades in briefly (not with Reduce Motion). It cancels its request when it scrolls away.
/// With a `size` it is a square of that many points; without one it fills whatever frame it is given (cards, backdrops). Pass `artworkClass` to
/// request the bucket that class needs instead of a raw `pixelHint`.
///
/// Right-sized and retried: the address is rewritten to the size the slot draws where the host supports it (`MusicArtworkSlot`), a failed sized request
/// falls back to the original address once, and only then does the designed tile stay.
///
/// Pass a `subject` and a cover with no usable picture (none given, or the given one would not load) asks `MusicEntityArtwork` for the best verified one:
/// a person's photo, a film's poster or a song's album cover. Nothing is asked until the cover is on screen.
struct MusicCoverImage: View {
    let thumbs: [MusicThumbnail]
    var size: CGFloat?
    var corner: CGFloat
    var pixelHint: Int
    var artworkClass: MusicArtworkClass?
    /// Text that picks the fallback colour instead of the address, so several items that share one cover still look different when it is missing.
    var seed: String?
    /// Letters drawn on the fallback instead of the note (an artist without a usable portrait).
    var initials: String?
    /// What this cover stands for, so a missing picture can be found (and the tile can wear the right glyph).
    var subject: MusicArtworkSubject?
    /// Where it is drawn, for the size to request; by default taken from `size` or `artworkClass`.
    var slot: MusicArtworkSlot?
    /// Which part of a picture that is taller or wider than the frame stays in view: the top for a portrait photo (faces sit high), the centre otherwise.
    var focus: Alignment = .center
    @Environment(\.displayScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loaded: MusicDecodedImage?
    @State private var loadedFor: String?
    @State private var failedFor: String?
    @State private var resolvedFor: String?
    @State private var resolvedAddress: String?
    @State private var thumbBroken: String?
    /// A page cover that arrived only as a small thumbnail asks the resolver once for a better picture of the same thing.
    @State private var upgradedFor: String?
    @State private var upgradedAddress: String?

    // Private so this file does not depend on the shared token files; reconcile with the motion tokens later.
    private static let arrivalFade = 0.18

    init(thumbs: [MusicThumbnail], size: CGFloat? = nil, corner: CGFloat = 8, pixelHint: Int = 512) {
        self.thumbs = thumbs; self.size = size; self.corner = corner; self.pixelHint = pixelHint
    }

    init(thumbs: [MusicThumbnail], artworkClass: MusicArtworkClass, size: CGFloat? = nil, corner: CGFloat = 8) {
        self.thumbs = thumbs; self.size = size; self.corner = corner; self.pixelHint = artworkClass.requestPoints * 2; self.artworkClass = artworkClass
    }

    private var needed: Int {
        if let size { return Int((size * max(scale, 1)).rounded(.up)) }
        // A page picture names its slot (hero, poster, viewer…): decode at what that place draws, not at the card default.
        if let slot { return slot.pixels(scale: scale) }
        if let artworkClass { return artworkClass.pixels(scale: scale) }
        return pixelHint
    }
    private var effectiveSlot: MusicArtworkSlot {
        if let slot { return slot }
        if let artworkClass { return artworkClass.slot }
        if let size { return .forPoints(size) }
        return .card
    }
    /// The addresses to try, best first: the sized one(s), then the original once.
    private func attempts(_ address: String) -> [String] { MusicArtworkURLSizing.attempts(for: address, ladder: effectiveSlot.ladder(scale: scale)) }

    private var thumbAddress: String? {
        let a = MusicArtworkService.pickThumbnail(thumbs, neededPixels: needed)
        return a != nil && a == thumbBroken ? nil : a
    }
    /// What the resolver found: kept in state once this cover has asked, else read from its memory so a cover seen before paints on the first frame.
    private var resolvedAddressNow: String? {
        guard let subject else { return nil }
        if resolvedFor == subject.key { return resolvedAddress }
        return MusicEntityArtwork.shared.cachedAddress(subject)
    }
    /// A picture the person chose for this thing wins over every other.
    private var chosenAddress: String? { subject.flatMap { MusicArtworkOverrides.shared.address(for: $0) } }
    private var upgradedNow: String? { subject.flatMap { upgradedFor == $0.key ? upgradedAddress : nil } }
    private var address: String? { chosenAddress ?? upgradedNow ?? thumbAddress ?? resolvedAddressNow }
    /// Only the pictures a page makes large are upgraded (a poster, a portrait, a hero, the viewer), never a row or a card.
    private var isPageSlot: Bool {
        switch slot { case .poster?, .filmHero?, .profile?, .viewer?: true; default: false }
    }
    /// The width the given thumbnail declares (0 when it says nothing).
    private var thumbWidth: Int { thumbs.first { $0.url == thumbAddress }?.width ?? 0 }
    private var wantsUpgrade: Bool {
        guard let subject, isPageSlot, upgradedFor != subject.key, chosenAddress == nil, thumbAddress != nil else { return false }
        return thumbWidth > 0 && thumbWidth * 4 < needed * 3
    }
    private var taskID: String { "\(address ?? "")|\(MusicArtworkBuckets.bucket(forPixels: needed))" }
    /// Identity for the placeholder tint: the seed, else the thing's name, else the first address, so every size of one cover shares a tint.
    private var identity: String { seed ?? subject?.name ?? thumbs.first?.url ?? address ?? "" }
    /// A cover with no address at all, or one that could not be fetched, shows the full designed tile (glyph and letters).
    private var showsFallback: Bool { address == nil || failedFor == taskID }

    private func cachedImage(_ address: String?) -> MusicDecodedImage? {
        guard let address else { return nil }
        for a in attempts(address) { if let hit = MusicArtworkService.shared.cachedImage(a, targetPixelSize: needed) { return hit } }
        return nil
    }

    /// Sized address, then the original once. Nil when every step failed.
    private func loadLadder(_ address: String) async -> MusicDecodedImage? {
        for a in attempts(address) {
            if let img = await MusicArtworkService.shared.load(a, targetPixelSize: needed) { return img }
            if Task.isCancelled { return nil }
        }
        return nil
    }

    var body: some View {
        let shown = loadedFor == taskID ? loaded : cachedImage(address)
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        backdrop
            .overlay(alignment: focus) {
                if let shown { Image(decorative: shown.cg, scale: 1).resizable().scaledToFill().transition(.opacity) }
            }
            .frame(width: size, height: size)
            .clipShape(shape)
            .task(id: taskID) { await run(taskID) }
    }

    private func run(_ want: String) async {
        // A small provider thumbnail drawn large: ask once for a better picture; a different answer changes the address, which runs this again.
        if wantsUpgrade, let subject {
            let found = await MusicEntityArtwork.shared.resolve(subject)
            guard !Task.isCancelled else { return }
            upgradedFor = subject.key
            if let a = found?.address, a != thumbAddress { upgradedAddress = a; return }
            upgradedAddress = nil
        }
        // Nothing usable yet: ask the artwork resolver once (lazy, shared by every cover of the same thing, cancelled when this one scrolls away).
        if address == nil, let subject, resolvedFor != subject.key {
            let found = await MusicEntityArtwork.shared.resolve(subject)
            guard !Task.isCancelled else { return }
            resolvedAddress = found?.address; resolvedFor = subject.key
            return   // a new address changes the task id, which runs this again to load it
        }
        let wasCached = cachedImage(address) != nil
        var img: MusicDecodedImage?
        if let address { img = await loadLadder(address) }
        guard !Task.isCancelled else { return }
        if img == nil, let failed = address, failed == upgradedAddress {
            upgradedAddress = nil   // the better picture would not load: the thumbnail that came with the page is still there to draw
            return
        }
        if img == nil, let failed = address {
            failedFor = want
            if let subject {
                if failed == thumbAddress {
                    thumbBroken = failed                       // the given picture is dead: ask the resolver for another
                    resolvedFor = nil; resolvedAddress = nil
                } else {
                    MusicEntityArtwork.shared.reportBroken(subject, address: failed)
                    resolvedFor = subject.key; resolvedAddress = nil
                }
                return
            }
            // A transient failure is not permanent: ask again once the short failure memory has passed.
            try? await Task.sleep(for: .seconds(MusicArtworkStore.failureTTL + 1))
            guard !Task.isCancelled else { return }
            img = await loadLadder(failed)
            guard !Task.isCancelled else { return }
        }
        if img != nil { failedFor = nil }
        if wasCached || reduceMotion || img == nil {
            loaded = img; loadedFor = want
        } else {
            withAnimation(.easeOut(duration: Self.arrivalFade)) { loaded = img; loadedFor = want }
        }
    }
}

extension MusicCoverImage {
    init(thumbs: [MusicThumbnail], artworkClass: MusicArtworkClass, size: CGFloat? = nil, corner: CGFloat = 8, seed: String?, initials: String? = nil,
         subject: MusicArtworkSubject? = nil, slot: MusicArtworkSlot? = nil) {
        self.init(thumbs: thumbs, artworkClass: artworkClass, size: size, corner: corner)
        self.seed = seed; self.initials = initials; self.subject = subject; self.slot = slot
    }

    /// A cover that can find its own picture (and says where it is drawn).
    func artwork(of subject: MusicArtworkSubject?, slot: MusicArtworkSlot? = nil) -> MusicCoverImage {
        var copy = self
        copy.subject = subject
        if let slot { copy.slot = slot }
        return copy
    }

    /// The designed tile is always under the picture: the full one (glyph, letters) when the cover is missing or failed, the plain gradient while it loads.
    @ViewBuilder fileprivate var backdrop: some View {
        if showsFallback {
            MusicCoverFallback(seed: identity, initials: initials ?? subject?.monogram, kind: subject?.kind)
        } else {
            MusicTokens.coverGradient(hue: MusicCoverTint.hue(for: identity))
        }
    }
}

/// The designed look of a missing or failed cover: a two-hue gradient with a soft highlight and a darker foot (in a stable hue per seed, a different
/// highlight corner per seed so neighbours never look alike), a large quiet glyph for the kind of thing it is, and letters for a person or a language.
/// Decorative: the name is always shown next to it, so it is hidden from VoiceOver.
struct MusicCoverFallback: View {
    let seed: String
    var initials: String?
    var kind: MusicEntityKind?

    var body: some View {
        MusicTokens.coverBackdrop(hue: MusicCoverTint.hue(for: seed), corner: Int(MusicCoverTint.hash(seed) % 4))
            .overlay {
                GeometryReader { g in
                    let side = min(g.size.width, g.size.height)
                    ZStack {
                        if let glyph = MusicCoverGlyph.systemName(for: kind), side >= 28 {
                            Image(systemName: glyph).font(MusicTokens.coverGlyphFont(side: side)).foregroundStyle(MusicInk.onArtworkFaint)
                                .offset(x: initials?.isEmpty == false ? side * 0.22 : 0, y: initials?.isEmpty == false ? -side * 0.18 : 0)
                        }
                        if let initials, !initials.isEmpty {
                            Text(verbatim: initials).font(MusicTokens.coverMonogramFont(side: side))
                                .foregroundStyle(MusicInk.onArtwork).minimumScaleFactor(0.5).lineLimit(1)
                        } else if kind == nil {
                            MusicIcon(glyph: .note, size: side * 0.5, tint: .custom(MusicInk.onArtworkFaint))
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The glyph a missing cover wears, by what it is.
enum MusicCoverGlyph {
    static func systemName(for kind: MusicEntityKind?) -> String? {
        guard let kind else { return nil }
        switch kind {
        case .person: return "person.fill"
        case .group: return "person.2.fill"
        case .film, .series: return "film"
        case .album, .release: return "opticaldisc"
        case .recording, .track, .work: return "music.note"
        case .playlist: return "music.note.list"
        case .genre: return "guitars"
        case .language: return "character.bubble"
        case .region: return "globe.asia.australia"
        case .era: return "clock"
        case .station: return "dot.radiowaves.left.and.right"
        }
    }
}

/// Stable per-address placeholder tint.
enum MusicCoverTint {
    /// FNV-1a, so the value is the same on every launch (Swift's Hasher is seeded per process).
    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// Hue in 0..<1 for an address; the empty address gets 0.
    static func hue(for address: String) -> Double { Double(hash(address) % 360) / 360 }

    static func fill(for address: String) -> some View {
        MusicTokens.coverWash(hue: hue(for: address), empty: address.isEmpty)
    }
}

extension View {
    /// Lifecycle hook for animated artwork (see `MusicMotionArtView`): `isActive` is true only while the view is on screen and the app is active,
    /// so a player or video layer can pause when scrolled away or backgrounded.
    func musicArtworkLifecycle(isActive: Binding<Bool>) -> some View { modifier(MusicArtworkLifecycle(isActive: isActive)) }
}

private struct MusicArtworkLifecycle: ViewModifier {
    @Binding var isActive: Bool
    @Environment(\.scenePhase) private var phase
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; isActive = phase == .active }
            .onDisappear { visible = false; isActive = false }
            .onChange(of: phase) { _, new in isActive = visible && new == .active }
    }
}
