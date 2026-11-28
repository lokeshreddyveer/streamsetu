import SwiftUI

/// What the header's capsules offer. An action appears only when it can do something right now.
enum MusicHomeQuickAction: String, CaseIterable, Sendable {
    case playRecent, shuffleLiked, startRadio, openLibrary

    /// `paused` is a locked profile: nothing can start playing, so only Open Library is offered.
    nonisolated static func available(hasRecent: Bool, hasLiked: Bool, canRadio: Bool, paused: Bool = false) -> [MusicHomeQuickAction] {
        var out: [MusicHomeQuickAction] = []
        if paused { return [.openLibrary] }
        if hasRecent { out.append(.playRecent) }
        if hasLiked { out.append(.shuffleLiked) }
        if canRadio { out.append(.startRadio) }
        out.append(.openLibrary)
        return out
    }
}

enum MusicHomeGreeting {
    /// The greeting's English text for an hour of the day (0 to 23); the page passes it through `Localized.string`.
    static func text(hour: Int) -> String {
        switch hour {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Good night"
        }
    }
}

/// The top of Listen Now: the greeting with the glass Refresh button beside it, and the quick actions as capsules.
struct MusicHomeHeader: View {
    let hub: MusicHub
    let refreshing: Bool
    let onRefresh: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The same plays Continue listening uses: a reset of recommendations starts "Play recent" fresh too, and a podcast episode or a skipped second is not a recent song.
        let now = Date()
        var seenRecent = Set<String>()
        let recent = MusicTasteReset.visible(hub.library.history).filter { HomeTaste.shapesTaste($0, now: now) && !hub.library.isBlacklisted($0.track) && seenRecent.insert($0.track.uid).inserted }.prefix(MusicLibrary.recentLimit).map(\.track)
        let liked = hub.library.liked.filter { !hub.library.isBlacklisted($0) }
        let current = hub.player.current
        let canRadio = current.map { hub.registry.provider(id: $0.providerID) is any MusicMetadataProvider } ?? false
        let actions = MusicHomeQuickAction.available(hasRecent: !recent.isEmpty, hasLiked: !liked.isEmpty, canRadio: canRadio, paused: hub.gated)
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            HStack(alignment: .center, spacing: MusicSpace.sm) {
                Text(verbatim: Localized.string(MusicHomeGreeting.text(hour: Calendar.current.component(.hour, from: Date()))))
                    .musicText(.section).foregroundStyle(ColorTokens.textSecondary).accessibilityAddTraits(.isHeader)
                Button(action: onRefresh) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .rotationEffect(.degrees(refreshing && !reduceMotion ? 180 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: refreshing)
                }
                .musicButton(.glassIcon)
                .disabled(refreshing)
                .accessibilityLabel(Localized.string("Refresh Listen Now")).musicTooltip(verbatim: Localized.string("Shuffle the page"))
                .atlas("control.music.homeRefresh")
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal) {
                HStack(spacing: MusicSpace.xs) {
                    ForEach(actions, id: \.self) { action in
                        Button { run(action, recent: recent, liked: liked, current: current) } label: { Label(title(action), systemImage: symbol(action)) }
                            .musicButton(.secondary)
                            .accessibilityLabel(title(action))
                            .atlasCovers("control.music.homePlayRecent").atlas(atlasID(action))
                    }
                }
                .padding(.vertical, MusicSpace.xxs)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func title(_ a: MusicHomeQuickAction) -> String {
        switch a {
        case .playRecent: Localized.string("Play recent")
        case .shuffleLiked: Localized.string("Shuffle liked")
        case .startRadio: Localized.string("Start radio")
        case .openLibrary: Localized.string("Open Library")
        }
    }

    private func symbol(_ a: MusicHomeQuickAction) -> String {
        switch a {
        case .playRecent: "play.fill"
        case .shuffleLiked: "shuffle"
        case .startRadio: "dot.radiowaves.left.and.right"
        case .openLibrary: "books.vertical"
        }
    }

    private func atlasID(_ a: MusicHomeQuickAction) -> String {
        switch a {
        case .playRecent: "control.music.homePlayRecent"
        case .shuffleLiked: "control.music.homeShuffleLiked"
        case .startRadio: "control.music.homeStartRadio"
        case .openLibrary: "control.music.homeOpenLibrary"
        }
    }

    private func run(_ a: MusicHomeQuickAction, recent: [MusicTrack], liked: [MusicTrack], current: MusicTrack?) {
        MusicDebugLog.log("home", "quick action: \(a.rawValue)")
        switch a {
        case .playRecent: hub.play(recent, at: 0)
        case .shuffleLiked: hub.playShuffled(liked, sourceName: Localized.string("Liked songs"))
        case .startRadio:
            guard let current else { return }
            Task { await MusicQueueActions.startRadio(current, hub: hub) }
        case .openLibrary: hub.openLibrary()
        }
    }
}

/// The new listener's welcome: one line of what Listen Now becomes, and three clear first steps as capsules.
struct MusicHomeWelcomeCard: View {
    let hub: MusicHub
    let onImport: () -> Void
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Image(systemName: "sparkles").font(MusicTokens.iconLarge).foregroundStyle(accent).accessibilityHidden(true)
            Text(verbatim: Localized.string("Start with music you will like")).musicText(.section).accessibilityAddTraits(.isHeader)
            Text(verbatim: Localized.string("Play a few songs and this page turns into yours: mixes, new releases from artists you play, and a front page that changes every visit."))
                .musicText(.body).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal) {
                HStack(spacing: MusicSpace.xs) {
                    Button { MusicDebugLog.log("home", "welcome: explore charts"); hub.nav.select(.explore) } label: { Label(Localized.string("Explore charts"), systemImage: "chart.bar") }
                        .musicButton(.primary).atlas("control.music.homeWelcomeExplore")
                    Button { MusicDebugLog.log("home", "welcome: open radio"); hub.nav.select(.radio) } label: { Label(Localized.string("Open Radio"), systemImage: "dot.radiowaves.left.and.right") }
                        .musicButton(.secondary).atlas("control.music.homeWelcomeRadio")
                    Button { MusicDebugLog.log("home", "welcome: import or open a link"); onImport() } label: { Label(Localized.string("Import or open a link"), systemImage: "link") }
                        .musicButton(.secondary).atlas("control.music.homeWelcomeImport")
                }
                .padding(.vertical, MusicSpace.xxs)
            }
            .scrollIndicators(.hidden)
        }
        .padding(MusicSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorTokens.card, in: RoundedRectangle(cornerRadius: MusicCorner.panel, style: .continuous))
        .musicElevation(.edge, cornerRadius: MusicCorner.panel)
        .accessibilityElement(children: .contain)
    }
}

/// "Explore more": capsule links into Explore, Radio and Library, at the foot of the page.
struct MusicHomeExploreMore: View {
    let hub: MusicHub
    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSectionTitle(title: Localized.string("Explore more"))
            ScrollView(.horizontal) {
                HStack(spacing: MusicSpace.xs) {
                    link(Localized.string("Explore"), "safari", .explore, "control.music.homeMoreExplore")
                    link(Localized.string("Radio"), "dot.radiowaves.left.and.right", .radio, "control.music.homeMoreRadio")
                    link(Localized.string("Your Library"), "books.vertical", .library, "control.music.homeMoreLibrary")
                }
                .padding(.vertical, MusicSpace.xxs)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func link(_ title: String, _ symbol: String, _ section: MusicSection, _ atlas: String) -> some View {
        Button { MusicDebugLog.log("home", "explore more: \(section.rawValue)"); hub.nav.select(section) } label: { Label(title, systemImage: symbol) }
            .musicButton(.secondary).atlas(atlas)
    }
}
