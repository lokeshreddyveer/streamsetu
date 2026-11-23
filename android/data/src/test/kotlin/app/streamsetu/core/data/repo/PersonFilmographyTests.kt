package app.streamsetu.core.data.repo

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException

class PersonFilmographyTests {
    @get:Rule val tmp = TemporaryFolder()

    private val person = """{"id":7,"name":"Ann Actor","biography":"","profile_path":"/p.jpg","known_for_department":"Acting","birthday":"1975-08-24","place_of_birth":"Hyderabad, India","also_known_as":["A. Actor"],"images":{"profiles":[{"file_path":"/1.jpg"},{"file_path":"/2.jpg"}]}}"""
    private val personEn = """{"id":7,"name":"Ann Actor","biography":"An actor."}"""
    private val credits = """{"cast":[
        {"id":1,"media_type":"movie","title":"Pokiri","original_title":"Pokiri","release_date":"2006-04-28","poster_path":"/a.jpg","vote_average":7.4,"vote_count":900,"popularity":30.0,"character":"Pandu"},
        {"id":1,"media_type":"movie","title":"Pokiri","release_date":"2006-04-28","poster_path":"/a.jpg","vote_average":7.4,"vote_count":900,"popularity":30.0,"character":"Pandu"},
        {"id":2,"media_type":"movie","title":"Junk Rated","release_date":"2010-01-01","poster_path":"/b.jpg","vote_average":10.0,"vote_count":1,"popularity":5.0},
        {"id":3,"media_type":"movie","title":"Nothing Known","popularity":1.0},
        {"id":4,"media_type":"tv","name":"A Show","first_air_date":"2020-02-02","poster_path":"/c.jpg","vote_average":8.1,"vote_count":300,"popularity":12.0,"genre_ids":[18]},
        {"id":5,"media_type":"tv","name":"Late Night","first_air_date":"2020-02-02","poster_path":"/d.jpg","genre_ids":[10767]},
        {"id":6,"media_type":"movie","title":"Undated","poster_path":"/e.jpg","vote_average":6.0,"vote_count":50}
      ],"crew":[{"id":9,"media_type":"movie","title":"Directed One","release_date":"2015-01-01","poster_path":"/f.jpg","job":"Director"},{"id":10,"media_type":"movie","title":"Produced","release_date":"2016-01-01","poster_path":"/g.jpg","job":"Producer"}]}"""

    @Test fun creditsAreDedupedAndJunkIsDropped() {
        val l = TmdbPeople.parseCredits(credits, "Acting")
        assertEquals(listOf("Pokiri", "Junk Rated", "A Show", "Undated"), l.map { it.title })
        assertNull("no date and no poster is dropped", l.firstOrNull { it.title == "Nothing Known" })
        assertNull("a talk show is out", l.firstOrNull { it.title == "Late Night" })
        assertNull("10.0 from one vote is not credible", l.first { it.title == "Junk Rated" }.rating)
        assertEquals(7.4, l.first { it.title == "Pokiri" }.rating!!, 0.0)
        assertEquals(2006, l.first { it.title == "Pokiri" }.year)
        assertNull("a poster without a date is kept, with no year", l.first { it.title == "Undated" }.year)
    }

    @Test fun aDirectorGetsDirectorCreditsAnActorDoesNot() {
        assertTrue(TmdbPeople.parseCredits(credits, "Directing").any { it.title == "Directed One" })
        assertFalse(TmdbPeople.parseCredits(credits, "Directing").any { it.title == "Produced" })
        assertFalse(TmdbPeople.parseCredits(credits, "Acting").any { it.title == "Directed One" })
    }

    @Test fun ratingRule() {
        assertNull(DisplayRating.credible(0.0, 500)); assertNull(DisplayRating.credible(8.0, 3)); assertNull(DisplayRating.credible(null, 100)); assertEquals(8.0, DisplayRating.credible(8.0, 10)!!, 0.0)
    }

