package app.streamsetu.core.data

import app.streamsetu.core.model.Plurals
import app.streamsetu.core.model.SortKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PluralsAndSortKeyTests {
    @Test fun everyPhraseExistsInEnglishHindiAndTeluguWithOneNumberPlace() {
        for (k in Plurals.keys) for (l in Plurals.languages) {
            val f = Plurals.forms(k, l)!!
            assertEquals("$k/$l one", 1, f.first.split("{}").size - 1); assertEquals("$k/$l other", 1, f.second.split("{}").size - 1)
            assertTrue("$k/$l is empty", f.first.isNotBlank() && f.second.isNotBlank())
        }
    }

    @Test fun englishAndTeluguSeparateOneFromOtherHindiTreatsZeroAsOne() {
        assertEquals("1 title", Plurals.format("title", 1, "en")); assertEquals("0 titles", Plurals.format("title", 0, "en")); assertEquals("2 titles", Plurals.format("title", 2, "en"))
        assertEquals("1 శీర్షిక", Plurals.format("title", 1, "te")); assertEquals("2 శీర్షికలు", Plurals.format("title", 2, "te"))
        assertEquals("0 रिमाइंडर सेट किया गया।", Plurals.format("reminderSet", 0, "hi")); assertEquals("2 रिमाइंडर सेट किए गए।", Plurals.format("reminderSet", 2, "hi"))
        assertEquals("1 reminder set.", Plurals.format("reminderSet", 1, "en")); assertEquals("3 titles", Plurals.format("title", 3, "xx"))      // an unknown language falls back to English
    }

    @Test fun accentsFoldAndAsciiKeepsTheOldKey() {
        assertEquals("emile", SortKey.of("Émile")); assertEquals("orsted", SortKey.of("Ørsted")); assertEquals("strasse", SortKey.of("Straße")); assertEquals("zebra", SortKey.of("Zebra"))
        assertEquals("the matrix: 2", SortKey.of("The Matrix: 2")); assertEquals("తెలుగు", SortKey.of("తెలుగు")); assertEquals("हिन्दी", SortKey.of("हिन्दी"))
        for (t in listOf("Avatar", "avatar", "ZED Film 2", "x-men")) assertEquals(t.lowercase(), SortKey.of(t))
    }

    @Test fun accentedTitlesOrderBesideTheirPlainLetters() {
        val sorted = listOf("Zebra", "Émile", "Eagle", "Ålesund", "Apple", "Ünal").sortedBy { SortKey.of(it) }
        assertEquals(listOf("Ålesund", "Apple", "Eagle", "Émile", "Ünal", "Zebra"), sorted)
    }

    @Test fun theSqlExpressionHoldsEveryFoldedCharacterOnce() {
        val steps = SortKey.updateStatements("movies", "NEW.title", "rowid = NEW.rowid")
        val sql = steps.joinToString(";")
        assertTrue(steps.first().contains("lower(NEW.title)") && steps.drop(1).all { it.contains("replace(titleSort,") || it.contains("(titleSort,") })
        assertEquals(SortKey.table.size, Regex.escape("replace(").toRegex().findAll(sql).count())
        assertTrue(steps.all { st -> Regex.escape("replace(").toRegex().findAll(st).count() <= SortKey.CHUNK })
        assertTrue(SortKey.table.keys.none { it == '\'' || it.code < 128 })
    }

    @Test fun shelfModeStoreKeepsEitherChoiceAndKnowsWhenThereIsNone() {
        val mem = HashMap<String, String>()
        val st = app.streamsetu.core.data.smartmix.ShelfModeStore({ mem[it] }, { k, v -> if (v == null) mem.remove(k) else mem[k] = v })
        assertEquals(null, st.chosen("a", "genre:thriller"))
        st.set("a", "genre:thriller", app.streamsetu.core.data.smartmix.ShelfView.WEEKLY)
        assertEquals(app.streamsetu.core.data.smartmix.ShelfView.WEEKLY, st.chosen("a", "genre:thriller"))
        st.set("a", "genre:thriller", app.streamsetu.core.data.smartmix.ShelfView.ALL_TIME)
        assertEquals(app.streamsetu.core.data.smartmix.ShelfView.ALL_TIME, st.mode("a", "genre:thriller")); assertEquals(null, st.chosen("b", "genre:thriller"))
    }
}
