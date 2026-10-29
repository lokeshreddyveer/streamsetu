package app.streamsetu.core.sports

import app.streamsetu.core.sports.SportsClassifier.Hint
import org.junit.Assert.*
import org.junit.Test

class SportsClassifierTests {
    private fun c(title: String, sub: String? = null, cat: String? = null, channel: String = "Sports 1", channelCat: String? = null, lang: String? = null, quality: String? = null, fast: Boolean = true) =
        SportsClassifier.classify(title, sub, cat, channel, channelCat, lang, quality, fast)

    @Test fun headToHeadInEverySport() {
        val cases = listOf("Premier League: Arsenal v Chelsea" to Sport.FOOTBALL, "IPL 2026: Mumbai Indians vs Chennai Super Kings" to Sport.CRICKET, "NBA | Lakers @ Celtics" to Sport.BASKETBALL,
            "NFL: Chiefs vs Eagles" to Sport.AMERICAN_FOOTBALL, "MLB: Yankees @ Red Sox" to Sport.BASEBALL, "NHL: Rangers vs Bruins" to Sport.ICE_HOCKEY, "ATP: Djokovic vs Alcaraz" to Sport.TENNIS,
            "WBC Heavyweight Title Fight: Fury vs Usyk" to Sport.BOXING, "UFC Fight Night: Smith vs Jones" to Sport.MMA, "Six Nations: France vs Ireland" to Sport.RUGBY)
        for ((title, sport) in cases) { val m = c(title)!!; assertEquals(title, sport, m.sport); assertEquals(SportsEventKind.HEAD_TO_HEAD, m.kind); assertEquals(2, m.participants.size) }
    }

    @Test fun aRaceSessionIsAnEventWithoutSides() {
        val race = c("Formula 1: Monaco Grand Prix - Race")!!; val quali = c("Formula 1: Monaco Grand Prix - Qualifying")!!; val p2 = c("F1 Practice 2: Monaco Grand Prix")!!; val sprint = c("Formula 1: Chinese Grand Prix Sprint")!!
        for (m in listOf(race, quali, p2, sprint)) { assertEquals(Sport.MOTORSPORT, m.sport); assertEquals(SportsEventKind.RACE_SESSION, m.kind); assertTrue(m.participants.isEmpty()) }
        assertEquals("race", race.stage); assertEquals("qualifying", quali.stage); assertEquals("practice 2", p2.stage); assertEquals("sprint", sprint.stage)
        assertNotEquals(race.identity, quali.identity); assertNotEquals(quali.identity, p2.identity)
        assertEquals(race.identity, c("LIVE: Formula 1 | Monaco Grand Prix Race HD")!!.identity)
        assertEquals("Formula 1", race.competition)
    }

    @Test fun aGolfTournamentRound() {
        val r3 = c("PGA Tour: Genesis Invitational - Round 3")!!; val fin = c("PGA Tour: Genesis Invitational - Final Round")!!
        assertEquals(Sport.GOLF, r3.sport); assertEquals(SportsEventKind.TOURNAMENT_ROUND, r3.kind); assertEquals("round 3", r3.stage); assertEquals("final round", fin.stage); assertTrue(r3.participants.isEmpty())
        assertNotEquals(r3.identity, fin.identity)
        assertEquals("day 2", c("The Masters Tournament: Day 2")!!.stage)
    }

    @Test fun aTennisTournamentFinalAndAFightCard() {
        val final = c("Wimbledon: Men's Singles Final")!!
        assertEquals(Sport.TENNIS, final.sport); assertEquals(SportsEventKind.TOURNAMENT_ROUND, final.kind); assertEquals("final", final.stage)
        val card = c("UFC 300: Main Card")!!; val prelims = c("UFC 300: Prelims")!!; val numberOnly = c("UFC 301")!!
        assertEquals(SportsEventKind.FIGHT_CARD, card.kind); assertEquals(Sport.MMA, card.sport); assertEquals("main card", card.stage); assertEquals("prelims", prelims.stage); assertNotEquals(card.identity, prelims.identity)
        assertEquals(SportsEventKind.FIGHT_CARD, numberOnly.kind)
        assertEquals(SportsEventKind.HEAD_TO_HEAD, c("Boxing: Fury vs Usyk")!!.kind)
    }

