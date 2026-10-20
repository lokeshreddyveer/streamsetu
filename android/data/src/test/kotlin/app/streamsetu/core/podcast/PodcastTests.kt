package app.streamsetu.core.podcast

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class PodcastTests {
    private val rss = """<?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
      <title>The Evening Show</title><itunes:author>Radio One</itunes:author><itunes:image href="https://img.example/show.jpg"/>
      <item><title>Second</title><description><![CDATA[<p>Hello &amp; welcome</p>]]></description>
        <enclosure url="https://cdn.example/2.mp3" type="audio/mpeg" length="1"/><pubDate>Tue, 13 Oct 2026 08:00:00 +0000</pubDate><itunes:duration>1:02:03</itunes:duration><guid>g2</guid></item>
      <item><title>First</title><enclosure url="https://cdn.example/1.mp3" type="audio/mpeg"/><pubDate>Tue, 06 Oct 2026 08:00:00 +0000</pubDate><itunes:duration>2700</itunes:duration></item>
      <item><title>No audio</title></item>
    </channel></rss>"""

    @Test fun readsTheShowAndItsEpisodesNewestFirst() {
        val feed = PodcastParser.parse(rss.toByteArray())!!
        assertEquals("The Evening Show", feed.title); assertEquals("Radio One", feed.author); assertEquals("https://img.example/show.jpg", feed.artwork)
        assertEquals(listOf("Second", "First"), feed.episodes.map { it.title })
        assertEquals("Hello & welcome", feed.episodes[0].summary)
        assertEquals(3723L, feed.episodes[0].durationSec); assertEquals(2700L, feed.episodes[1].durationSec)
        assertNotNull(feed.episodes[0].publishedMs)
    }

    @Test fun somethingThatIsNotAFeedIsRefused() {
        assertNull(PodcastParser.parse("<html><body>hi</body></html>".toByteArray()))
        assertNull(PodcastParser.parse("nonsense".toByteArray()))
    }
}
