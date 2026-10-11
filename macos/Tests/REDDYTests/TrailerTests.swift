import Testing
import Foundation
@testable import REDDY

@Suite struct TrailerTests {
    @Test func cleansTitles() {
        #expect(TrailerLookup.cleanTitle("Maremma (2026) (Hindi)") == "maremma")
        #expect(TrailerLookup.cleanTitle("Amélie") == "amelie")
    }

    @Test func pickssMatchingPreview() {
        let json = #"{"results":[{"trackName":"Other Film","releaseDate":"2020-01-01T00:00:00Z","previewUrl":"https://v.example/a.m4v"},{"trackName":"Only Me","releaseDate":"2026-03-01T00:00:00Z","previewUrl":"https://v.example/b.m4v"}]}"#
        #expect(TrailerLookup.previewURL(from: Data(json.utf8), title: "Only Me (2026)", year: 2026)?.absoluteString == "https://v.example/b.m4v")
        #expect(TrailerLookup.previewURL(from: Data(json.utf8), title: "Only Me", year: 1990) == nil)     // wrong year
        #expect(TrailerLookup.previewURL(from: Data(json.utf8), title: "Missing", year: nil) == nil)
    }

    @Test func seasonNamesMatchTheSeries() {
        let json = #"{"results":[{"collectionName":"Dexter, Season 1","releaseDate":"2006-10-01T00:00:00Z","previewUrl":"https://v.example/d.m4v"}]}"#
        #expect(TrailerLookup.previewURL(from: Data(json.utf8), title: "Dexter", year: 2006) != nil)
    }

    @Test func youTubeKeys() {
        #expect(ProviderExtras.youTubeKey("dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(ProviderExtras.youTubeKey("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=3") == "dQw4w9WgXcQ")
        #expect(ProviderExtras.youTubeKey("https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(ProviderExtras.youTubeKey("not a video") == nil)
    }
}
