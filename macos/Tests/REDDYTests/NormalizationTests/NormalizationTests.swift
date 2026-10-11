import Testing
import Foundation
@testable import REDDY

@Suite("Normalization & grouping") struct NormalizationTests {
    @Test func normalizesDiacriticsAndSymbols() {
        #expect(MetadataNormalizer.normalize("Café  Zürich HD!") == "cafe zurich hd")
        #expect(MetadataNormalizer.normalize("Sky Sports+") == "sky sports plus")      // "+" is meaningful, not noise
        #expect(MetadataNormalizer.normalize("Sky Sports") != MetadataNormalizer.normalize("Sky Sports+"))
    }

    @Test func qualityDetection() {
        #expect(MetadataNormalizer.qualityLabel("sky sports fhd") == "FHD")
        #expect(MetadataNormalizer.qualityLabel("sky sports 4k") == "4K")
        #expect(MetadataNormalizer.qualityLabel("sky sports") == nil)
        #expect(MetadataNormalizer.baseName("sky sports hd") == "sky sports")
    }

    @Test func separatorRowsAreDetected() {
        #expect(MetadataNormalizer.isSeparator("######## Bulgaria Channels ########"))
        #expect(MetadataNormalizer.isSeparator("=== NEWS ==="))
        #expect(!MetadataNormalizer.isSeparator("BBC News"))
        #expect(!MetadataNormalizer.isSeparator("E! Entertainment"))
    }

    @Test func countryPrefixIsConservative() {
        #expect(CategoryNormalizer.countryPrefix("BG: Bnt 1") == "BG")
        #expect(CategoryNormalizer.countryPrefix("DK | TV2") == "DK")
        #expect(CategoryNormalizer.countryPrefix("CNN International") == nil)
        #expect(CategoryNormalizer.countryPrefix("Sky: Cinema") == nil)
    }

    @Test func yearFromTitle() {
        #expect(MetadataNormalizer.year(from: "Movie Title (2019)") == 2019)
        #expect(MetadataNormalizer.year(from: "Movie [1994]") == 1994)
        #expect(MetadataNormalizer.year(from: "Movie 2049") == nil)
    }

    @Test func variantsGroupOnlyWithinSameSourceAndCategory() throws {
        let a = PlaylistSource(name: "A", type: .m3uRemote, baseURL: "x"), b = PlaylistSource(name: "B", type: .m3uRemote, baseURL: "y")
        let chans = [
            TestSupport.channel(a, "1", "Sky Sports", order: 1),
            TestSupport.channel(a, "2", "Sky Sports HD", order: 2),
            TestSupport.channel(a, "3", "Sky Sports FHD", order: 3),
            TestSupport.channel(a, "4", "Sky Sports", cat: "Other", order: 4),     // other category: not merged
            TestSupport.channel(b, "5", "Sky Sports HD", order: 5),                // other source: not merged
            TestSupport.channel(a, "6", "Sky Sports+", order: 6),                  // different channel
        ]
        let out = ChannelDeduplicator.group(chans)
        #expect(out.primaryIDs.contains(chans[2].id), "FHD should be the primary")
        #expect(!out.primaryIDs.contains(chans[0].id) && !out.primaryIDs.contains(chans[1].id))
        for i in [3, 4, 5] { #expect(out.primaryIDs.contains(chans[i].id)) }
        #expect(out.variants.filter { $0.channelID == chans[2].id }.count == 3)
        #expect(out.channels.count == chans.count, "nothing is ever deleted")
    }
}
