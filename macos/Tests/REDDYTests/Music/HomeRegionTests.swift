import Testing
import Foundation
@testable import REDDY

// Home's region, language, hero, continue-listening and cache rules, and the parsers of the regional sources against trimmed live replies
// (taken 2026-11-25 with no key). Nothing here touches the network.

private enum HomeRegionFixtures {
    /// JioSaavn web home with the Telugu setting: the new songs and albums, and the charts list.
    static let jioLaunch = #"""
{"new_albums":[{"id":"-7ArPopr","title":"Diviki Diviki (From &quot;January 12 Vidudala&quot;)","subtitle":"G.V. Prakash Kumar, Anantha Sriram - Diviki Diviki (From &quot;January 12 Vidudala&quot;)","type":"song","perma_url":"https://www.jiosaavn.com/song/diviki-diviki-from-january-12-vidudala/XV8qQyRfR0E","image":"https://c.saavncdn.com/200/Diviki-Diviki-From-January-12-Vidudala-Telugu-2026-20261123131527-150x150.jpg","language":"telugu","year":"2026","play_count":"16721","explicit_content":"0","more_info":{"music":"G.V. Prakash Kumar","album_id":"83971039","album":"Diviki Diviki (From &quot;January 12 Vidudala&quot;)","duration":"149","artistMap":{"primary_artists":[{"id":"455454","name":"G.V. Prakash Kumar","image":"https://c.saavncdn.com/artists/G_V__Prakash_Kumar_003_20251113063655_150x150.jpg","perma_url":"https://www.jiosaavn.com/artist/g.v.-prakash-kumar-songs/b2CMYiogn3E_"},{"id":"456746","name":"Anantha Sriram","image":"https://c.saavncdn.com/artists/Anantha_Sriram_20180502124137_150x150.jpg","perma_url":"https://www.jiosaavn.com/artist/anantha-sriram-songs/PcZ7QTA-ErU_"}]},"release_date":"2026-06-21"}},{"id":"VaoxVWpz","title":"Osey Ramulamma (From &quot;Mysaa&quot;)","subtitle":"Vandemataram Srinivas - Osey Ramulamma (From &quot;Mysaa&quot;)","type":"song","perma_url":"https://www.jiosaavn.com/song/osey-ramulamma-from-mysaa/JgkESSJnR0k","image":"https://c.saavncdn.com/573/Osey-Ramulamma-From-Mysaa-Telugu-2026-20261121182119-150x150.jpg","language":"telugu","year":"2026","play_count":"26034","explicit_content":"0","more_info":{"music":"Vandemataram Srinivas, Jakes Bejoy","album_id":"83916892","album":"Osey Ramulamma (From &quot;Mysaa&quot;)","duration":"210","artistMap":{"primary_artists":[{"id":"456809","name":"Vandemataram Srinivas","image":"https://c.saavncdn.com/artists/Vandemataram_Srinivas_000_20220913110808_150x150.jpg","perma_url":"https://www.jiosaavn.com/artist/vandemataram-srinivas-songs/igkOW25Kxio_"}]},"release_date":"2026-11-20"}},{"id":"lD-OEesz","title":"Pichhi Premalo (From &quot;Alias Rukmini&quot;)","subtitle":"Vijai Bulganin, Krishna Kanth - Pichhi Premalo (From &quot;Alias Rukmini&quot;)","type":"song","perma_url":"https://www.jiosaavn.com/song/pichhi-premalo-from-alias-rukmini/HCxGfjFVREk","image":"https://c.saavncdn.com/686/Pichhi-Premalo-From-Alias-Rukmini-Telugu-2026-20261113084103-150x150.jpg","language":"telugu","year":"2026","play_count":"67178","explicit_content":"0","more_info":{"music":"Vijai Bulganin","album_id":"83573762","album":"Pichhi Premalo (From &quot;Alias Rukmini&quot;)","duration":"226","artistMap":{"primary_artists":[{"id":"3518493","name":"Vijai Bulganin","image":"https://c.saavncdn.com/artists/Vijai_Bulganin_000_20230316093009_150x150.jpg","perma_url":"https://www.jiosaavn.com/artist/vijai-bulganin-songs/P78Bei47APc_"},{"id":"824408","name":"Krishna Kanth","image":"https://c.saavncdn.com/artists/Krishna_Kanth_003_20260121134649_150x150.jpg","perma_url":"https://www.jiosaavn.com/artist/krishna-kanth-songs/WF5TqWhiG,M_"}]},"release_date":"2026-11-13"}},{"id":"83986964","title":"Aakasamlo Oka Tara","subtitle":"","type":"album","perma_url":"https://www.jiosaavn.com/album/aakasamlo-oka-tara/n7MsuGAcWJ8_","image":"https://c.saavncdn.com/869/Aakasamlo-Oka-Tara-Telugu-2026-20261121221034-150x150.jpg","language":"telugu","year":"","play_count":"","explicit_content":"0","more_info":{"song_count":"0","release_date":"2026-11-21","artistMap":{"primary_artists":[]}}},{"id":"83512753","title":"Itllu Arjuna","subtitle":"","type":"album","perma_url":"https://www.jiosaavn.com/album/itllu-arjuna/212Dgpdlabc_","image":"https://c.saavncdn.com/303/Itllu-Arjuna-Telugu-2026-20261112131035-150x150.jpg","language":"telugu","year":"","play_count":"","explicit_content":"0","more_info":{"song_count":"0","release_date":"2026-11-12","artistMap":{"primary_artists":[]}}}],"new_trending":[{"id":"83986964","title":"Aakasamlo Oka Tara","subtitle":"","type":"album","perma_url":"https://www.jiosaavn.com/album/aakasamlo-oka-tara/n7MsuGAcWJ8_","image":"https://c.saavncdn.com/869/Aakasamlo-Oka-Tara-Telugu-2026-20261121221034-150x150.jpg?bch=498782","language":"telugu","year":"","play_count":"","explicit_content":"0","more_info":{"release_date":"2026-11-21","song_count":"9","artistMap":{"primary_artists":[]}}},{"id":"82268631","title":"Veera Veera (From \"O.M: Operation Mole - Telugu\")","subtitle":"","type":"album","perma_url":"https://www.jiosaavn.com/album/veera-veera-from-o.m-operation-mole-telugu/9w-h0Mzb1TE_","image":"https://c.saavncdn.com/993/Veera-Veera-From-O-M-Operation-Mole-Telugu-Telugu-2026-20261117163235-150x150.jpg?bch=498782","language":"telugu","year":"","play_count":"","explicit_content":"0","more_info":{"release_date":"2026-10-19","song_count":"1","artistMap":{"primary_artists":[]}}}],"charts":[{"id":"1134643225","title":"Telugu: India Superhits Top 50","type":"playlist","count":50},{"id":"1134548194","title":"India Superhits Top 50","type":"playlist","count":50},{"id":"951897805","title":"Most Searched Songs - Telugu","type":"playlist"}]}
"""#
    /// A JioSaavn chart list.
    static let jioChart = #"""
{"id":"1134643225","title":"Telugu: India Superhits Top 50","list":[{"id":"4PYZR6Ng","title":"Endhayya Saami","subtitle":"Ajay-Atul, Ajay Gogavale, Shweta Mohan, Ramajogayya Sastry - Ranabaali - Telugu","type":"song","perma_url":"https://www.jiosaavn.com/song/endhayya-saami/RDgyayYGeVQ","image":"https://c.saavncdn.com/172/Ranabaali-Hindi-Telugu-2026-20261014171014-150x150.jpg","language":"telugu","year":"2026","play_count":"3471421","explicit_content":"0","more_info":{"music":"Ajay-Atul","album_id":"81994977","album":"Ranabaali - Telugu","duration":"328","artistMap":{"primary_artists":[{"id":"459381","name":"Ajay-Atul","image":"https://c.saavncdn.com/artists/Ajay_Atul_003_20230228105414_150x150.jpg","perma_url":"https://www.jiosaavn.com/artist/ajay-atul-songs/LZ,JHzGbLkY_"},{"id":"459383","name":"Ajay Gogavale","image":"https://c.saavncdn.com/artists/Ajay_Gogavale_001_20230228104016_150x150.jpg","perma_url":"https://www.jiosaavn.com/artist/ajay-gogavale-songs/PAVCZrf3,G4_"}]},"release_date":"2026-10-14"}},{"id":"KLmOLxT3","title":"Basinga Balaalu","subtitle":"Kalyan Keys, Swamy Naresh, Srinidhi Nerella - Basinga Balaalu","type":"song","perma_url":"https://www.jiosaavn.com/song/basinga-balaalu/OyQGfjhIYwA","image":"https://c.saavncdn.com/420/Basinga-Balaalu-Telugu-2026-20260612154016-150x150.jpg","language":"telugu","year":"2026","play_count":"9399564","explicit_content":"0","more_info":{"music":"Kalyan Keys","album_id":"76795723","album":"Basinga Balaalu","duration":"249","artistMap":{"primary_artists":[{"id":"9944342","name":"Kalyan Keys","image":"https://c.saavncdn.com/artists/Kalyan_Keys_000_20260530145359_150x150.jpg","perma_url":"https://www.jiosaavn.com/artist/kalyan-keys-songs/sV0Drw5hfmI_"},{"id":"25910734","name":"Swamy Naresh","image":"https://c.saavncdn.com/artists/Swamy_Naresh_000_20260805094847_150x150.jpg","perma_url":"https://www.jiosaavn.com/artist/swamy-naresh-songs/hPwTZ1FqfoA_"}]},"release_date":"2026-06-12"}}]}
"""#
    /// Deezer's "Top Brazil" playlist tracks.
    static let deezerPlaylist = #"""
{"data":[{"id":4337389322,"title":"Pós (Ao Vivo)","duration":175,"rank":988594,"explicit_lyrics":false,"link":"https://www.deezer.com/track/4337389322","artist":{"id":172071177,"name":"Felipe e Rodrigo","picture_medium":"https://cdn-images.dzcdn.net/images/artist/8a708000573bc036a557771329d13932/250x250-000000-80-0-0.jpg"},"album":{"id":1117358492,"title":"Pós (Ao Vivo)","cover_medium":"https://cdn-images.dzcdn.net/images/cover/4c07cc728fd1531094bbf11235afef34/250x250-000000-80-0-0.jpg","cover_big":"https://cdn-images.dzcdn.net/images/cover/4c07cc728fd1531094bbf11235afef34/500x500-000000-80-0-0.jpg"}},{"id":4179195042,"title":"Postinho de Gasolina","duration":143,"rank":977199,"explicit_lyrics":false,"link":"https://www.deezer.com/track/4179195042","artist":{"id":9719682,"name":"João Gustavo e Murilo","picture_medium":"https://cdn-images.dzcdn.net/images/artist/fecadb77d38e0c23ad61d03d76be4029/250x250-000000-80-0-0.jpg"},"album":{"id":1039054582,"title":"Postinho de Gasolina","cover_medium":"https://cdn-images.dzcdn.net/images/cover/73162157e1fc438ddfc4273aaae892c6/250x250-000000-80-0-0.jpg","cover_big":"https://cdn-images.dzcdn.net/images/cover/73162157e1fc438ddfc4273aaae892c6/500x500-000000-80-0-0.jpg"}}]}
"""#
    /// YouTube Music charts page for India: the language and top-artist carousels.
    static let ytmChartsIndia = #"""
{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Languages"}]}}},"contents":[{"musicTwoRowItemRenderer":{"thumbnailRenderer":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://yt3.googleusercontent.com/5_xzqaMZ2R7U5xogg71R1k-JA6VyuJRaNQ2EwdNxU_Os2Damqe_oNiVuwWgcZDPE0Hfx42giIBg=s576","width":576,"height":576}]},"thumbnailCrop":"MUSIC_THUMBNAIL_CROP_UNSPECIFIED","thumbnailScale":"MUSIC_THUMBNAIL_SCALE_ASPECT_FILL"}},"aspectRatio":"MUSIC_TWO_ROW_ITEM_THUMBNAIL_ASPECT_RATIO_SQUARE","title":{"runs":[{"text":"Top Weekly Videos International","navigationEndpoint":{"browseEndpoint":{"browseId":"VLPL4fGSI1pDJn49TUu37nJoN2QTeYuRwmNv","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}}}}]},"subtitle":{"runs":[{"text":"Chart"},{"text":" \u2022 "},{"text":"YouTube Charts","navigationEndpoint":{"browseEndpoint":{"browseId":"FEmusic_charts","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_USER_CHANNEL"}}}}}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"VLPL4fGSI1pDJn49TUu37nJoN2QTeYuRwmNv","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}}}}},{"musicTwoRowItemRenderer":{"thumbnailRenderer":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://yt3.googleusercontent.com/HriZEsaBA_HMlJdcoU2pEz159dTx43Q2U-79xlCW6BJMpaqzvDfnmN_jCsx70JJO1CbNIVvrHEo=s576","width":576,"height":576}]},"thumbnailCrop":"MUSIC_THUMBNAIL_CROP_UNSPECIFIED","thumbnailScale":"MUSIC_THUMBNAIL_SCALE_ASPECT_FILL"}},"aspectRatio":"MUSIC_TWO_ROW_ITEM_THUMBNAIL_ASPECT_RATIO_SQUARE","title":{"runs":[{"text":"Top Weekly Videos Punjabi","navigationEndpoint":{"browseEndpoint":{"browseId":"VLPL4fGSI1pDJn5JXkyIohg2RstsbL2SnRew","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}}}}]},"subtitle":{"runs":[{"text":"Chart"},{"text":" \u2022 "},{"text":"YouTube Charts","navigationEndpoint":{"browseEndpoint":{"browseId":"FEmusic_charts","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_USER_CHANNEL"}}}}}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"VLPL4fGSI1pDJn5JXkyIohg2RstsbL2SnRew","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}}}}}],"itemSize":"COLLECTION_STYLE_ITEM_SIZE_MEDIUM"}},{"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Top artists"}]}}},"contents":[{"musicResponsiveListItemRenderer":{"thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://lh3.googleusercontent.com/_wPXKRCH5rAX8AK1kJZ1bNhSpNyyEgBRNmREdPmLbvTy3sX_ldiKMRYFc5uChygV_KRx_SDrH1KgUifk=w60-h60-p-l90-rj","width":60,"height":60},{"url":"https://lh3.googleusercontent.com/_wPXKRCH5rAX8AK1kJZ1bNhSpNyyEgBRNmREdPmLbvTy3sX_ldiKMRYFc5uChygV_KRx_SDrH1KgUifk=w120-h120-p-l90-rj","width":120,"height":120}]},"thumbnailCrop":"MUSIC_THUMBNAIL_CROP_CIRCLE","thumbnailScale":"MUSIC_THUMBNAIL_SCALE_ASPECT_FILL"}},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Alka Yagnik"}]},"displayPriority":"MUSIC_RESPONSIVE_LIST_ITEM_COLUMN_DISPLAY_PRIORITY_HIGH"}},{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"2.34M subscribers"}]},"displayPriority":"MUSIC_RESPONSIVE_LIST_ITEM_COLUMN_DISPLAY_PRIORITY_HIGH"}}],"flexColumnDisplayStyle":"MUSIC_RESPONSIVE_LIST_ITEM_FLEX_COLUMN_DISPLAY_STYLE_TWO_LINE_STACK","navigationEndpoint":{"browseEndpoint":{"browseId":"UCptBkLZ6XRxoyn8SkUMc_Iw","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}},"itemHeight":"MUSIC_RESPONSIVE_LIST_ITEM_HEIGHT_MEDIUM_COMPACT","customIndexColumn":{"musicCustomIndexColumnRenderer":{"text":{"runs":[{"text":"1"}]},"icon":{"iconType":"ARROW_CHART_NEUTRAL"},"iconColorStyle":"CUSTOM_INDEX_COLUMN_ICON_COLOR_STYLE_GREY"}}}},{"musicResponsiveListItemRenderer":{"thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://yt3.googleusercontent.com/coesV4OVEVkua3_wJG-2BVvTc95yHF9sS1W6mOAtl4-vvTjQb250Hy_nVlfvudmEugb7_k05vhY9aJm4=w60-h60-l90-rj","width":60,"height":60},{"url":"https://yt3.googleusercontent.com/coesV4OVEVkua3_wJG-2BVvTc95yHF9sS1W6mOAtl4-vvTjQb250Hy_nVlfvudmEugb7_k05vhY9aJm4=w120-h120-l90-rj","width":120,"height":120}]},"thumbnailCrop":"MUSIC_THUMBNAIL_CROP_CIRCLE","thumbnailScale":"MUSIC_THUMBNAIL_SCALE_ASPECT_FILL"}},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Udit Narayan"}]},"displayPriority":"MUSIC_RESPONSIVE_LIST_ITEM_COLUMN_DISPLAY_PRIORITY_HIGH"}},{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"3.98M subscribers"}]},"displayPriority":"MUSIC_RESPONSIVE_LIST_ITEM_COLUMN_DISPLAY_PRIORITY_HIGH"}}],"flexColumnDisplayStyle":"MUSIC_RESPONSIVE_LIST_ITEM_FLEX_COLUMN_DISPLAY_STYLE_TWO_LINE_STACK","navigationEndpoint":{"browseEndpoint":{"browseId":"UC13ToEQgfmTe8_GW19LYtCg","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}},"itemHeight":"MUSIC_RESPONSIVE_LIST_ITEM_HEIGHT_MEDIUM_COMPACT","customIndexColumn":{"musicCustomIndexColumnRenderer":{"text":{"runs":[{"text":"2"}]},"icon":{"iconType":"ARROW_CHART_NEUTRAL"},"iconColorStyle":"CUSTOM_INDEX_COLUMN_ICON_COLOR_STYLE_GREY"}}}}],"itemSize":"COLLECTION_STYLE_ITEM_SIZE_MEDIUM","numItemsPerColumn":"4"}}]}}}}]}}}
"""#

    static func object(_ s: String) throws -> [String: Any] {
        guard let d = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { throw MusicError.network("bad fixture") }
        return d
    }
}

private final class HomeStub: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private let handler: @Sendable (URLRequest) -> (Int, String)
    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) { self.handler = handler }
    var requests: [URLRequest] { lock.withLock { seen } }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { seen.append(request) }
        let (code, body) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

private func track(_ title: String, artist: String = "A", album: String? = nil, uid: String = UUID().uuidString) -> MusicTrack {
    MusicTrack(id: uid, providerID: "x", title: title, durationMs: 180_000, artists: [MusicArtistRef(id: "", name: artist)],
               album: album.map { MusicAlbumRef(id: "a", title: $0) })
}

private let art = [MusicThumbnail(url: "https://example.com/c.jpg", width: 300, height: 300)]

// MARK: region to sources

@Suite struct HomeRegionSourcesTests {
    @Test func appleFollowsAnyCountryAndNoSourceFollowsWorldwide() {
        for c in MusicDiscoveryRegion.supported {
            #expect(MusicRegionalSources.followsRegion(providerID: ITunesChartsDiscoveryProvider.id, region: c.code), Comment(rawValue: c.code))
            #expect(MusicRegionalSources.youTubeChartsCountry(for: c.code) == c.code.uppercased(), Comment(rawValue: c.code))
            #expect(!MusicRegionalSources.followsRegion(providerID: DeezerDiscoveryProvider.id, region: c.code), "Deezer has one chart, the worldwide one: it never claims a country")
        }
        #expect(MusicRegionalSources.followsRegion(providerID: JioSaavnDiscoveryProvider.id, region: "in"))
        #expect(!MusicRegionalSources.followsRegion(providerID: JioSaavnDiscoveryProvider.id, region: "us"))
        #expect(!MusicRegionalSources.followsRegion(providerID: "discover-audius", region: "in"))
        for id in [ITunesChartsDiscoveryProvider.id, DeezerDiscoveryProvider.id, JioSaavnDiscoveryProvider.id, "discover-audius"] {
            #expect(!MusicRegionalSources.followsRegion(providerID: id, region: MusicDiscoveryRegion.worldwide), "\(id) must not answer for no country")
        }
        #expect(MusicRegionalSources.youTubeChartsCountry(for: "zzz") == nil)
    }

    @Test func theCountryListIsEverySystemCountryAndWorldwideIsNotOneOfThem() {
        #expect(MusicDiscoveryRegion.supported.count > 200, "every country, not a short list")
        #expect(MusicDiscoveryRegion.supported.allSatisfy { $0.code.count == 2 && !$0.name.isEmpty })
        #expect(!MusicDiscoveryRegion.supported.contains { $0.code.isEmpty })
        #expect(MusicDiscoveryRegion.name(MusicDiscoveryRegion.worldwide) == "Worldwide")
        #expect(MusicDiscoveryRegion.name("jp") == Locale.current.localizedString(forRegionCode: "JP"))
    }

    @Test func titlesSayWorldwideWhenNoCountryIsChosen() {
        #expect(MusicRegionalSources.chartsTitle(region: "") == "Top charts worldwide")
        #expect(MusicRegionalSources.topSongsTitle(region: "", language: nil) == "Top songs worldwide")
        #expect(MusicRegionalSources.topSongsTitle(region: "", language: .hindi) == "Top Hindi songs worldwide")
        #expect(MusicRegionalSources.newTitle(region: "", language: nil) == "New worldwide")
    }

    @Test func jioSaavnLanguagesAreThePersonsOwnOrTheDevicesInIndia() {
        // Changed with the hardcode removal: the old fixed default of Hindi, Telugu and Tamil is gone; with no history only the device's own languages are asked for.
        #expect(MusicRegionalSources.jioSaavnLanguages(region: "in", wanted: [], device: ["en-IN", "te-IN", "hi-IN"]) == [.telugu, .hindi])
        #expect(MusicRegionalSources.jioSaavnLanguages(region: "in", wanted: [], device: ["en-IN"]).isEmpty)
        #expect(MusicRegionalSources.jioSaavnLanguages(region: "in", wanted: [.telugu, .korean]) == [.telugu])
        #expect(MusicRegionalSources.jioSaavnLanguages(region: "us", wanted: []).isEmpty)
        #expect(MusicRegionalSources.jioSaavnLanguages(region: "us", wanted: [.tamil]) == [.tamil])
    }

    @Test func shelfTitlesNameTheCountryAndTheLanguage() {
        #expect(MusicRegionalSources.topSongsTitle(region: "in", language: nil) == "Top songs in India")
        #expect(MusicRegionalSources.topSongsTitle(region: "in", language: .telugu) == "Top Telugu songs in India")
        #expect(MusicRegionalSources.newTitle(region: "in", language: nil) == "New in India")
        #expect(MusicRegionalSources.newTitle(region: "in", language: .tamil) == "New in Tamil")
    }

    @Test func regionalShelvesAreOrderedSongsNewThenChartsThenAlbums() {
        func s(_ id: String) -> MusicBrowseSection { MusicBrowseSection(id: id, title: id, items: []) }
        let shuffled = ["itunes-albums-in", "ytm-chart-videos", "deezer-top-br", "jiosaavn-albums-mix", "jiosaavn-top-mix", "ytm-chart-artists", "jiosaavn-new-mix", "itunes-songs-in", "other"].map(s)
        #expect(MusicHomeRegionalOrder.ordered(shuffled).map(\.id) == ["itunes-songs-in", "jiosaavn-new-mix", "jiosaavn-top-mix", "deezer-top-br", "ytm-chart-artists", "ytm-chart-videos", "jiosaavn-albums-mix", "itunes-albums-in", "other"])
    }

    @Test func youTubeChartShelvesAreRenamedWithTheCountryAndCutToALanguage() {
        #expect(MusicHomeRegionalOrder.youTubeChartTitle("Top artists", country: "India", languageName: nil)?.title == "Top artists in India")
        #expect(MusicHomeRegionalOrder.youTubeChartTitle("Languages", country: "India", languageName: "Telugu")?.id == "ytm-chart-language")
        #expect(MusicHomeRegionalOrder.youTubeChartTitle("Top artists", country: "India", languageName: "Telugu") == nil)
        #expect(MusicHomeRegionalOrder.youTubeChartTitle("Weekly top podcast shows", country: "India", languageName: nil) == nil)
    }

    @Test func theChartsPageParsesIndiasLanguageAndArtistShelves() throws {
        let shelves = YTMHomeParser.parseExplore(try HomeRegionFixtures.object(HomeRegionFixtures.ytmChartsIndia))
        #expect(shelves.map(\.title) == ["Languages", "Top artists"])
        #expect(shelves[0].items.count == 2)
        if case .playlist(let p) = shelves[0].items[0] { #expect(p.name.hasPrefix("Top Weekly Videos")) } else { Issue.record("not a playlist") }
    }

    @Test func theChartsRequestCarriesTheCountryAsASelectedValue() async throws {
        let stub = HomeStub { _ in (200, "{}") }
        let client = YouTubeMusicClient(http: MusicHTTP(transport: stub))
        _ = try await client.browse("FEmusic_charts", selectedValues: ["IN"])
        let body = stub.requests.first { $0.url?.path.hasSuffix("/browse") == true }?.httpBody
        let json = try #require(body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(json["browseId"] as? String == "FEmusic_charts")
        #expect((json["formData"] as? [String: Any])?["selectedValues"] as? [String] == ["IN"])
    }

    @Test func deezerAnswersEveryCountryWithItsOneWorldwideChartLabelledGlobal() async throws {
        let stub = HomeStub { _ in (200, #"{"data": []}"#) }
        let deezer = DeezerDiscoveryProvider(http: MusicHTTP(transport: stub))
        for code in ["br", "us", "in", ""] {
            let sections = (try? await deezer.featured(region: code)) ?? []
            #expect(sections.allSatisfy { $0.scope == .global }, "\(code): Deezer's chart is never shown as a country's")
        }
        #expect(!stub.requests.contains { ($0.url?.path ?? "").hasPrefix("/playlist/") }, "no per-country playlist is asked for: the app keeps no table of them")
    }
}

// MARK: JioSaavn parsers

@Suite struct HomeJioSaavnTests {
    @Test func theNewSongsAreCutToTheLanguagesAsked() throws {
        let launch = try HomeRegionFixtures.object(HomeRegionFixtures.jioLaunch)
        let te = JioSaavnDiscoveryProvider.newSongs(in: launch, languages: [.telugu])
        #expect(te.count == 3 && te[0].title.contains("Diviki Diviki") && te[0].providerID == "jiosaavn" && te[0].directStreams == nil)
        #expect(JioSaavnDiscoveryProvider.newSongs(in: launch, languages: [.hindi]).isEmpty)
        let albums = JioSaavnDiscoveryProvider.newAlbums(in: launch, languages: [.telugu, .hindi])
        #expect(albums.count == 3 && Set(albums.map(\.id)).count == albums.count)
    }

    @Test func theChartIsFoundByItsLanguageOrByTheCountryName() throws {
        let launch = try HomeRegionFixtures.object(HomeRegionFixtures.jioLaunch)
        // The names come from the saved reply itself: the language list is "<Language>: <list name>", the country list is the shared list name.
        let titles = launch.array("charts").compactMap { $0.str("title") }
        let telugu = JioSaavnDiscoveryProvider.chart(in: launch, language: .telugu)?.title
        let country = JioSaavnDiscoveryProvider.chart(in: launch, language: nil)?.title
        #expect(titles.contains(telugu ?? "?") && titles.contains(country ?? "?"))
        #expect(telugu?.hasPrefix("Telugu:") == true)
        #expect(telugu?.hasSuffix(country ?? "?") == true && country?.contains(":") == false)
        #expect(JioSaavnDiscoveryProvider.chart(in: launch, language: .tamil) == nil)
    }

    @Test func aSingleLanguageGivesTitlesThatNameItAndTheCountryGivesItsOwn() throws {
        let launch = try HomeRegionFixtures.object(HomeRegionFixtures.jioLaunch)
        let chart = JioSaavnProvider.songs(in: try HomeRegionFixtures.object(HomeRegionFixtures.jioChart))
        #expect(chart.count == 2)
        let te = JioSaavnDiscoveryProvider.sections(launch: launch, chartSongs: chart, region: "in", language: .telugu, languages: [.telugu])
        #expect(te.map(\.id) == ["jiosaavn-top-telugu", "jiosaavn-new-telugu", "jiosaavn-albums-telugu"])
        #expect(te.map(\.title) == ["Top Telugu songs in India", "New in Telugu", "New Telugu albums"])
        let mix = JioSaavnDiscoveryProvider.sections(launch: launch, chartSongs: chart, region: "in", language: nil, languages: [.hindi, .telugu, .tamil])
        #expect(mix.map(\.title) == ["Superhits in India", "New in India", "New albums in India"])
        let abroad = JioSaavnDiscoveryProvider.sections(launch: launch, chartSongs: chart, region: "us", language: .telugu, languages: [.telugu])
        #expect(abroad.first?.title == "Top Telugu songs")
    }

    @Test func noSongArrivesWithAStreamAndTheTitlesAreCleaned() throws {
        let launch = try HomeRegionFixtures.object(HomeRegionFixtures.jioLaunch)
        for t in JioSaavnDiscoveryProvider.newSongs(in: launch, languages: [.telugu]) {
            #expect(t.directStreams == nil)
            #expect(!t.title.contains("&quot;"))
        }
    }

    @Test func aRegionWithoutAJioSaavnListAsksNothing() async {
        let p = JioSaavnDiscoveryProvider(http: MusicHTTP(transport: HomeStub { _ in (500, "") }))
        await #expect(throws: MusicError.self) { _ = try await p.featured(region: "us") }
        await #expect(throws: MusicError.self) { _ = try await p.featured() }
    }

    @Test func theLanguageRequestSendsTheServicesOwnLanguageSetting() async throws {
        let stub = HomeStub { r in
            (200, r.url?.query?.contains("getLaunchData") == true ? HomeRegionFixtures.jioLaunch : HomeRegionFixtures.jioChart)
        }
        let p = JioSaavnDiscoveryProvider(http: MusicHTTP(transport: stub))
        let sections = try await p.featured(region: "in", languages: [.telugu])
        #expect(!sections.isEmpty)
        let launchRequest = try #require(stub.requests.first { $0.url?.query?.contains("getLaunchData") == true })
        #expect(launchRequest.value(forHTTPHeaderField: "Cookie") == "L=telugu")
    }
}

// MARK: language detection and the profile

@Suite struct HomeLanguageTests {
    @Test func theWritingSystemNamesTheLanguage() {
        let cases: [(String, MusicLanguage?)] = [
            ("ఎందయ్య సామి", .telugu), ("तू मिल जाए", .hindi), ("வீழா வீரா", .tamil), ("ಕನ್ನಡ ಹಾಡು", .kannada), ("മലയാളം പാട്ട്", .malayalam),
            ("আমার সোনার বাংলা", .bengali), ("ਪੰਜਾਬੀ ਗੀਤ", .punjabi), ("사랑해", .korean), ("ありがとう", .japanese), ("حبيبي", .arabic),
            ("Hello world", .latin), ("123 456", nil), ("", nil), ("ab", nil)
        ]
        for (text, want) in cases { #expect(MusicLanguageDetector.language(of: text) == want, Comment(rawValue: text)) }
    }

    @Test func aNativeTitleWithLatinWordsAroundItKeepsItsLanguage() {
        #expect(MusicLanguageDetector.language(of: "వీర వీర (From OM Chapter 1)") == .telugu)
        // The artist's name says where the artist is from, not the language of the song: a Latin title by an artist written in Telugu letters is not called Telugu.
        #expect(MusicLanguageDetector.language(of: track("Dilruba", artist: "అనిరుధ్", album: "Jailer")) == .latin)
        // The album's title counts as much as the song's own.
        #expect(MusicLanguageDetector.language(of: track("Dilruba", artist: "Anirudh", album: "జైలర్")) == .telugu)
        #expect(MusicLanguageDetector.language(of: track("Endhayya Saami", artist: "Ajay-Atul")) == .latin)
    }

    @Test func theProfileComesOnlyFromTheTracksGiven() {
        let tracks = (0..<6).map { track("తెలుగు పాట \($0)") } + (0..<2).map { track("हिन्दी गाना \($0)") } + (0..<5).map { track("English song \($0)") } + [track("123")]
        let p = MusicLanguageProfile.build(from: tracks)
        #expect(p.total == 13 && p.counts[.telugu] == 6 && p.counts[.hindi] == 2 && p.counts[.latin] == 5)
        #expect(p.found() == [.telugu, .hindi])
        #expect(p.found(minCount: 3) == [.telugu])
        #expect(p.dominant() == .telugu)
        #expect(MusicLanguageProfile.build(from: []).dominant() == nil)
    }

    @Test func noLanguageDominatesWhenTheMixIsEvenOrTooSmall() {
        let even = (0..<3).map { track("తెలుగు \($0)") } + (0..<3).map { track("हिन्दी \($0)") } + (0..<8).map { track("English \($0)") }
        #expect(MusicLanguageProfile.build(from: even).dominant() == nil)   // each is under 30 percent
        #expect(MusicLanguageProfile.build(from: [track("తెలుగు"), track("తెలుగు 2")]).dominant() == nil)   // fewer than three songs
        #expect(MusicLanguageProfile.build(from: (0..<9).map { track("English \($0)") }).dominant() == nil)   // Latin never leads
    }

    @Test func aRegionalListIsCutToTheLanguageByWritingSystem() {
        let s = MusicBrowseSection(id: "x", title: "T", items: [.track(track("తెలుగు పాట")), .track(track("English")), .track(track("हिन्दी गाना"))])
        #expect(MusicHomeLoaders.cut(s, to: .telugu)?.items.count == 1)
        #expect(MusicHomeLoaders.cut(s, to: nil)?.items.count == 3)
        #expect(MusicHomeLoaders.cut(s, to: .latin)?.items.count == 3)
        #expect(MusicHomeLoaders.cut(s, to: .korean) == nil)
    }
}

// MARK: cache

@Suite struct HomeCacheTests {
    private func key(_ region: String = "in", _ language: MusicLanguage? = nil, source: String = "ytmusic", discovery: [String] = ["discover-itunes-charts"], wanted: [MusicLanguage] = []) -> MusicHomeKey {
        MusicHomeKey(region: region, language: language, source: source, discovery: discovery, wanted: wanted)
    }

    @Test func eachRegionAndLanguageHasItsOwnCacheKey() {
        #expect(key("in").name != key("us").name)
        #expect(key("in", .telugu).name != key("in").name)
        #expect(key("in", .telugu).name != key("in", .tamil).name)
        #expect(key("IN").name == key("in").name)
        #expect(key("in", source: "ytmusic") != key("in", source: "audius"))
        #expect(key("in", discovery: ["b", "a"]) == key("in", discovery: ["a", "b"]))
    }

    @Test func theLanguagesInferredFromHistoryOnlyCountWhenNoLanguageIsChosen() {
        #expect(key("in", wanted: [.tamil, .telugu]).name == key("in", wanted: [.telugu, .tamil]).name)
        #expect(key("in", wanted: [.telugu]).name != key("in").name)
        #expect(key("in", .telugu, wanted: [.tamil]).name == key("in", .telugu).name)
    }

    @Test func theFileNameIsSafeAndDistinct() {
        let a = key("in", .telugu), b = key("in", .tamil)
        #expect(a.fileName != b.fileName && a.fileName.hasSuffix(".json"))
        #expect(!a.fileName.contains("/") && !a.fileName.contains("|") && !a.fileName.contains(".."))
    }

    @Test func aHomeIsFreshForTwentyMinutesStaleForAWeekAndThenUnusable() {
        let now = Date()
        #expect(MusicHomeCachePolicy.state(savedAt: now.addingTimeInterval(-60), now: now) == .fresh)
        #expect(MusicHomeCachePolicy.state(savedAt: now.addingTimeInterval(-3600), now: now) == .stale)
        #expect(MusicHomeCachePolicy.state(savedAt: now.addingTimeInterval(-8 * 86_400), now: now) == .unusable)
        #expect(MusicHomeCachePolicy.state(savedAt: now.addingTimeInterval(600), now: now) == .unusable)
    }

    @Test func aSnapshotSurvivesTheRoundTripThroughJSON() throws {
        let t = track("తెలుగు పాట")
        let al = MusicAlbum(id: "1", providerID: "jiosaavn", title: "Alb", thumbnails: art)
        let section = MusicBrowseSection(id: "s", title: "S", items: [.track(t), .album(al)])
        var snap = MusicHomeSnapshot(key: key().name, savedAt: Date(timeIntervalSince1970: 1_000))
        snap.regional = [MusicCachedSection(section)]
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(MusicHomeSnapshot.self, from: try enc.encode(snap))
        #expect(back.key == snap.key && back.regional.first?.section == section)
    }

    @Test func theCacheFileGoesToDiskAndComesBackByKey() throws {
        let k = key("in", .telugu, source: "test-\(UUID().uuidString)")
        let snap = MusicHomeSnapshot(key: k.name, savedAt: Date(), personalIncluded: false, regional: [MusicCachedSection(MusicBrowseSection(id: "r", title: "R", items: [.track(track("x"))]))])
        MusicHomeDisk.save(snap, key: k)
        defer { try? FileManager.default.removeItem(at: MusicHomeDisk.folder.appendingPathComponent(k.fileName)) }
        let loaded = try #require(MusicHomeDisk.load(k))
        #expect(loaded.regional.count == 1 && !loaded.personalIncluded)
        #expect(MusicHomeDisk.load(key("us", source: "none-\(UUID().uuidString)")) == nil)
    }

    @Test func theCountrysOwnAppleChartsNeverClaimALanguageTheyAreNotCutBy() {
        let songs = MusicBrowseSection(id: "itunes-songs-in", title: "x", items: [])
        let albums = MusicBrowseSection(id: "itunes-albums-in", title: "x", items: [])
        for lang in [MusicLanguage?.none, .telugu, .hindi] {
            #expect(MusicHomeLoaders.retitled(songs, region: "in", language: lang).title == "Top songs in India")
            #expect(MusicHomeLoaders.retitled(albums, region: "in", language: lang).title == "Top albums in India")
        }
    }
}
