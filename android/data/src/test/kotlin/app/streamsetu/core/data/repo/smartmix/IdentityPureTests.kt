package app.streamsetu.core.data.repo.smartmix

import app.streamsetu.core.data.repo.smartmix.CanonicalPick.Copy
import org.junit.Assert.*
import org.junit.Test

/** The identity rule, the derived facts and the choice of the copy to show (pure: no database). Synthetic titles only. */
class IdentityPureTests {
    // ---- IdentityKey ----
    @Test fun theKeyDropsYearQualityLanguageDubAndArticle() {
        for (t in listOf("Leo (2023) (Tamil) FHD", "Leo 2023 Hindi", "LEO [4K] Dubbed", "Leo")) assertEquals(t, "leo", IdentityKey.of(t))
        assertEquals(IdentityKey.of("The Fast & Furious"), IdentityKey.of("Fast and Furious"))
        assertEquals("night manager", IdentityKey.of("The Night Manager (2016)"))
    }
    @Test fun aTitleMadeOnlyOfTagsStillGetsAKey() { assertEquals("hindi 2020", IdentityKey.ofOrFallback("Hindi (2020)")); assertEquals("", IdentityKey.of("Hindi (2020)")) }
    @Test fun accentsAndScriptsKeepTheirLetters() {
        assertEquals("amelie", IdentityKey.of("Amélie"))
        assertEquals("ஜெயிலர்", IdentityKey.of("ஜெயிலர் (2023)")); assertNotEquals(IdentityKey.of("ஜெயிலர்"), IdentityKey.of("ஜெயிலா"))
        assertEquals("pyar ka punchnama", IdentityKey.of("Pyaar Ka Punchnama".replace("aa", "a")))
        assertTrue(IdentityKey.of("千と千尋の神隠し").isNotEmpty())
    }
    @Test fun yearComesFromTheProviderOrTheTitle() { assertEquals(2019, IdentityKey.yearOf("X", 2019)); assertEquals(2021, IdentityKey.yearOf("Dune (2021)", null)); assertNull(IdentityKey.yearOf("Dune", null)); assertEquals(1984, IdentityKey.yearOf("Dune (1984)", 0)) }
    @Test fun theHashIsTheSameEverywhere() { assertEquals(IdentityKey.fnv1a64("abc"), IdentityKey.fnv1a64("abc")); assertEquals(-3750763034362895579L, IdentityKey.fnv1a64("")); assertEquals(0xaf63dc4c8601ec8cuL.toLong(), IdentityKey.fnv1a64("a")) }

    // ---- Derive ----
    @Test fun languageComesFromTheTagThenTheFolderThenTheTitle() {
        assertEquals("Tamil", Derive.languageOf("Leo (2023) (Tamil)", "HINDI | NEW"))
        assertEquals("Hindi", Derive.languageOf("Leo", "ENGLISH | HINDI DUBBED"))
        assertEquals("Telugu", Derive.languageOf("Leo", "TELUGU | GENERAL"))
        assertNull("subtitles are not a language", Derive.languageOf("Leo", "ARABIC SUBTITLES"))
        assertEquals("Korean", Derive.languageOf("Parasite Korean", null))
        assertEquals("Hindi", Derive.languageName("hi")); assertEquals("Hindi", Derive.languageName("HINDI")); assertNull(Derive.languageName("x"))
    }
    @Test fun qualityRanksOnOneScaleAndARecordingFromACinemaIsLast() {
        assertEquals(5, Derive.qualityRank("Leo 4K", null)); assertEquals(4, Derive.qualityRank("Leo FHD", null)); assertEquals(3, Derive.qualityRank("Leo", "MOVIES HD"))
        assertEquals(2, Derive.qualityRank("Leo", null)); assertEquals(1, Derive.qualityRank("Leo SD", null)); assertEquals(0, Derive.qualityRank("Leo HDCAM", null)); assertEquals(0, Derive.qualityRank("Leo (CAM)", "NEW RELEASES"))
        assertTrue(Derive.derive("MOVIE", "Leo HDCAM", null, 2023).isCam)
    }
    @Test fun theSourceHashChangesWithWhatTheKeyIsMadeFrom() {
        val a = Derive.inHash("MOVIE", "Leo", "HINDI", 2023)
        assertEquals(a, Derive.inHash("MOVIE", "Leo", "HINDI", 2023))
        assertNotEquals(a, Derive.inHash("MOVIE", "Leo 2", "HINDI", 2023)); assertNotEquals(a, Derive.inHash("MOVIE", "Leo", "TAMIL", 2023)); assertNotEquals(a, Derive.inHash("MOVIE", "Leo", "HINDI", 2024))
    }

