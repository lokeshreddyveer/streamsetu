import Foundation

/// Sports events found in the guide of the person's own playlists. Nothing here is stored: events are derived from channels and programmes, never written back to them, and can always be
/// rebuilt. No outside sports service is used to decide what an event is.

enum Sport: String, CaseIterable, Codable, Sendable, Hashable {
    case football, cricket, basketball, americanFootball, baseball, iceHockey, tennis, motorsport, golf, boxing, mma, rugby

    var title: String {
        switch self {
        case .football: "Football"; case .cricket: "Cricket"; case .basketball: "Basketball"; case .americanFootball: "American Football"; case .baseball: "Baseball"
        case .iceHockey: "Ice Hockey"; case .tennis: "Tennis"; case .motorsport: "Motorsport"; case .golf: "Golf"; case .boxing: "Boxing"; case .mma: "MMA"; case .rugby: "Rugby"
        }
    }
}

enum SportsEventState: String, Codable, Sendable { case upcoming, live, finished }

/// What shape of event it is. Not every event has two sides.
enum SportsEventKind: String, Codable, Sendable {
    /// Two sides: a match, a game, a bout.
    case headToHead
    /// A motorsport session: a race, qualifying, a practice or a sprint of a named Grand Prix or round.
    case raceSession
    /// A round, day or final of a named tournament (golf, tennis).
    case tournamentRound
    /// A named fight card or one of its parts (UFC 300 main card, prelims).
    case fightCard
    /// Any other event, accepted only when the competition is known and the listing names a specific final, match number or round.
    case generic
}

/// Where a piece of feed information came from. A language or quality read out of a channel name is a hint, never presented as something the provider said.
enum MetadataSource: String, Codable, Sendable { case provider, parsedFromName, unknown }

/// Why a channel is kept out of every result.
enum SportsRestriction: String, Codable, Sendable { case hiddenChannel, lockedFolder }

/// One channel carrying an event. A channel that is hidden or in a locked folder never becomes a feed: it is removed before any event is built.
struct SportsFeed: Hashable, Sendable, Identifiable {
    var id: String { channelID }
    let channelID: String
    let sourceID: UUID
    let channelName: String
    /// A lower-case language code ("en", "hi", "te"); nil when neither the playlist nor the title says one. See `languageSource`.
    let language: String?
    let languageSource: MetadataSource
    /// "4K", "FHD", "HD" or "SD"; nil when unknown. See `qualitySource`.
    let quality: String?
    let qualitySource: MetadataSource
    /// "home", "away", "alt" or "clean" for a feed that is a particular commentary or camera (always a hint read from the title).
    let variant: String?
    let guideProgrammeID: Int64
    /// The provider keeps this channel's past programmes.
    let catchUp: Bool
    /// The channel's own logo address, for showing a card; never shown as text.
    var logoURL: String? = nil
}

struct SportsEvent: Identifiable, Hashable, Sendable {
    /// Stable: the same event keeps its id when a feed appears or disappears, a start time is corrected by a few minutes, or a playlist is refreshed. It comes from the normalized event identity, the UTC
    /// day of the event and its place among that identity's occurrences that day (so the same two sides playing twice on one day get two ids). It can only change if an event sitting on UTC
    /// midnight has its time corrected across that line. It is for list keys, focus and cache identity only: never the permanent identity of a reminder, recording or synced record, which need their own
    /// durable record re-associated by normalized identity and a time tolerance (see docs/SPORTS.md).
    let id: String
    let sport: Sport
    let kind: SportsEventKind
    let competition: String?
    /// The sides in the order the title gives them (for "A @ B", the home side first). Empty for an event with no sides.
    let participants: [String]
    /// The part of a longer event: "race", "qualifying", "practice 2", "round 3", "final", "main card".
    let stage: String?
    let title: String
    let start: Date
    let end: Date
    var feeds: [SportsFeed]
    /// 0 to 1: how sure the rules are that this is a real event of this sport.
    let confidence: Double
    /// The playlists whose channels carry it.
    let sourceIDs: Set<UUID>
    /// Made from the guide revision of every playlist that carries the event, and only those, so another playlist's update does not change it.
    let guideRevision: String

    func state(at now: Date) -> SportsEventState { now < start ? .upcoming : (now < end ? .live : .finished) }
}
