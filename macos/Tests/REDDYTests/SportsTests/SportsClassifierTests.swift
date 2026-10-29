import Testing
import Foundation
@testable import REDDY

@Suite("Sports classifier") struct SportsClassifierTests {
    private func c(_ title: String, sub: String? = nil, cat: String? = nil, channel: String = "Sports 1", channelCat: String? = nil, lang: String? = nil, quality: String? = nil) -> SportsClassifier.Match? {
        SportsClassifier.classify(title: title, subtitle: sub, category: cat, channelName: channel, channelCategory: channelCat, channelLanguage: lang, channelQuality: quality)
    }

    // MARK: every sport

    @Test(arguments: [
        ("Premier League: Arsenal v Chelsea", Sport.football), ("IPL 2026: Mumbai Indians vs Chennai Super Kings", .cricket), ("NBA | Lakers @ Celtics", .basketball),
        ("NFL: Chiefs vs Eagles", .americanFootball), ("MLB: Yankees @ Red Sox", .baseball), ("NHL: Rangers vs Bruins", .iceHockey), ("ATP: Djokovic vs Alcaraz", .tennis),
        ("WBC Heavyweight Title Fight: Fury vs Usyk", .boxing), ("UFC Fight Night: Smith vs Jones", .mma), ("Six Nations: France vs Ireland", .rugby),
    ])
    func headToHeadInEverySport(title: String, sport: Sport) throws {
        let m = try #require(c(title))
        #expect(m.sport == sport && m.kind == .headToHead && m.participants.count == 2, "\(title)")
    }

    @Test func aRaceSessionIsAnEventWithoutSides() throws {
        let race = try #require(c("Formula 1: Monaco Grand Prix - Race")), quali = try #require(c("Formula 1: Monaco Grand Prix - Qualifying")), p2 = try #require(c("F1 Practice 2: Monaco Grand Prix"))
        let sprint = try #require(c("Formula 1: Chinese Grand Prix Sprint"))
        #expect([race, quali, p2, sprint].allSatisfy { $0.sport == .motorsport && $0.kind == .raceSession && $0.participants.isEmpty })
        #expect(race.stage == "race" && quali.stage == "qualifying" && p2.stage == "practice 2" && sprint.stage == "sprint")
        #expect(race.identity != quali.identity && quali.identity != p2.identity, "a Grand Prix's sessions are separate events")
        #expect(race.identity == (try #require(c("LIVE: Formula 1 | Monaco Grand Prix Race HD"))).identity, "the same session under another title form")
        #expect(race.competition == "Formula 1")
    }

    @Test func aGolfTournamentRound() throws {
        let r3 = try #require(c("PGA Tour: Genesis Invitational - Round 3")), fin = try #require(c("PGA Tour: Genesis Invitational - Final Round"))
        #expect(r3.sport == .golf && r3.kind == .tournamentRound && r3.stage == "round 3" && fin.stage == "final round" && r3.participants.isEmpty)
        #expect(r3.identity != fin.identity)
        #expect(try #require(c("The Masters Tournament: Day 2")).stage == "day 2")
    }

    @Test func aTennisTournamentFinalAndAFightCard() throws {
        let final = try #require(c("Wimbledon: Men's Singles Final"))
        #expect(final.sport == .tennis && final.kind == .tournamentRound && final.stage == "final")
        let card = try #require(c("UFC 300: Main Card")), prelims = try #require(c("UFC 300: Prelims")), numberOnly = try #require(c("UFC 301"))
        #expect(card.kind == .fightCard && card.sport == .mma && card.stage == "main card" && prelims.stage == "prelims" && card.identity != prelims.identity)
        #expect(numberOnly.kind == .fightCard)
        #expect(try #require(c("Boxing: Fury vs Usyk")).kind == .headToHead, "a named bout has two sides")
    }

    @Test func aGenericEventNeedsAKnownCompetitionAndASpecificFinalOrMatch() throws {
        let ipl = try #require(c("IPL Final")), sb = try #require(c("Super Bowl LX")), g = try #require(c("NBA Playoff Game 3"))
        #expect(ipl.kind == .generic && ipl.stage == "final" && sb.kind == .generic && g.kind == .generic)
        for vague in ["Cricket Live", "IPL 2026 Live", "NBA Basketball", "Football Live", "Sky Sports Cricket", "Boxing: Main Event", "Formula 1 Race", "Golf Live", "Tennis"] {
            #expect(c(vague, channel: "Sports") == nil, "ambiguous, so skipped: \(vague)")
        }
    }