    @Test fun sortAndFilter() {
        val l = TmdbPeople.parseCredits(credits, "Acting")
        val tiles = l.map { FilmTile(it, if (it.title == "Pokiri") LibraryHit(null, null, 2) else null) }
        assertEquals(listOf("A Show", "Junk Rated", "Pokiri", "Undated"), FilmographyView.arrange(tiles, FilmSort.NEWEST, FilmKind.ALL, false).map { it.credit.title })
        assertEquals("Undated", FilmographyView.arrange(tiles, FilmSort.NEWEST, FilmKind.ALL, false).last().credit.title)
        assertEquals("A Show", FilmographyView.arrange(tiles, FilmSort.NEWEST, FilmKind.ALL, false).first().credit.title)
        assertEquals("Pokiri", FilmographyView.arrange(tiles, FilmSort.POPULAR, FilmKind.ALL, false).first().credit.title)
        assertEquals("A Show", FilmographyView.arrange(tiles, FilmSort.RATING, FilmKind.ALL, false).first().credit.title)
        assertEquals(listOf("A Show"), FilmographyView.arrange(tiles, FilmSort.NEWEST, FilmKind.SERIES, false).map { it.credit.title })
        assertEquals(listOf("Pokiri"), FilmographyView.arrange(tiles, FilmSort.NEWEST, FilmKind.ALL, true).map { it.credit.title })
        assertEquals(3 to 1, FilmographyView.counts(tiles, FilmKind.MOVIES))
        assertEquals(1 to 0, FilmographyView.counts(tiles, FilmKind.SERIES))
    }

    @Test fun nameSearchPrefersTheExactNameKnownForTheTappedTitle() {
        val json = """{"results":[{"id":1,"name":"Mahesh Babu","known_for":[{"title":"Other"}]},{"id":2,"name":"Mahesh Babu","known_for":[{"title":"Pokiri"}]},{"id":3,"name":"Mahesh Babu Jr","known_for":[{"title":"Pokiri"}]}]}"""
        val r = TmdbPeople.parseSearch(json)
        assertEquals(2L, TmdbPeople.choosePerson(r, "Mahesh Babu", "Pokiri (2006)"))
        assertEquals(1L, TmdbPeople.choosePerson(r, "Mahesh Babu", null))
        assertNull(TmdbPeople.choosePerson(r, "Nobody", "Pokiri"))
    }

    private fun people(dir: File, now: () -> Long = { 1_000_000_000_000L }, key: String? = "KEY", urls: MutableList<String> = ArrayList(), fail: Boolean = false) =
        TmdbPeople(TmdbAuth({ key }, { null }, dir, now), dir, { u, _ -> urls += u; if (fail) throw IOException("offline"); when {
            "combined_credits" in u -> credits
            "language=en-US" in u -> personEn
            "/search/person" in u -> """{"results":[{"id":7,"name":"Ann Actor","known_for":[]}]}"""
            else -> person } }, now)

    @Test fun loadCachesAnd30DaysAndNothingAboutTheLibraryIsSent() {
        val dir = tmp.newFolder(); val urls = ArrayList<String>(); var t = 1_000_000_000_000L
        val p = people(dir, { t }, urls = urls)
        val f = p.load(7, "te"); dir.listFiles()!!.forEach { it.setLastModified(t) }
        assertEquals("the biography falls back to English when empty", "An actor.", f.person!!.biography)
        assertEquals(2, f.person!!.photos.size); assertEquals(4, f.credits.size)
        assertTrue(urls.all { "themoviedb.org/3/" in it && ("person/7" in it || "search/person" in it) })
        assertNotNull(p.cached(7, "te")); assertTrue(p.isFresh(7, "te"))
        assertEquals(f, p.cached(7, "te"))
        t += 31 * TmdbFiles.DAY_MS
        assertFalse("30 days old is not fresh", people(dir, { t }).isFresh(7, "te"))
        assertNotNull("but is shown while refreshing", people(dir, { t }).cached(7, "te"))
        t += 160 * TmdbFiles.DAY_MS
        assertNull("past 180 days it is not shown", people(dir, { t }).cached(7, "te"))
    }

    @Test fun purgeAndClearRemovePersonFiles() {
        val dir = tmp.newFolder(); var t = 1_000_000_000_000L
        val p = people(dir, { t }); p.load(7, "en")
        assertEquals(1, dir.listFiles { f -> f.name.startsWith(TmdbPeople.PREFIX) }!!.size)
        val old = dir.listFiles()!!.first(); old.setLastModified(t - 181 * TmdbFiles.DAY_MS)
        assertEquals(1, TmdbFiles.purge(dir, t)); assertNull(p.cached(7, "en"))
        p.load(7, "en"); TmdbFiles.clear(dir)
        assertEquals(0, dir.listFiles { f -> f.name.startsWith(TmdbPeople.PREFIX) }!!.size)
    }