    // ---- Canonical pick ----
    private fun copy(id: String, src: String, title: String, year: Int? = 2023, folder: String? = "f-$src", folderName: String? = "ENGLISH | MOVIES", added: Long = 100, kind: String = "MOVIE"): Copy {
        val d = Derive.derive(kind, title, folderName, year)
        return Copy(id, kind, src, folder, d.identityKey, d.year, d.lang, d.qualityRank, added)
    }
    private fun ids(g: CanonicalPick.Group) = listOf(g.canonical.itemId) + g.alternatives.map { it.itemId }

    @Test fun twinPlaylistsAreOneTitleAndBothCopiesStayReachable() {
        val copies = listOf(copy("a1", "A", "Leo"), copy("b1", "B", "Leo"), copy("a2", "A", "Other"), copy("b2", "B", "Other"))
        val g = CanonicalPick.group(copies, CanonicalPick.Context(sourceRank = mapOf("A" to 0, "B" to 1)))
        assertEquals(2, g.size)
        assertEquals("a1", g.first { it.identityKey == "leo" }.canonical.itemId); assertEquals(listOf("b1"), g.first { it.identityKey == "leo" }.alternatives.map { it.itemId })
    }
    @Test fun theChoiceIsLanguageThenQualityThenPlaylistThenNewestThenId() {
        val tamilFhd = copy("t", "A", "Leo (Tamil) FHD"); val hindiHd = copy("h", "A", "Leo (Hindi) HD"); val hindiSd = copy("s", "A", "Leo (Hindi) SD"); val hindiHdB = copy("h2", "B", "Leo (Hindi) HD")
        val all = listOf(tamilFhd, hindiHd, hindiSd, hindiHdB)
        fun top(lang: String?, rank: Map<String, Int> = mapOf("A" to 0, "B" to 1)) = CanonicalPick.group(all, CanonicalPick.Context(preferredLang = lang, sourceRank = rank)).single().canonical.itemId
        assertEquals("t", top(null)); assertEquals("t", top("ta")); assertEquals("h", top("Hindi")); assertEquals("h2", top("Hindi", mapOf("A" to 1, "B" to 0)))
        val newer = copy("n", "A", "Leo (Hindi) HD", added = 999)
        assertEquals("n", CanonicalPick.group(listOf(hindiHd, newer), CanonicalPick.Context()).single().canonical.itemId)
        assertEquals("a", CanonicalPick.group(listOf(copy("b", "A", "Leo"), copy("a", "A", "Leo")), CanonicalPick.Context()).single().canonical.itemId)
    }
    @Test fun aFourKCopyInTheSecondPlaylistBeatsAnSdCopyInTheFirst() {
        val g = CanonicalPick.group(listOf(copy("a", "A", "Leo SD"), copy("b", "B", "Leo 4K")), CanonicalPick.Context(sourceRank = mapOf("A" to 0, "B" to 1))).single()
        assertEquals("b", g.canonical.itemId)
    }
    @Test fun theSameAnswerWhateverTheOrderTheCopiesComeIn() {
        val all = (1..12).map { copy("i$it", if (it % 2 == 0) "A" else "B", "Leo", added = (it % 3).toLong()) } + (1..5).map { copy("o$it", "A", "Other $it") }
        val ctx = CanonicalPick.Context(sourceRank = mapOf("A" to 0, "B" to 1))
        val base = CanonicalPick.group(all, ctx).associate { it.identityKey to ids(it) }
        repeat(20) { seed -> assertEquals(base, CanonicalPick.group(all.shuffled(java.util.Random(seed.toLong())), ctx).associate { it.identityKey to ids(it) }) }
    }
    @Test fun aRemakeOfAnotherYearIsAnotherTitle() {
        val g = CanonicalPick.group(listOf(copy("old", "A", "Dune", 1984), copy("new", "A", "Dune", 2021), copy("new2", "B", "Dune", 2021)))
        assertEquals(2, g.size); assertEquals(setOf("old"), g.first { it.year == 1984 }.let { ids(it).toSet() }); assertEquals(setOf("new", "new2"), g.first { it.year == 2021 }.let { ids(it).toSet() })
    }
    @Test fun aYearApartMergesOnlyWhenSomethingElseAgrees() {
        val c = listOf(copy("a", "A", "Heat Wave", 2023), copy("b", "B", "Heat Wave", 2024))
        assertEquals(2, CanonicalPick.group(c).size)
        assertEquals(1, CanonicalPick.group(c, CanonicalPick.Context(corroborated = { _, _ -> true })).size)
    }
    @Test fun aTitleWithNoYearJoinsTheMainOneOnlyWhenItHasTwoWords() {
        assertEquals(1, CanonicalPick.group(listOf(copy("a", "A", "Night Manager", 2016), copy("b", "B", "Night Manager", null))).size)
        assertEquals(2, CanonicalPick.group(listOf(copy("a", "A", "Tuesday", 2016), copy("b", "B", "Tuesday", null))).size)
    }
    @Test fun differentScriptsAreNeverMerged() { assertEquals(2, CanonicalPick.group(listOf(copy("a", "A", "千と千尋の神隠し"), copy("b", "A", "ஜெயிலர்"))).size) }
    @Test fun aTitleWithNoKeyIsNeverGrouped() { assertEquals(2, CanonicalPick.group(listOf(copy("a", "A", "Hindi (2020)").copy(identityKey = ""), copy("b", "B", "Hindi (2020)").copy(identityKey = ""))).size) }

