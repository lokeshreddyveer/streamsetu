import Testing
import Foundation
@testable import REDDY

@Suite struct PodcastTests {
    static let rss = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
      <title>The Evening Show</title><itunes:author>Radio One</itunes:author>
      <itunes:image href="https://img.example/show.jpg"/>
      <item><title>Second</title><description><![CDATA[<p>Hello &amp; welcome</p>]]></description>
        <enclosure url="https://cdn.example/2.mp3" type="audio/mpeg" length="1"/><pubDate>Tue, 13 Oct 2026 08:00:00 +0000</pubDate>
        <itunes:duration>1:02:03</itunes:duration><guid>g2</guid></item>
      <item><title>First</title><enclosure url="https://cdn.example/1.mp3" type="audio/mpeg"/><pubDate>Tue, 06 Oct 2026 08:00:00 +0000</pubDate><itunes:duration>2700</itunes:duration></item>
      <item><title>No audio</title></item>
    </channel></rss>
    """

    @Test func readsTheShowAndItsEpisodesNewestFirst() throws {
        let feed = try #require(PodcastParser.parse(Data(Self.rss.utf8)))
        #expect(feed.title == "The Evening Show" && feed.author == "Radio One")
        #expect(feed.artwork?.absoluteString == "https://img.example/show.jpg")
        #expect(feed.episodes.map(\.title) == ["Second", "First"])          // the one with no audio is left out
        #expect(feed.episodes[0].summary == "Hello & welcome")
        #expect(feed.episodes[0].duration == 3723 && feed.episodes[1].duration == 2700)
        #expect(feed.episodes[0].audioURL.absoluteString == "https://cdn.example/2.mp3")
        #expect(feed.episodes[0].published != nil)
    }

    @Test func somethingThatIsNotAFeedIsRefused() {
        #expect(PodcastParser.parse(Data("<html><body>hi</body></html>".utf8)) == nil)
        #expect(PodcastParser.parse(Data("nonsense".utf8)) == nil)
    }

    @Test func subscribingKeepsTheShowAndUnsubscribingForgetsIt() async throws {
        let d = UserDefaults(suiteName: "pod.\(UUID())")!
        let service = PodcastService(defaults: d, fetch: { _ in Data(Self.rss.utf8) })
        let url = URL(string: "https://feeds.example/evening.xml")!
        let sub = try await service.subscribe(url)
        #expect(sub.title == "The Evening Show")
        #expect(PodcastService(defaults: d).isSubscribed(url))
        service.unsubscribe(url)
        #expect(!PodcastService(defaults: d).isSubscribed(url))
    }

    @Test func directorySearchResultsAreRead() {
        let json = #"{"resultCount":2,"results":[{"collectionName":"Show A","artistName":"Ann","feedUrl":"https://a.example/feed","artworkUrl600":"https://a.example/a.jpg"},{"collectionName":"No feed"}]}"#
        let found = PodcastService.parseSearch(Data(json.utf8))
        #expect(found.count == 1 && found[0].title == "Show A" && found[0].feedURL.absoluteString == "https://a.example/feed")
    }
}