    @Test fun noCredentialAndOfflineAreQuietFailures() {
        val dir = tmp.newFolder(); val urls = ArrayList<String>()
        val none = people(dir, key = null, urls = urls)
        assertFalse(none.enabled); assertNull(none.resolve("Ann Actor", null)); assertTrue(urls.isEmpty())
        assertThrows(IOException::class.java) { none.load(7) }
        assertThrows(IOException::class.java) { people(dir, fail = true).load(7, "en") }
        assertNull("nothing was saved by a failed load", people(dir).cached(7, "en"))
    }

    @Test fun resolveAsksOnceThenRemembers() {
        val dir = tmp.newFolder(); val urls = ArrayList<String>(); val p = people(dir, urls = urls)
        assertEquals(7L, p.resolve("Ann Actor", "X")); assertEquals(7L, p.resolve("Ann Actor", "X")); assertEquals(1, urls.size)
    }

    @Test fun headerLines() {
        val info = TmdbPeople.parsePerson(person)!!
        val now = java.util.GregorianCalendar(2026, 10, 22).timeInMillis
        assertEquals("Born 24 Aug 1975 (age 51) · Hyderabad, India", PersonText.born(info, now))
        assertEquals("Acting · Pokiri, A Show", PersonText.knownFor("Acting", listOf("Pokiri", "A Show")))
        assertEquals("A. Actor", PersonText.alsoKnownAs(info))
        assertNull(PersonText.alsoKnownAs(info.copy(alsoKnownAs = listOf("x".repeat(80)))))
    }

    // ---- acting roles against voice, narration and cameo credits (TMDB-shaped: a narrator at order 23 beside a lead at order 0)
    private val mixed = """{"cast":[
        {"id":11,"media_type":"movie","title":"Lead Film","release_date":"2015-01-01","poster_path":"/1.jpg","popularity":9.0,"character":"Pandu","order":0},
        {"id":12,"media_type":"movie","title":"Narrated Film","release_date":"2016-01-01","poster_path":"/2.jpg","popularity":8.0,"character":"Narrator (voice)","order":23},
        {"id":13,"media_type":"movie","title":"Voiceover Film","release_date":"2017-01-01","poster_path":"/3.jpg","popularity":7.0,"character":"Voiceover","order":30},
        {"id":14,"media_type":"movie","title":"Cameo Film","release_date":"2018-01-01","poster_path":"/4.jpg","popularity":6.0,"character":"Cameo","order":40},
        {"id":15,"media_type":"tv","name":"Guest Show","first_air_date":"2019-01-01","poster_path":"/5.jpg","popularity":5.0,"character":"Guest","order":3},
        {"id":16,"media_type":"movie","title":"Himself Film","release_date":"2014-01-01","poster_path":"/6.jpg","popularity":4.0,"character":"Himself","order":9},
        {"id":17,"media_type":"movie","title":"Sung Film","release_date":"2013-01-01","poster_path":"/7.jpg","popularity":3.0,"character":"Playback Singer","order":50},
        {"id":18,"media_type":"movie","title":"Supporting Film","release_date":"2012-01-01","poster_path":"/8.jpg","popularity":2.0,"character":"Raju","order":14}
      ],"crew":[{"id":19,"media_type":"movie","title":"Directed Film","release_date":"2011-01-01","poster_path":"/9.jpg","job":"Director"},{"id":20,"media_type":"movie","title":"Produced Film","release_date":"2010-01-01","poster_path":"/a.jpg","job":"Producer"},{"id":21,"media_type":"movie","title":"Presented","release_date":"2009-01-01","poster_path":"/b.jpg","job":"Presenter"}]}"""