    @Test fun aGenericEventNeedsAKnownCompetitionAndASpecificFinalOrMatch() {
        val ipl = c("IPL Final")!!; val sb = c("Super Bowl LX")!!; val g = c("NBA Playoff Game 3")!!
        assertEquals(SportsEventKind.GENERIC, ipl.kind); assertEquals("final", ipl.stage); assertEquals(SportsEventKind.GENERIC, sb.kind); assertEquals(SportsEventKind.GENERIC, g.kind)
        for (vague in listOf("Cricket Live", "IPL 2026 Live", "NBA Basketball", "Football Live", "Sky Sports Cricket", "Boxing: Main Event", "Formula 1 Race", "Golf Live", "Tennis")) assertNull("ambiguous, so skipped: $vague", c(vague, channel = "Sports"))
    }

    @Test fun titleFormsGiveTheSameSides() {
        for (title in listOf("Arsenal vs Chelsea", "Arsenal v Chelsea", "Arsenal vs. Chelsea", "Premier League: Arsenal v Chelsea", "Premier League - Arsenal v Chelsea", "Premier League | Arsenal vs Chelsea",
            "UEFA Champions League - Arsenal vs Chelsea - Matchday 3", "Arsenal - Chelsea", "Premier League - Arsenal - Chelsea")) {
            val m = c(title, channel = "Sky Sports Football", channelCat = "Football")!!
            assertEquals("$title -> ${m.participants}", listOf("Arsenal", "Chelsea"), m.participants); assertEquals(Sport.FOOTBALL, m.sport)
        }
        assertEquals(listOf("Celtics", "Lakers"), c("NBA | Lakers @ Celtics")!!.participants)
        assertEquals(listOf("Arsenal", "Chelsea"), c("Premier League", sub = "Arsenal v Chelsea")!!.participants)
    }

    @Test fun qualityLanguageAndFeedSuffixesAreRemovedAndRemembered() {
        class Case(val title: String, val lang: String?, val quality: String?, val variant: String?)
        for (k in listOf(Case("Arsenal vs Chelsea (HD) [English]", "en", "HD", null), Case("Premier League: Arsenal v Chelsea | FHD", null, "FHD", null), Case("Arsenal vs Chelsea - Home Feed", null, null, "home"),
            Case("LIVE: Arsenal vs Chelsea 4K", null, "4K", null), Case("Arsenal vs Chelsea - Away Feed HD", null, "HD", "away"), Case("EPL: Arsenal v Chelsea (Hindi)", "hi", null, null),
            Case("Premier League: Arsenal v Chelsea Telugu HD", "te", "HD", null))) {
            val m = c(k.title, channel = "Sky Sports Football", channelCat = "Football")!!
            assertEquals(k.title, listOf("Arsenal", "Chelsea"), m.participants)
            assertEquals(k.title, k.lang, m.language?.value); assertEquals(k.title, k.quality, m.quality?.value); assertEquals(k.title, k.variant, m.variant)
            if (k.lang != null) assertEquals(MetadataSource.PARSED_FROM_NAME, m.language?.source)
        }
    }

    @Test fun providerMetadataIsProviderAndParsedMetadataIsMarkedAsAHint() {
        val provider = c("Premier League: Arsenal v Chelsea HD", lang = "hi", quality = "FHD")!!
        assertEquals(Hint("hi", MetadataSource.PROVIDER), provider.language); assertEquals(Hint("FHD", MetadataSource.PROVIDER), provider.quality)
        val parsed = c("Premier League: Arsenal v Chelsea HD", channel = "Sky Sports Telugu")!!
        assertEquals(Hint("HD", MetadataSource.PARSED_FROM_NAME), parsed.quality); assertEquals(Hint("te", MetadataSource.PARSED_FROM_NAME), parsed.language)
        val unknown = c("Premier League: Arsenal v Chelsea", channel = "Sky Sports 1")!!
        assertNull(unknown.language); assertNull(unknown.quality)
    }

