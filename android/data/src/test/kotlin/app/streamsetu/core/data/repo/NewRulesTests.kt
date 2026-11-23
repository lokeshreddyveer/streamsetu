package app.streamsetu.core.data.repo

import app.streamsetu.core.data.guidehub.ChannelNormalizer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The name-cleaning, language table, channel-name and search-example rules added with the persona work (artwork/fixtures/name-cleaning.json holds the shared cases). */
class NewRulesTests {
    @Test fun releaseGroupsAndEpisodeMarkersAreCleaned() {
        assertEquals("The Matrix", ArtworkNames.clean("The Matrix 1999 1080p-YIFY", 1999))
        assertEquals("Inception", ArtworkNames.clean("Inception.2010.720p.BluRay.x264-RARBG", 2010))
        assertEquals("Movie Name", ArtworkNames.clean("Movie Name 2019 1080p YTS.MX", 2019))
        assertEquals("Breaking Bad", ArtworkNames.clean("Breaking Bad 1x02 720p"))
        assertEquals("Dark", ArtworkNames.clean("Dark Season 1 Episode 2"))
        assertEquals("The Boys", ArtworkNames.clean("The Boys S03E05 WEB-DL"))
        assertEquals("Roma", ArtworkNames.clean("Roma (2018) [Spanish] 4K", 2018))
    }

    @Test fun anEpisodeWordNeedsMoreThanTwoWordsLeft() {
        assertEquals("Episode 2", ArtworkNames.clean("Episode 2"))
    }

    @Test fun languageTableCoversTheFifteenAddedLanguagesBothWays() {
        for ((name, code) in listOf("dutch" to "nl", "polish" to "pl", "persian" to "fa", "hebrew" to "he", "vietnamese" to "vi", "odia" to "or", "assamese" to "as", "nepali" to "ne", "sinhala" to "si", "malay" to "ms", "tagalog" to "tl", "portuguese" to "pt", "italian" to "it", "russian" to "ru", "indonesian" to "id")) {
            assertEquals(name, code, ArtworkMatchDecision.code(name)); assertEquals(code, name, ArtworkMatchDecision.name(code))
        }
        assertEquals("te-IN", ArtworkMatchDecision.searchLanguage("Telugu")); assertNull(ArtworkMatchDecision.searchLanguage("german"))
    }

    @Test fun aCopyMarkerIsNotPartOfAChannelName() {
        val plain = ChannelNormalizer.name("BBC One HD")
        for (raw in listOf("BBC One HD (backup)", "BBC One HD [alt 2]", "BBC One (Mirror) HD", "BBC One [RAW] HD", "BBC One HD (reserve 3)")) assertEquals(raw, plain.base, ChannelNormalizer.name(raw).base)
        assertEquals("+1", ChannelNormalizer.name("BBC One +1 (backup)").variant)
        assertEquals("backup plan", ChannelNormalizer.name("Backup Plan").base)
    }

    @Test fun exampleSearchesFollowThePersonsLanguageNotAFixedRegion() {
        fun texts(langs: List<String>, audio: String?, device: String?) = SearchIdeas.examples(langs, audio, device).joinToString("|") { it.query }.lowercase()
        assertTrue(texts(emptyList(), null, "de").contains("german movies"))
        assertTrue(texts(emptyList(), null, "ko").contains("korean movies"))
        assertTrue(texts(emptyList(), "es", "en").contains("spanish movies"))
        assertTrue(texts(listOf("Turkish", "Arabic"), null, "en").contains("arabic movies 2020s"))
        assertTrue(texts(emptyList(), null, "xx").contains("english movies"))
        for (d in listOf("en", "de", "ja", "ar", "es", "hi", "te")) { val all = texts(emptyList(), null, d); assertTrue(d, !all.contains("prabhas") && (!all.contains("telugu") || d == "te")) }
    }

    @Test fun pickerPutsTheDeviceLanguageThenTheLibraryLanguages() {
        val all = listOf("en" to "English", "hi" to "Hindi", "te" to "Telugu", "ta" to "Tamil", "es" to "Spanish")
        val order = LibraryLanguageHint.pickerOrder(all, "es", listOf("Tamil", "Spanish", "Hindi")).map { it.first }
        assertEquals(listOf("", "es", "ta", "hi", "en", "te"), order)
    }
}