    @Test fun classifierSeparatesActingFromVoiceCameoAndCrew() {
        assertEquals(CreditKind.ON_SCREEN, CreditClassifier.classify("Pandu", 0)); assertEquals(CreditKind.ON_SCREEN, CreditClassifier.classify("Raju", 14)); assertEquals(CreditKind.ON_SCREEN, CreditClassifier.classify(null, null))
        assertEquals(CreditKind.VOICE, CreditClassifier.classify("Narrator (voice)", 23)); assertEquals(CreditKind.VOICE, CreditClassifier.classify("Voiceover", 30)); assertEquals(CreditKind.VOICE, CreditClassifier.classify("Hindi dub", 4))
        for (c in listOf("Cameo", "Guest", "Special Appearance", "Himself", "Herself", "Self")) assertEquals(c, CreditKind.CAMEO, CreditClassifier.classify(c, 1))
        assertEquals(CreditKind.CREW, CreditClassifier.classify("Director", null)); assertEquals(CreditKind.CREW, CreditClassifier.classify("Creator", null))
        assertEquals("Narrator", CreditClassifier.tag("Narrator (voice)", 23)); assertEquals("Voice", CreditClassifier.tag("Voiceover", 30)); assertEquals("Cameo", CreditClassifier.tag("Cameo", 40)); assertEquals("Guest", CreditClassifier.tag("Guest", 3)); assertNull(CreditClassifier.tag("Pandu", 0))
        assertTrue(CreditClassifier.crewOnlyCharacter("Playback Singer")); assertFalse(CreditClassifier.crewOnlyCharacter("Pandu"))
    }

    @Test fun crewCreditsStayOutExceptDirectorAndCreatorForDirectors() {
        val actor = TmdbPeople.parseCredits(mixed, "Acting").map { it.title }
        assertFalse("Sung Film" in actor); assertFalse("Directed Film" in actor); assertFalse("Produced Film" in actor); assertFalse("Presented" in actor)
        val director = TmdbPeople.parseCredits(mixed, "Directing").map { it.title }
        assertTrue("Directed Film" in director); assertFalse("Produced Film" in director); assertFalse("Presented" in director)
    }

    @Test fun onScreenFirstThenVoiceAndCameoGroupedUnderTheSortAndTheFilterAndCountsFollow() {
        val tiles = TmdbPeople.parseCredits(mixed, "Acting").map { FilmTile(it, if (it.title == "Narrated Film" || it.title == "Lead Film") LibraryHit(null, null, 1) else null) }
        val all = FilmographyView.arrange(tiles, FilmSort.NEWEST, FilmKind.ALL, false)
        assertEquals(listOf("Lead Film", "Supporting Film"), all.take(2).map { it.credit.title }.sortedBy { listOf("Lead Film", "Supporting Film").indexOf(it) })
        assertEquals(listOf("Lead Film", "Supporting Film", "Guest Show", "Cameo Film", "Voiceover Film", "Narrated Film", "Himself Film").let { listOf("Lead Film", "Supporting Film") }, all.take(2).map { it.credit.title }.sortedBy { listOf("Lead Film", "Supporting Film").indexOf(it) })
        assertEquals("on-screen credits come first, newest first", listOf("Lead Film", "Supporting Film"), all.take(2).map { it.credit.title })
        assertEquals(2, FilmographyView.secondaryStart(all))
        assertEquals("then the grouped ones, newest first", listOf("Guest Show", "Cameo Film", "Voiceover Film", "Narrated Film", "Himself Film"), all.drop(2).map { it.credit.title }.let { g -> g })
        // the group also holds inside "In your library"
        val lib = FilmographyView.arrange(tiles, FilmSort.NEWEST, FilmKind.ALL, true)
        assertEquals(listOf("Lead Film", "Narrated Film"), lib.map { it.credit.title }); assertEquals(1, FilmographyView.secondaryStart(lib))
        // Acting only
        val acting = FilmographyView.arrange(tiles, FilmSort.NEWEST, FilmKind.ALL, false, actingOnly = true)
        assertEquals(listOf("Lead Film", "Supporting Film"), acting.map { it.credit.title }); assertEquals(-1, FilmographyView.secondaryStart(acting))
        assertEquals(7 to 2, FilmographyView.counts(tiles, FilmKind.ALL)); assertEquals(2 to 1, FilmographyView.counts(tiles, FilmKind.ALL, actingOnly = true))
        assertEquals(1 to 0, FilmographyView.counts(tiles, FilmKind.SERIES)); assertEquals(0 to 0, FilmographyView.counts(tiles, FilmKind.SERIES, actingOnly = true))
        // order survives the saved copy
        assertEquals(23, TmdbPeople.parseCredits(mixed, "Acting").first { it.title == "Narrated Film" }.order)
    }
}
