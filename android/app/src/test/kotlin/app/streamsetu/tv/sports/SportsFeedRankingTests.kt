package app.streamsetu.tv.sports

import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.SportsFeed
import org.junit.Assert.*
import org.junit.Test

class SportsFeedRankingTests {
    private fun feed(id: String, source: String = "A", lang: String? = null, langSrc: MetadataSource = MetadataSource.UNKNOWN, q: String? = null, qSrc: MetadataSource = MetadataSource.UNKNOWN) =
        SportsFeed(id, source, "Channel $id", lang, langSrc, q, qSrc, null, id, 0L, false)
    private fun ids(r: List<RankedFeed>) = r.map { it.feed.channelId }
    private val P = MetadataSource.PROVIDER; private val N = MetadataSource.PARSED_FROM_NAME

    @Test fun providerLanguageBeatsInferredLanguage() {
        val r = SportsFeedRanker.rank(listOf(feed("inferred", lang = "en", langSrc = N), feed("provider", lang = "en", langSrc = P), feed("other", lang = "ar", langSrc = P)), RankInput(preferredLanguage = "en"))
        assertEquals(listOf("provider", "inferred", "other"), ids(r)); assertEquals(RankReason.LANGUAGE, r[0].reason)
    }

    @Test fun providerQualityBeatsInferredQuality() {
        val r = SportsFeedRanker.rank(listOf(feed("inferred4k", q = "4K", qSrc = N), feed("providerHd", q = "HD", qSrc = P)), RankInput())
        assertEquals("a quality the provider supplied outranks one read from a name", listOf("providerHd", "inferred4k"), ids(r)); assertEquals(RankReason.PROVIDER_QUALITY, r[0].reason)
    }

    @Test fun anInferredQualityOrdersFeedsWhenNothingBetterIsKnown() {
        val r = SportsFeedRanker.rank(listOf(feed("sd", q = "SD", qSrc = N), feed("fhd", q = "FHD", qSrc = N), feed("hd", q = "HD", qSrc = N)), RankInput())
        assertEquals(listOf("fhd", "hd", "sd"), ids(r)); assertEquals(RankReason.INFERRED_QUALITY, r[0].reason)
    }

    @Test fun aKnown4KThatTheDeviceCannotShowIsDeprioritised() {
        val feeds = listOf(feed("4k", q = "4K", qSrc = P), feed("hd", q = "HD", qSrc = P))
        assertEquals(listOf("4k", "hd"), ids(SportsFeedRanker.rank(feeds, RankInput(deviceDecodes4K = true))))
        val r = SportsFeedRanker.rank(feeds, RankInput(deviceDecodes4K = false))
        assertEquals(listOf("hd", "4k"), ids(r)); assertTrue(r[1].deprioritized); assertFalse(r[0].deprioritized)
    }

    @Test fun anInferred4KIsNeverCalledUnsupportedButEarnsNoPreferenceOverFhd() {
        val feeds = listOf(feed("fhd", q = "FHD", qSrc = N), feed("4k", q = "4K", qSrc = N))
        val r = SportsFeedRanker.rank(feeds, RankInput(deviceDecodes4K = false))
        assertEquals("a name alone is not proof; the earlier-listed feed of equal standing stays first", listOf("fhd", "4k"), ids(r))
        assertTrue(r.none { it.deprioritized })
        assertEquals("with the decoder, the 4K reading counts", listOf("4k", "fhd"), ids(SportsFeedRanker.rank(feeds, RankInput(deviceDecodes4K = true))))
    }

    @Test fun unknownMetadataStaysUnknownAndUsable() {
        val r = SportsFeedRanker.rank(listOf(feed("1"), feed("2"), feed("3")), RankInput(preferredLanguage = "en"))
        assertEquals(listOf("1", "2", "3"), ids(r)); assertTrue(r.all { it.reason == RankReason.PROVIDER_ORDER })
        assertTrue(r.all { it.feed.language == null && it.feed.quality == null })
    }

    @Test fun tiesAreBrokenByTheProvidersOrderAndRepeatably() {
        val feeds = listOf(feed("a", q = "HD", qSrc = P), feed("b", q = "HD", qSrc = P), feed("c", q = "HD", qSrc = P))
        val once = ids(SportsFeedRanker.rank(feeds, RankInput())); val twice = ids(SportsFeedRanker.rank(feeds, RankInput()))
        assertEquals(listOf("a", "b", "c"), once); assertEquals(once, twice)
    }

    @Test fun thePreferredSourceThenAKnownHealthyChannelBreakTiesBeforeProviderOrder() {
        val feeds = listOf(feed("a", "A"), feed("b", "B"), feed("c", "C"))
        assertEquals("c", ids(SportsFeedRanker.rank(feeds, RankInput(preferredSourceIds = listOf("C", "B")))).first())
        assertEquals("b", ids(SportsFeedRanker.rank(feeds, RankInput(healthyChannelIds = setOf("b")))).first())
    }

    @Test fun theChoiceMadeEarlierAndTheFeedThatPlayedAreRemembered() {
        val feeds = listOf(feed("best", q = "FHD", qSrc = P), feed("played"), feed("chosen"))
        assertEquals("played", ids(SportsFeedRanker.rank(feeds, RankInput(playedChannelId = "played"))).first())
        val r = SportsFeedRanker.rank(feeds, RankInput(selectedChannelId = "chosen", playedChannelId = "played"))
        assertEquals(listOf("chosen", "played", "best"), ids(r)); assertEquals(RankReason.YOUR_CHOICE, r[0].reason); assertEquals(RankReason.PLAYED_EARLIER, r[1].reason)
    }

    @Test fun theRecommendationIsExplainedInPlainWords() {
        val r = SportsFeedRanker.rank(listOf(feed("a", lang = "en", langSrc = P, q = "FHD", qSrc = P)), RankInput(preferredLanguage = "en"))
        assertEquals("Best available · English · FHD", SportsFeedRanker.explain(r[0]) { if (it == "en") "English" else it })
        assertEquals("Best available", SportsFeedRanker.explain(SportsFeedRanker.rank(listOf(feed("x")), RankInput())[0]))
    }

    @Test fun noFeedsRankToNothing() { assertTrue(SportsFeedRanker.rank(emptyList(), RankInput()).isEmpty()) }
}