    @Test fun aGroupIsRestrictedWhenAnyCopyIsAndNoRestrictedCopyIsAnAlternative() {
        val open = copy("o", "A", "Leo"); val locked = copy("l", "B", "Leo", folder = "locked"); val third = copy("t", "A", "Leo (Tamil)", folder = "f3")
        val ctx = CanonicalPick.Context(folderRestricted = { it.folderId == "locked" })
        val g = CanonicalPick.group(listOf(open, locked, third), ctx).single()
        assertTrue(g.restricted); assertTrue(g.alternatives.none { it.folderId == "locked" })
        assertFalse(CanonicalPick.group(listOf(open, third), ctx).single().restricted)
    }
    @Test fun aCopyInAPlaylistThatIsOffIsNeitherShownNorOffered() {
        val ctx = CanonicalPick.Context(accessible = { it.sourceId != "B" })
        val g = CanonicalPick.group(listOf(copy("a", "A", "Leo"), copy("b", "B", "Leo")), ctx).single()
        assertEquals(listOf("a"), ids(g)); assertTrue(CanonicalPick.group(listOf(copy("b", "B", "Leo")), ctx).isEmpty())
    }
    @Test fun aCinemaRecordingNeverBeatsARealCopyButStaysAnAlternative() {
        val g = CanonicalPick.group(listOf(copy("cam", "A", "Leo HDCAM"), copy("ok", "B", "Leo"))).single()
        assertEquals("ok", g.canonical.itemId); assertEquals(listOf("cam"), g.alternatives.map { it.itemId })
    }
    @Test fun aLibraryWithEightPercentRecordingsGroupsCleanly() {
        val all = (1..200).flatMap { n -> listOfNotNull(copy("a$n", "A", "Title $n"), copy("b$n", "B", if (n % 12 == 0) "Title $n HDCAM" else "Title $n")) }
        val g = CanonicalPick.group(all, CanonicalPick.Context(sourceRank = mapOf("A" to 0, "B" to 1)))
        assertEquals(200, g.size); assertTrue(g.all { it.canonical.qualityRank > 0 && it.alternatives.size == 1 })
    }

    // ---- Preferred playlist ----
    @Test fun thePreferredPlaylistFollowsHealthThenTheChoiceThenTheOrder() {
        val now = 100L * PreferredSource.STALE_MS
        val a = PreferredSource.Info("A", true, false, false, now, 0); val b = PreferredSource.Info("B", true, false, false, now, 1)
        assertEquals(mapOf("A" to 0, "B" to 1), PreferredSource.rank(listOf(b, a), null, now))
        assertEquals(mapOf("B" to 0, "A" to 1), PreferredSource.rank(listOf(a, b), "B", now))
        assertEquals("a failed playlist ranks below its healthy twin", mapOf("B" to 0, "A" to 1), PreferredSource.rank(listOf(a.copy(failed = true), b), null, now))
        assertEquals("a playlist not read for two weeks ranks below", mapOf("B" to 0, "A" to 1), PreferredSource.rank(listOf(a.copy(lastSyncAt = now - PreferredSource.STALE_MS - 1), b), null, now))
        assertEquals("the only playlist is never stale", 0, PreferredSource.rank(listOf(a.copy(lastSyncAt = 0)), null, now)["A"])
        assertEquals("a playlist that is off ranks last", mapOf("B" to 0, "A" to 1), PreferredSource.rank(listOf(a.copy(enabled = false), b), "A", now))
    }
}

class IdentityNormalizeCodePointTests {
    @org.junit.Test fun accentsGoAndLettersOutsideTheFirstPlaneStay() {
        org.junit.Assert.assertEquals("cafe", IdentityKey.normalize("Café"))
        org.junit.Assert.assertEquals("cafe", IdentityKey.normalize("Café"))
        val ext = String(Character.toChars(0x20BB7))          // a CJK extension B letter: one letter, not two halves turned into spaces
        org.junit.Assert.assertEquals(ext + " a", IdentityKey.normalize("$ext A").replace("  ", " "))
        org.junit.Assert.assertEquals("a b", IdentityKey.normalize("a 🎬 b"))          // an emoji is a separator
        org.junit.Assert.assertEquals("தமிழ்", IdentityKey.normalize("தமிழ்"))          // Tamil vowel signs stay
    }
}