    @Test fun reversedSidesAreTheSameEventWhateverTheSport() {
        val pairs = listOf("Premier League: Arsenal vs Chelsea" to "Premier League: Chelsea @ Arsenal", "IPL: Mumbai Indians vs Chennai Super Kings" to "IPL: Chennai Super Kings v Mumbai Indians",
            "NBA: Lakers vs Celtics" to "NBA: Celtics @ Lakers", "NFL: Chiefs vs Eagles" to "NFL: Eagles v Chiefs", "MLB: Yankees vs Red Sox" to "MLB: Red Sox @ Yankees", "NHL: Rangers vs Bruins" to "NHL: Bruins v Rangers",
            "ATP: Djokovic vs Alcaraz" to "ATP: Alcaraz v Djokovic", "Boxing: Fury vs Usyk" to "Boxing: Usyk v Fury", "UFC Fight Night: Smith vs Jones" to "UFC Fight Night: Jones v Smith",
            "Six Nations: France vs Ireland" to "Six Nations: Ireland v France")
        for ((a, b) in pairs) assertEquals("$a / $b", c(a)!!.identity, c(b)!!.identity)
        assertEquals(listOf("Arsenal", "Chelsea"), c("Premier League: Arsenal vs Chelsea")!!.participants)
    }

    @Test fun clubMarkersAndAccentsDoNotSplitAnEvent() {
        assertEquals(c("La Liga: Atlético Madrid vs Real Betis")!!.identity, c("La Liga: Atletico Madrid FC v Real Betis")!!.identity)
    }

    @Test fun newsStudioHighlightsDocumentariesAndReplaysAreNotEvents() {
        for (title in listOf("Sky Sports News", "Cricket Highlights", "Premier League Highlights: Arsenal v Chelsea", "The Football Show", "Football Focus Tonight", "Arsenal vs Chelsea - Replay", "Arsenal v Chelsea Highlights",
            "Pre-Match Show: Arsenal vs Chelsea", "NBA Daily", "Formula 1: Race Review", "UFC Countdown", "Rugby Documentary: The Haka", "Cricket Magazine", "IPL Preview Show", "Match of the Day", "Golf Channel Live",
            "The Cricket Debate", "Post-Match Analysis: Arsenal v Chelsea", "Boxing History: Ali vs Frazier")) assertNull(title, c(title, channel = "Sky Sports Football", channelCat = "Football"))
        assertNull(c("Premier League: Arsenal v Chelsea", cat = "Documentary")); assertNull(c("Premier League: Arsenal v Chelsea", cat = "News"))
    }

    @Test fun moviesAndSeriesWithAVersusInTheTitleAreNotEvents() {
        for (title in listOf("Batman v Superman: Dawn of Justice", "Rocky vs Drago", "Alien vs. Predator", "Kramer vs. Kramer", "Godzilla v Kong", "Freddy vs Jason")) {
            assertNull(title, c(title, cat = "Movie", channel = "HBO")); assertNull("$title: no sport named anywhere", c(title, channel = "Movies 24"))
        }
        assertNull(c("Rocky vs Drago", cat = "Movie", channel = "Sky Sports Boxing"))
    }

    @Test fun missingOrMalformedGuideDataIsRefusedNotGuessed() {
        for (title in listOf("", "   ", " vs ", "vs", "Arsenal vs", "vs Chelsea", "Arsenal vs Arsenal", "Premier League: 1 vs 2", "Premier League: Arsenal v Chelsea ".repeat(20), "🔴", "----", "Premier League:"))
            assertNull(title.take(30), c(title, channel = "Sky Sports Football", channelCat = "Football"))
        assertNull(c("Arsenal vs Chelsea", channel = "", channelCat = null)); assertNotNull(c("Arsenal vs Chelsea", channel = "Sky Sports Football"))
    }

    @Test fun confidenceIsHigherWithAKnownCompetition() {
        val known = c("Premier League: Arsenal v Chelsea")!!; val word = c("Football: Arsenal v Chelsea")!!; val channel = c("Arsenal v Chelsea", channel = "Sky Sports Football")!!
        assertTrue(known.confidence > word.confidence && word.confidence > channel.confidence)
    }

    @Test fun theSameInputAlwaysGivesTheSameAnswer() {
        val first = c("UEFA Champions League - Real Madrid v Barcelona (HD) [Spanish]")
        repeat(50) { assertEquals(first, c("UEFA Champions League - Real Madrid v Barcelona (HD) [Spanish]")) }
    }

    @Test fun theHashIsAStableFnv1a() {
        assertEquals("af63dc4c8601ec8c", SportsEventService.hash("a"))
        assertEquals("cbf29ce484222325", SportsEventService.hash(""))
    }

    // ---- the shortcut changes nothing