    // MARK: title forms

    @Test func titleFormsGiveTheSameSides() throws {
        for title in ["Arsenal vs Chelsea", "Arsenal v Chelsea", "Arsenal vs. Chelsea", "Premier League: Arsenal v Chelsea", "Premier League - Arsenal v Chelsea", "Premier League | Arsenal vs Chelsea",
                      "UEFA Champions League - Arsenal vs Chelsea - Matchday 3", "Arsenal - Chelsea", "Premier League - Arsenal - Chelsea"] {
            let m = try #require(c(title, channel: "Sky Sports Football", channelCat: "Football"), "\(title)")
            #expect(m.participants == ["Arsenal", "Chelsea"] && m.sport == .football, "\(title) -> \(m.participants)")
        }
        let at = try #require(c("NBA | Lakers @ Celtics"))
        #expect(at.participants == ["Celtics", "Lakers"], "for A @ B the home side (B) is listed first")
        #expect(try #require(c("Premier League", sub: "Arsenal v Chelsea")).participants == ["Arsenal", "Chelsea"], "the fixture in the sub-title")
    }

    @Test func qualityLanguageAndFeedSuffixesAreRemovedAndRemembered() throws {
        let cases: [(String, [String], String?, String?, String?)] = [
            ("Arsenal vs Chelsea (HD) [English]", ["Arsenal", "Chelsea"], "en", "HD", nil),
            ("Premier League: Arsenal v Chelsea | FHD", ["Arsenal", "Chelsea"], nil, "FHD", nil),
            ("Arsenal vs Chelsea - Home Feed", ["Arsenal", "Chelsea"], nil, nil, "home"),
            ("LIVE: Arsenal vs Chelsea 4K", ["Arsenal", "Chelsea"], nil, "4K", nil),
            ("Arsenal vs Chelsea - Away Feed HD", ["Arsenal", "Chelsea"], nil, "HD", "away"),
            ("EPL: Arsenal v Chelsea (Hindi)", ["Arsenal", "Chelsea"], "hi", nil, nil),
            ("Premier League: Arsenal v Chelsea Telugu HD", ["Arsenal", "Chelsea"], "te", "HD", nil),
        ]
        for (title, sides, lang, quality, variant) in cases {
            let m = try #require(c(title, channel: "Sky Sports Football", channelCat: "Football"), "\(title)")
            #expect(m.participants == sides, "\(title) -> \(m.participants)")
            #expect(m.language?.value == lang && m.quality?.value == quality && m.variant == variant, "\(title): \(String(describing: m.language)) \(String(describing: m.quality)) \(String(describing: m.variant))")
            if lang != nil { #expect(m.language?.source == .parsedFromName, "read out of the title, so a hint") }
        }
    }

    @Test func providerMetadataIsProviderAndParsedMetadataIsMarkedAsAHint() throws {
        let provider = try #require(c("Premier League: Arsenal v Chelsea HD", lang: "hi", quality: "FHD"))
        #expect(provider.language == .init(value: "hi", source: .provider) && provider.quality == .init(value: "FHD", source: .provider), "what the playlist says beats a suffix")
        let parsed = try #require(c("Premier League: Arsenal v Chelsea HD", channel: "Sky Sports Telugu"))
        #expect(parsed.quality == .init(value: "HD", source: .parsedFromName) && parsed.language == .init(value: "te", source: .parsedFromName))
        let unknown = try #require(c("Premier League: Arsenal v Chelsea", channel: "Sky Sports 1"))
        #expect(unknown.language == nil && unknown.quality == nil, "nothing is invented")
    }

    @Test func reversedSidesAreTheSameEventWhateverTheSport() throws {
        let pairs = [("Premier League: Arsenal vs Chelsea", "Premier League: Chelsea @ Arsenal"), ("IPL: Mumbai Indians vs Chennai Super Kings", "IPL: Chennai Super Kings v Mumbai Indians"), ("NBA: Lakers vs Celtics", "NBA: Celtics @ Lakers"),
                     ("NFL: Chiefs vs Eagles", "NFL: Eagles v Chiefs"), ("MLB: Yankees vs Red Sox", "MLB: Red Sox @ Yankees"), ("NHL: Rangers vs Bruins", "NHL: Bruins v Rangers"),
                     ("ATP: Djokovic vs Alcaraz", "ATP: Alcaraz v Djokovic"), ("Boxing: Fury vs Usyk", "Boxing: Usyk v Fury"), ("UFC Fight Night: Smith vs Jones", "UFC Fight Night: Jones v Smith"),
                     ("Six Nations: France vs Ireland", "Six Nations: Ireland v France")]
        for (a, b) in pairs {
            let x = try #require(c(a, channel: "Sports")), y = try #require(c(b, channel: "Sports"))
            #expect(x.identity == y.identity, "\(a) / \(b)")
        }
        #expect(try #require(c("Premier League: Arsenal vs Chelsea")).participants == ["Arsenal", "Chelsea"], "the display order is kept")
    }

    @Test func clubMarkersAndAccentsDoNotSplitAnEvent() throws {
        let a = try #require(c("La Liga: Atlético Madrid vs Real Betis")), b = try #require(c("La Liga: Atletico Madrid FC v Real Betis"))
        #expect(a.identity == b.identity)
    }

    // MARK: what is not an event

    @Test func newsStudioHighlightsDocumentariesAndReplaysAreNotEvents() {
        for title in ["Sky Sports News", "Cricket Highlights", "Premier League Highlights: Arsenal v Chelsea", "The Football Show", "Football Focus Tonight", "Arsenal vs Chelsea - Replay", "Arsenal v Chelsea Highlights",
                      "Pre-Match Show: Arsenal vs Chelsea", "NBA Daily", "Formula 1: Race Review", "UFC Countdown", "Rugby Documentary: The Haka", "Cricket Magazine", "IPL Preview Show", "Match of the Day",
                      "Golf Channel Live", "The Cricket Debate", "Post-Match Analysis: Arsenal v Chelsea", "Boxing History: Ali vs Frazier"] {
            #expect(c(title, channel: "Sky Sports Football", channelCat: "Football") == nil, "\(title)")
        }
        #expect(c("Premier League: Arsenal v Chelsea", cat: "Documentary") == nil && c("Premier League: Arsenal v Chelsea", cat: "News") == nil)
    }

    @Test func moviesAndSeriesWithAVersusInTheTitleAreNotEvents() {
        for title in ["Batman v Superman: Dawn of Justice", "Rocky vs Drago", "Alien vs. Predator", "Kramer vs. Kramer", "Godzilla v Kong", "Freddy vs Jason"] {
            #expect(c(title, cat: "Movie", channel: "HBO") == nil, "\(title)")
            #expect(c(title, channel: "Movies 24") == nil, "\(title): no sport named anywhere")
        }
        #expect(c("Rocky vs Drago", cat: "Movie", channel: "Sky Sports Boxing") == nil, "a movie category wins over a sports channel name")
    }

    @Test func missingOrMalformedGuideDataIsRefusedNotGuessed() {
        for title in ["", "   ", " vs ", "vs", "Arsenal vs", "vs Chelsea", "Arsenal vs Arsenal", "Premier League: 1 vs 2", String(repeating: "Premier League: Arsenal v Chelsea ", count: 20), "🔴", "----", "Premier League:"] {
            #expect(c(title, channel: "Sky Sports Football", channelCat: "Football") == nil, "\(title.prefix(30))")
        }
        #expect(c("Arsenal vs Chelsea", channel: "", channelCat: nil) == nil, "no sport named anywhere: not guessed")
        #expect(c("Arsenal vs Chelsea", channel: "Sky Sports Football") != nil, "the channel's own name can supply the sport at lower confidence")
    }

    @Test func confidenceIsHigherWithAKnownCompetition() throws {
        let known = try #require(c("Premier League: Arsenal v Chelsea")), fromTitleWord = try #require(c("Football: Arsenal v Chelsea")), fromChannel = try #require(c("Arsenal v Chelsea", channel: "Sky Sports Football"))
        #expect(known.confidence > fromTitleWord.confidence && fromTitleWord.confidence > fromChannel.confidence)
    }

    @Test func theSameInputAlwaysGivesTheSameAnswer() throws {
        let first = c("UEFA Champions League - Real Madrid v Barcelona (HD) [Spanish]")
        for _ in 0..<50 { #expect(c("UEFA Champions League - Real Madrid v Barcelona (HD) [Spanish]") == first) }
        #expect(first?.competition == "Champions League" || first?.competition == "UEFA Champions League")
    }
}