    @Test fun theEarlyRefusalReturnsExactlyWhatTheFullPathReturns() {
        val titles = corpus(); val channels = listOf("Sports 1", "Sky Sports Football", "Channel 5", "Star Sports Hindi HD", "HBO", "Eurosport 2 4K", "")
        val categories = listOf<String?>(null, "Sports", "Movie", "News", "Football")
        var compared = 0; var found = 0
        for (t in titles) for (ch in channels) for (cat in categories) {
            val fast = SportsClassifier.classify(t, null, cat, ch, cat, null, null, true); val full = SportsClassifier.classify(t, null, cat, ch, cat, null, null, false)
            assertEquals("$t | $ch | $cat", full, fast); compared++; if (full != null) found++
        }
        assertEquals(titles.size * channels.size * categories.size, compared); assertTrue("compared $compared, $found events", found > 100)
    }

    companion object {
        fun corpus(): List<String> {
            val t = arrayListOf("Premier League: Arsenal v Chelsea", "Premier League - Arsenal v Chelsea", "Arsenal vs Chelsea", "Arsenal - Chelsea", "Chelsea @ Arsenal", "NBA | Lakers @ Celtics", "NFL: Chiefs vs Eagles",
                "MLB: Yankees @ Red Sox", "NHL: Rangers vs Bruins", "ATP: Djokovic vs Alcaraz", "WBC Heavyweight Title Fight: Fury vs Usyk", "UFC Fight Night: Smith vs Jones", "UFC 300: Main Card", "UFC 300: Prelims",
                "Six Nations: France vs Ireland", "IPL 2026: Mumbai Indians vs Chennai Super Kings", "IPL Final", "Super Bowl LX", "NBA Playoff Game 3", "Formula 1: Monaco Grand Prix - Race",
                "Formula 1: Monaco Grand Prix - Qualifying", "F1 Practice 2: Monaco Grand Prix", "Formula 1: Chinese Grand Prix Sprint", "PGA Tour: Genesis Invitational - Round 3", "The Masters Tournament: Day 2",
                "Wimbledon: Men's Singles Final", "Arsenal vs Chelsea (HD) [English]", "LIVE: Arsenal vs Chelsea 4K", "Arsenal vs Chelsea - Home Feed", "Premier League: Arsenal v Chelsea Telugu HD",
                "Cricket Live", "IPL 2026 Live", "Football Live", "Sky Sports Cricket", "Boxing: Main Event", "Formula 1 Race", "Golf Live", "Tennis", "Sky Sports News", "Cricket Highlights", "The Football Show",
                "Premier League Highlights: Arsenal v Chelsea", "Pre-Match Show: Arsenal vs Chelsea", "Match of the Day", "Batman v Superman: Dawn of Justice", "Rocky vs Drago", "Alien vs. Predator",
                "Kramer vs. Kramer", "Evening News", "Cooking Today", "Weather", "Quiz Night", "Documentary: The Sea", "Kids Cartoon Hour", "", "   ", " vs ", "vs", "Arsenal vs", "vs Chelsea", "🔴", "----",
                "La Liga: Atlético Madrid vs Real Betis", "La Liga: Atletico Madrid FC v Real Betis", "Champions League - Real Madrid v Barcelona (HD) [Spanish]", "Rugby: Wales v Scotland", "Basketball: Heat vs Bulls",
                "Soccer: Brazil v Argentina", "Cricket: India vs Australia", "Tennis: Swiatek vs Gauff", "Baseball: Dodgers @ Giants", "Hockey: Maple Leafs vs Canadiens", "Boxing: Fury vs Usyk", "Golf: Final Round",
                "Formula 1 Qualifying", "UFC", "Football", "NBA", "Grand Prix", "Monaco Grand Prix", "Round 3", "Final")
            val teams = listOf("Arsenal", "Chelsea", "Lakers", "Celtics", "Yankees", "Real Madrid", "Mumbai Indians", "India", "Australia", "Fury", "Usyk", "Alcaraz")
            val leagues = listOf("", "Premier League: ", "NBA | ", "IPL: ", "ATP: ", "Boxing: ", "UEFA Champions League - ", "Cricket: ", "News: ", "Movie: ")
            val seps = listOf(" vs ", " v ", " @ ", " - ", " vs. ")
            val suffixes = listOf("", " (HD)", " [English]", " | FHD", " - Home Feed", " 4K", " Hindi", " - Highlights", " - Replay")
            for ((i, l) in leagues.withIndex()) for ((j, s) in seps.withIndex()) for ((k, x) in suffixes.withIndex()) if ((i + j + k) % 2 == 0) t.add(l + teams[(i + j) % teams.size] + s + teams[(j + k + 3) % teams.size] + x)
            return t
        }
    }
}
