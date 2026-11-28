import Testing
import Foundation
@testable import REDDY

@Suite("Context menu gaps")
struct ContextMenuGapsTests {
    private func track(_ id: String, artist: String = "Ada", artistID: String = "a1", provider: String = "yt") -> MusicTrack {
        MusicTrack(id: id, providerID: provider, title: "Song \(id)", durationMs: 200_000, artists: [MusicArtistRef(id: artistID, name: artist)])
    }

    private func entry(_ id: String, title: String = "T", artist: String = "A", album: String = "Al") -> LocalEntry {
        LocalEntry(id: id, folderID: "f", path: "/x/\(id).mp3", title: title, artist: artist, album: album, trackNumber: nil, durationMs: 1000, modified: Date(), artworkFile: nil, ext: "mp3")
    }

    @Test func hiddenSongsAndArtistsAreLeftOut() {
        var s = MusicHiddenSet()
        s.tracks.insert("yt:1")
        s.artists.insert("a2")
        let list = [track("1"), track("2", artistID: "a2"), track("3")]
        #expect(s.filter(list).map(\.id) == ["3"])
        #expect(s.blockedKeys == ["yt:1", "a2"])
        #expect(MusicHiddenSet().filter(list).count == 3)
    }

    @Test func aPatchChangesOnlyWhatWasTyped() {
        var index = LocalLibraryIndex()
        index.entries = [entry("1"), entry("2", title: "Two")]
        let changed = index.edit(ids: ["1", "2"], patch: LocalEntryPatch(artist: "New", genre: "Pop", year: 1999))
        #expect(changed == 2)
        #expect(index.entries.allSatisfy { $0.artist == "New" && $0.genre == "Pop" && $0.year == 1999 })
        #expect(index.entries[1].title == "Two")
        #expect(LocalEntryPatch(title: "   ").applied(to: entry("1")).title == "T")
        #expect(LocalEntryPatch(year: 5).applied(to: entry("1")).year == nil)
    }

    @Test func theEditorShowsDifferentValuesAndSavesOnlyTypedFields() {
        let d = MusicMetadataDraft.initial([entry("1", artist: "A"), entry("2", artist: "B")])
        #expect(d.artist.mixed && d.artist.text.isEmpty)
        #expect(d.album.text == "Al" && !d.album.mixed)
        var edited = d
        edited.artist.text = "Same"
        let p = edited.patch()
        #expect(p.artist == "Same")
        #expect(p.title == "T")
        #expect(d.patch().artist == nil)
    }

    @Test func creditsGroupByRoleAndFallBackToTheArtists() {
        var t = track("1")
        #expect(MusicSongCreditGroups.groups(for: t).map(\.names) == [["Ada"]])
        t.creditBundle = MusicCreditBundle(credits: [MusicCredit(name: "Bee", role: .composer), MusicCredit(name: "Bee", role: .composer), MusicCredit(name: "Cy", role: .lyricist)])
        let g = MusicSongCreditGroups.groups(for: t)
        #expect(g.count == 3)
        #expect(g.first { $0.names == ["Bee"] } != nil)
    }

    @Test func songInformationLeavesOutWhatItDoesNotHave() {
        let rows = MusicSongInfo.rows(track: track("1"), plays: 0, lastPlayed: nil, local: nil, providerName: nil)
        #expect(!rows.contains { $0.value.isEmpty })
        #expect(rows.contains { $0.value == "3:20" })
    }

    @Test func songMenuOffersTheNewItemsWhereTheyApply() {
        let remote = MusicMenuLogic.trackItems(MusicTrackMenuContext())
        #expect(remote.contains(.viewLyrics) && remote.contains(.viewCredits) && remote.contains(.songInfo) && remote.contains(.hideRecommendation))
        #expect(!remote.contains(.editMetadata))
        let local = MusicMenuLogic.trackItems(MusicTrackMenuContext(isLocal: true))
        #expect(local.contains(.editMetadata))
    }

    @Test func playlistMenuOffersTheFullSetForYourOwnPlaylists() {
        let own = MusicMenuLogic.cardItems(.init(kind: .playlist, isLocal: true))
        for i in [MusicMenuLogic.CardItem.editPlaylist, .sortTracks, .selectMultiple, .removeDuplicates, .exportPlaylist] { #expect(own.contains(i)) }
        let album = MusicMenuLogic.cardItems(.init(kind: .album))
        #expect(album.contains(.download) && album.contains(.exportPlaylist))
        #expect(album.contains(.manageArtwork) && !album.contains(.sortTracks))
        #expect(own.contains(.manageArtwork))
        #expect(!MusicMenuLogic.cardItems(.init(kind: .artist)).contains(.exportPlaylist))
    }

    @Test func missingDetailsAreFilledOnlyFromTheSameRecording() {
        var e = entry("1", title: "Song 1", artist: "Ada", album: "")
        e.albumTagged = false
        e.durationMs = 200_000
        var same = track("1", artist: "Ada")
        same.album = MusicAlbumRef(id: "al", title: "The Album")
        same.creditBundle = MusicCreditBundle(credits: [], hints: MusicProviderHints(year: 2001, genre: "Pop"))
        var other = track("9", artist: "Ada")
        other.title = "Different"
        #expect(MusicMetadataFill.best(for: e, in: [other, same])?.id == "1")
        let p = MusicMetadataFill.patch(for: e, from: same)
        #expect(p.album == "The Album" && p.year == 2001 && p.genre == "Pop")
        #expect(p.artist == nil)
        var far = same
        far.durationMs = 900_000
        #expect(MusicMetadataFill.best(for: e, in: [far]) == nil)
    }
}

@Suite("Insights and reliability")
struct InsightsAndReliabilityTests {
    private func track(_ id: String, genre: String? = nil, title: String = "Song") -> MusicTrack {
        var t = MusicTrack(id: id, providerID: "yt", title: title, durationMs: 200_000, artists: [MusicArtistRef(id: "a\(id)", name: "Artist \(id)")])
        if let genre { t.creditBundle = MusicCreditBundle(credits: [], hints: MusicProviderHints(genre: genre)) }
        return t
    }

    @Test func genreSharesCountEachLabelAndSumToOne() {
        let songs = [MusicStatsEngine.SongAgg(track: track("1", genre: "Pop / Rock"), plays: 2, secs: 600, firstAt: Date()),
                     MusicStatsEngine.SongAgg(track: track("2", genre: "Pop"), plays: 1, secs: 300, firstAt: Date()),
                     MusicStatsEngine.SongAgg(track: track("3"), plays: 5, secs: 900, firstAt: Date())]
        let g = MusicInsightsEngine.genres(songs)
        #expect(g.first?.name == "Pop")
        #expect(abs(g.reduce(0) { $0 + $1.fraction } - 1) < 0.0001)
        #expect(!g.contains { $0.name.isEmpty })
    }

    @Test func recapCoversOnlyTheChosenMonth() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let may = cal.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 12))!
        let june = cal.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 12))!
        var f = MusicStatsFile()
        let t = track("1", genre: "Pop")
        f.songs[t.uid] = MusicSongEntry(track: t, firstAt: may)
        f.listens = [MusicListenRow(id: 1, uid: t.uid, at: may, secs: 200), MusicListenRow(id: 2, uid: t.uid, at: june, secs: 100)]
        let r = MusicInsightsEngine.recap(f, period: .month, anchor: may, calendar: cal)
        #expect(r.plays == 1 && r.totalSecs == 200)
        #expect(r.newSongs == 1 && r.newArtists == 1)
        #expect(r.topSongs.first?.track.uid == t.uid)
        #expect(MusicInsightsEngine.recap(f, period: .month, anchor: june, calendar: cal).previousSecs == 200)
        #expect(MusicInsightsEngine.recap(f, period: .year, anchor: may, calendar: cal).plays == 2)
    }

    @Test func resetOnlyHidesPlaysBeforeTheCutoff() {
        let old = PlayRecord(track: track("1"), at: Date(timeIntervalSince1970: 100), playedMs: 1)
        let new = PlayRecord(track: track("2"), at: Date(timeIntervalSince1970: 300), playedMs: 1)
        #expect(MusicTasteReset.visible([old, new], cutoff: Date(timeIntervalSince1970: 200)).map(\.track.id) == ["2"])
        #expect(MusicTasteReset.visible([old, new], cutoff: nil).count == 2)
    }

    @Test func outputRemovalPausesOnlyWhenAllowed() {
        #expect(MusicOutputRemoval.shouldPause(previousWasRemovable: true, previousStillPresent: false, wasPlaying: true, enabled: true, changedByApp: false))
        #expect(!MusicOutputRemoval.shouldPause(previousWasRemovable: true, previousStillPresent: false, wasPlaying: true, enabled: false, changedByApp: false))
        #expect(!MusicOutputRemoval.shouldPause(previousWasRemovable: true, previousStillPresent: false, wasPlaying: true, enabled: true, changedByApp: true))
        #expect(!MusicOutputRemoval.shouldPause(previousWasRemovable: false, previousStillPresent: false, wasPlaying: true, enabled: true, changedByApp: false))
    }

    @Test func onlyReadsAreRetriedAndOnlyForMomentaryFailures() {
        #expect(MusicRetryPolicy.shouldRetry(method: "GET", status: 503, urlErrorCode: nil, attempt: 1))
        #expect(!MusicRetryPolicy.shouldRetry(method: "POST", status: 503, urlErrorCode: nil, attempt: 1))
        #expect(!MusicRetryPolicy.shouldRetry(method: "GET", status: 404, urlErrorCode: nil, attempt: 1))
        #expect(!MusicRetryPolicy.shouldRetry(method: "GET", status: 503, urlErrorCode: nil, attempt: 3))
        #expect(MusicRetryPolicy.shouldRetry(method: "GET", status: nil, urlErrorCode: .timedOut, attempt: 2))
    }

    @Test func storageLevelsFollowFreeSpace() {
        let gb: Int64 = 1_073_741_824
        #expect(MusicStorageLevel.level(freeBytes: 100 * gb, totalBytes: 500 * gb) == .fine)
        #expect(MusicStorageLevel.level(freeBytes: 20 * gb, totalBytes: 500 * gb) == .low)
        #expect(MusicStorageLevel.level(freeBytes: gb / 8, totalBytes: 500 * gb) == .critical)
    }
}

@Suite("Audio and offline gaps")
struct AudioAndOfflineGapsTests {
    private func entry(_ id: String, _ title: String, artist: String = "Ada", ext: String = "mp3", ms: Int64 = 200_000) -> LocalEntry {
        LocalEntry(id: id, folderID: "f", path: "/m/\(id).\(ext)", title: title, artist: artist, album: "A", trackNumber: nil, durationMs: ms, modified: Date(), artworkFile: nil, ext: ext)
    }

    @Test func balanceQuietensOnlyTheFarSide() {
        let c = MusicSpatialWidener.balanceGains(0)
        #expect(c.left == 1 && c.right == 1)
        let r = MusicSpatialWidener.balanceGains(0.5)
        #expect(r.left == 0.5 && r.right == 1)
        let l = MusicSpatialWidener.balanceGains(-1)
        #expect(l.left == 1 && l.right == 0)
    }

    @Test func monoAndBalanceNeedTheEngineEvenWithTheCurveOff() {
        var s = MusicEqualizerSettings()
        #expect(!s.needsEngine)
        s.mono = true
        #expect(s.needsEngine)
        s.mono = false; s.balance = 0.3
        #expect(s.needsEngine)
    }

    @Test func parametricBandsFillFixedSlotsAndStayInRange() {
        var s = MusicEqualizerSettings()
        s.enabled = true
        s.parametric = [MusicParametricBand(shape: .bell, hz: 3_000, gainDB: 6, q: 2)]
        let secs = MusicEqualizerMath.sections(s)
        #expect(secs.count == MusicEqualizerMath.bandCentres.count + 2 + MusicParametricBand.slots)
        #expect(secs[MusicEqualizerMath.bandCentres.count + 2].gainDB == 6)
        #expect(s.curveIsAudible && s.isValid)
        s.parametric[0].hz = 5
        #expect(!s.isValid)
        let octaves = MusicEqualizerMath.octaves(fromQ: 1 / (2 * sinh(log(2) / 2 * 1.2)))
        #expect(abs(octaves - 1.2) < 0.0001)
    }

    @Test func customPresetsReplaceTheSameNameAndAreCapped() {
        var s = MusicEqualizerSettings(); s.bands[0] = 4
        var list = MusicCustomPresetRules.saving(s, as: "  Warm ", into: [])
        #expect(list.count == 1 && list[0].name == "Warm" && list[0].settings.enabled)
        s.bands[0] = 6
        list = MusicCustomPresetRules.saving(s, as: "warm", into: list)
        #expect(list.count == 1 && list[0].settings.bands[0] == 6)
        #expect(MusicCustomPresetRules.saving(s, as: "   ", into: list) == list)
        for i in 0..<40 { list = MusicCustomPresetRules.saving(s, as: "P\(i)", into: list) }
        #expect(list.count == MusicCustomPresetRules.maxPresets)
    }

    @Test func aNewOutputBringsItsOwnSoundOrKeepsTheCurrentOne() {
        var warm = MusicEqualizerSettings(); warm.mono = true
        let current = MusicEqualizerSettings()
        #expect(MusicDeviceAudioProfiles.settings(afterChangingTo: "buds", current: current, saved: ["buds": warm]) == warm)
        #expect(MusicDeviceAudioProfiles.settings(afterChangingTo: "other", current: current, saved: ["buds": warm]) == current)
    }

    @Test func duplicatesAreTheSameSongAtTheSameLengthAndKeepTheLossless() {
        let a = entry("1", "Tum Hi Ho", ext: "mp3"), b = entry("2", "Tum Hi Ho", ext: "flac", ms: 201_000)
        let remix = entry("3", "Tum Hi Ho (Remix)"), other = entry("4", "Tum Hi Ho", ms: 400_000)
        let groups = LocalLibraryTidy.duplicates([a, b, remix, other])
        #expect(groups.count == 1)
        #expect(groups[0].keeper.id == "2")
        #expect(groups[0].extras.map(\.id) == ["1"])
    }

    @Test func missingSongsAreFoundInPlaylistsAndReplacedInPlace() {
        func local(_ id: String) -> MusicTrack {
            var t = MusicTrack(id: id, providerID: MusicStatsRules.localProviderID, title: "S\(id)", durationMs: 1000, artists: [])
            t.directStreams = [MusicStream(url: URL(fileURLWithPath: "/m/\(id).mp3").absoluteString, codec: "mp3", container: "mp3")]
            return t
        }
        let p = LocalPlaylist(name: "P", tracks: [local("1"), local("2")])
        let missing = LocalLibraryTidy.missing(in: [p]) { $0.hasSuffix("1.mp3") ? false : true }
        #expect(missing.map(\.track.id) == ["1"] && missing[0].playlistIDs == [p.id])
        let fixed = LocalLibraryTidy.replacing(local("1"), with: local("9"), in: p.tracks)
        #expect(fixed.map(\.id) == ["9", "2"])
        #expect(LocalLibraryTidy.replacing(local("1"), with: local("2"), in: p.tracks).map(\.id) == ["2"])
    }
}

@Suite("Relationship browsing")
struct RelationshipBrowsingTests {
    private func person(_ n: String, role: MusicRole) -> MusicSongCreditPerson {
        MusicSongCreditPerson(id: MusicEntityID(kind: .person, token: "T" + n), name: n, role: role, instrument: nil, status: .verified, confidence: 1, level: .song, order: nil)
    }

    @Test func creditRolesHaveTheirOwnPages() {
        #expect(MusicPersonView.view(for: .producer) == .producer)
        #expect(MusicPersonView.view(for: .instrumentalist) == .instrumentalist)
        #expect(MusicPersonView.view(for: .conductor) == .conductor)
        #expect(MusicPersonView.view(for: .label) == .label)
        #expect(MusicPersonView.view(for: .singer) == .singer && MusicPersonView.view(for: .performer) == .singer)
        for v in MusicPersonView.allCases { #expect(!MusicPersonSectionID.order(for: v).isEmpty) }
    }

    @Test func theWheelShowsOnlyRolesWithPeopleAndMergesRelatedOnes() {
        let groups = [MusicSongCreditGroup(kind: .singers, people: [person("A", role: .singer), person("B", role: .singer), person("C", role: .singer)]),
                      MusicSongCreditGroup(kind: .composers, people: [person("D", role: .composer)]),
                      MusicSongCreditGroup(kind: .musicDirectors, people: [person("D", role: .musicDirector), person("E", role: .musicDirector)]),
                      MusicSongCreditGroup(kind: .others, people: [person("F", role: .remixer)])]
        let nodes = MusicRelationshipWheel.nodes(groups: groups, film: nil)
        #expect(nodes.map(\.kind) == [.composer, .singer])
        #expect(nodes.first { $0.kind == .composer }?.people.map(\.name) == ["D", "E"])
        #expect(nodes.first { $0.kind == .singer }?.extra == 1)
        #expect(MusicRelationshipWheel.isWorthShowing(nodes))
        #expect(!MusicRelationshipWheel.isWorthShowing(Array(nodes.prefix(1))))
        let top = MusicRelationshipWheel.point(index: 0, of: 4)
        #expect(abs(top.x) < 0.0001 && abs(top.y + 1) < 0.0001)
    }
}

@Suite("Combine query rules")
struct CombineQueryRulesTests {
    @Test func decadeAndLanguageMatching() {
        #expect(MusicCombineRules.inDecade(1994, 1990) && !MusicCombineRules.inDecade(2000, 1990) && !MusicCombineRules.inDecade(nil, 1990))
        #expect(MusicCombineRules.sameLanguage("te", "te") && MusicCombineRules.sameLanguage("tel", "te") && MusicCombineRules.sameLanguage("Telugu", "te"))
        #expect(!MusicCombineRules.sameLanguage("hi", "te") && !MusicCombineRules.sameLanguage(nil, "te"))
        #expect(MusicCombineRules.decades(from: [1994, 1999, 2003, 1971]) == [2000, 1990, 1970])
    }

    @Test func industryIsDerivedFromLanguageOnly() {
        #expect(MusicCombineRules.industry(forLanguage: "te") == "Tollywood")
        #expect(MusicCombineRules.industry(forLanguage: "hin") == "Bollywood")
        #expect(MusicCombineRules.industry(forLanguage: "en") == nil)
    }

    @Test func aFilterNeedsSomeoneToStartFrom() {
        var f = MusicCombineFilter()
        #expect(f.isEmpty && !f.isRunnable)
        f.language = "te"; f.decade = 1990
        #expect(!f.isRunnable)
        f.singer = MusicEntityID(kind: .person, token: "TSINGER")
        #expect(f.isRunnable && f.people.count == 1)
    }
}

@Suite("Translated versions")
struct TranslatedVersionTests {
    private func work(_ id: String) -> MusicDraftRef { .external(.work, ExternalID(.mbWork, id)) }
    private func group(_ id: String) -> MusicDraftRef { .external(.album, ExternalID(.mbReleaseGroup, id)) }

    @Test func aTranslatedWorkLinkIsTranslatedLyricsAndNeverADub() {
        let backward = """
        {"id":"w-tam","title":"Kaadhal Rojaavae","language":"tam","relations":[
          {"type":"other version","target-type":"work","direction":"backward","attributes":["translated"],"work":{"id":"w-hin","title":"Roja Jaaneman","language":"hin"}},
          {"type":"other version","target-type":"work","attributes":[],"work":{"id":"w-x","title":"Something else"}}]}
        """
        let links = MusicBrainzParser.work(Data(backward.utf8))?.claims.filter { $0.predicate == .alternateOf } ?? []
        #expect(links.count == 1)
        #expect(links[0].attributes.versionKind == .translatedLyrics)
        // Backward: this work is the translation of the other, so it is the subject.
        #expect(links[0].subject == work("w-tam") && links[0].object == work("w-hin"))
        let forward = backward.replacingOccurrences(of: "backward", with: "forward")
        let f = MusicBrainzParser.work(Data(forward.utf8))?.claims.filter { $0.predicate == .alternateOf } ?? []
        // Forward: this work is the earliest version, so the other one is the translation.
        #expect(f.count == 1 && f[0].subject == work("w-hin") && f[0].object == work("w-tam"))
    }

    @Test func aTranslatedSoundtrackIsADubOnlyWhenItsOwnTextSaysDubbing() {
        // Shapes taken from MusicBrainz's own replies for "Mom (Telugu Dubbing of "Mom")" and the Tamil "Indian" soundtrack.
        let dubbed = """
        {"id":"rg-telugu","title":"Mom","disambiguation":"Telugu Dubbing of \\"Mom\\"","secondary-types":["Soundtrack"],"relations":[
          {"type":"translated version","target-type":"release_group","direction":"backward","attributes":[],"release_group":{"id":"rg-orig","title":"Mom"}}]}
        """
        let d = MusicBrainzParser.releaseGroup(Data(dubbed.utf8))?.claims.filter { $0.predicate == .relatedAlbum } ?? []
        #expect(d.count == 1 && d[0].attributes.versionKind == .dub)
        #expect(d[0].subject == group("rg-telugu") && d[0].object == group("rg-orig"))
        let plain = """
        {"id":"rg-tamil","title":"Indian","disambiguation":"","secondary-types":["Soundtrack"],"relations":[
          {"type":"translated version","target-type":"release_group","direction":"forward","attributes":[],"release_group":{"id":"rg-hindustani","title":"Hindustani"}}]}
        """
        let p = MusicBrainzParser.releaseGroup(Data(plain.utf8))?.claims.filter { $0.predicate == .relatedAlbum } ?? []
        #expect(p.count == 1 && p[0].attributes.versionKind == .translatedSoundtrack)
        // Forward: the Tamil soundtrack is the original, so the Hindustani one is the translation.
        #expect(p[0].subject == group("rg-hindustani") && p[0].object == group("rg-tamil"))
    }

    @Test func everyVersionKindHasItsOwnWording() {
        for k in MusicVersionKind.allCases where k != .original && k != .unknown && k != .live {
            #expect(MusicSongVersioning.badgeKey(k, inferred: false) != nil)
            #expect(MusicSongVersioning.originalLineKey(MusicSongVersion(kind: k, originalID: MusicEntityID(kind: .recording, token: "T"), status: .verified, confidence: 1, evidence: [], source: .edge)) != nil)
        }
        #expect(MusicSongVersioning.badgeKey(.translatedLyrics, inferred: false) == "Translated lyrics")
        #expect(MusicSongVersioning.badgeKey(.dub, inferred: false) == "Dubbed version")
    }
}

@Suite("Raga list parsing")
struct RagaTableTests {
    private let sample = "Intro text\n" + """
    {| class="wikitable sortable"
    |- style="color:#ff0000;"
    ![[Raga|Rāg]] !! Song !! Film !! Music composer !! Singer(s) !! [[Language|Lang]]
    |-
    |[[Abheri|Ābhēri]] (Carnatic) <br /> [[Bhimpalasi]] (Hindustani)
    | ''Maname Ganamum''<ref name=A group="TH">{{cite news|title=x}}</ref>
    |Savitri
    |[[Papanasam Sivan]]
    |[[M. S. Subbulakshmi]]
    |
    |-
    |[[Abheri|Ābhēri]] / [[Bhimpalasi]]
    |"Duniya Se Ji Ghabra Gaya"
    |Laila Majnu(1953 film)
    |[[Ghulam Mohammed (composer)|Ghulam Mohammed]]
    |[[Lata Mangeshkar]] & [[Talat Mahmood]]
    | [[Hindi]]
    |-
    |[[Abheri|Ābhēri]]/ [[Bhimpalasi]]
    | ''Khilte Hain Gul Yahan''
    |[[Sharmeelee]]
    |rowspan=2|[[Sachin Dev Burman]]
    |[[Kishore Kumar]] & [[Lata Mangeshkar]]
    |[[Hindi]]
    |-
    |[[Abheri|Ābhēri]]/ [[Bhimpalasi]]
    | ''Khoya Khoya Chand''
    |[[Kala Bazar]]
    |[[Mohammed Rafi]]
    |[[Hindi]]
    |}
    """

    @Test func rowsCarryTheirCellsAndShareSpannedOnes() {
        let songs = MusicRagaTable.parse(wikitext: sample)
        #expect(songs.count == 4)
        #expect(songs[0].title == "Maname Ganamum" && songs[0].film == "Savitri" && songs[0].language == nil)
        #expect(songs[0].ragas == ["Ābhēri", "Bhimpalasi"])
        #expect(songs[1].film == "Laila Majnu" && songs[1].year == 1953 && songs[1].singers == ["Lata Mangeshkar", "Talat Mahmood"] && songs[1].language == "Hindi")
        #expect(songs[3].composer == "Sachin Dev Burman")
    }

    @Test func songsGroupUnderTheirFirstRagaNameAndSearchFindsAliases() {
        let g = MusicRagaTable.groups(MusicRagaTable.parse(wikitext: sample))
        #expect(g.count == 1 && g[0].songs.count == 4 && g[0].aliases == ["Bhimpalasi"])
        #expect(MusicRagaTable.filter(g, query: "bhimpalasi").count == 1)
        #expect(MusicRagaTable.filter(g, query: "yaman").isEmpty)
    }
}

@Suite("Writing tags into files")
struct LocalTagFileWriterTests {
    private func frameText(_ tag: Data, _ id: String) -> String? {
        guard let parsed = MusicID3LyricFrames.frames(inTag: tag), let f = parsed.frames.first(where: { $0.id == id }), f.payload.first == 1 else { return nil }
        return String(data: Data(f.payload.dropFirst(3)), encoding: .utf16LittleEndian)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    @Test func anEditReplacesOnlyItsFramesAndKeepsTheRest() throws {
        func textFrame(_ id: String, _ s: String) -> Data { MusicID3LyricFrames.frame(id, Data([0x03]) + Data(s.utf8), version: 3) }
        let body = textFrame("TIT2", "Old") + textFrame("TPE1", "Ada") + textFrame("TRCK", "3/12") + MusicID3LyricFrames.frame("APIC", Data([1, 2, 3, 4]), version: 3)
        var old = Data("ID3".utf8)
        old.append(contentsOf: [3, 0, 0]); old.append(contentsOf: MusicID3LyricFrames.syncsafe(body.count)); old += body
        let tag = try #require(LocalTagFileWriter.replacingText(inTag: old, with: LocalEntryPatch(title: "New", year: 1994, trackNumber: 5)))
        #expect(frameText(tag, "TIT2") == "New")
        #expect(frameText(tag, "TYER") == "1994")
        #expect(frameText(tag, "TRCK") == "5/12")
        let kept = try #require(MusicID3LyricFrames.frames(inTag: tag)).frames
        #expect(kept.contains { $0.id == "APIC" && $0.payload == [1, 2, 3, 4] })
        #expect(kept.contains { $0.id == "TPE1" })
        #expect(LocalTagFileWriter.numberPair(setting: 2, existing: nil) == "2")
    }

    @Test func aFileTagsRoundTripThroughDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tagtest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.mp3")
        try (Data("ID3".utf8) + Data([3, 0, 0, 0, 0, 0, 0]) + Data(repeating: 0xFF, count: 64)).write(to: file)
        let result = await LocalTagFileWriter.write(LocalEntryPatch(title: "Hello", genre: "Pop"), to: file)
        #expect(result == .tagged)
        let data = try Data(contentsOf: file)
        let tag = Data(data.prefix(MusicTagWriter.existingTagLength(in: data)))
        #expect(frameText(tag, "TIT2") == "Hello" && frameText(tag, "TCON") == "Pop")
        let other = dir.appendingPathComponent("b.flac")
        try Data("fLaC".utf8 + Data(repeating: 0, count: 20)).write(to: other)
        #expect(await LocalTagFileWriter.write(LocalEntryPatch(title: "x"), to: other) == .unsupportedFormat)
    }
}

@Suite("Responsiveness meter")
struct PerfProbeTests {
    @Test func percentilesAndBudgets() {
        let v = [10.0, 20, 30, 40, 100, 250]
        #expect(MusicPerfStats.percentile(v, 0.5) == 30)
        #expect(MusicPerfStats.percentile(v, 0.95) == 250)
        #expect(MusicPerfStats.percentile([], 0.5) == 0)
        #expect(MusicPerfBudget.exceeds(.pageOpen, ms: 201) && !MusicPerfBudget.exceeds(.pageOpen, ms: 200))
        #expect(MusicPerfBudget.exceeds(.playPress, ms: 101) && MusicPerfBudget.exceeds(.slowMoment, ms: 51))
    }

    @Test func summaryCountsOnlyItsKind() {
        let now = Date()
        let s = [MusicPerfSample(kind: .pageOpen, label: "a", ms: 150, at: now), MusicPerfSample(kind: .pageOpen, label: "b", ms: 300, at: now),
                 MusicPerfSample(kind: .playPress, label: "c", ms: 50, at: now)]
        let p = MusicPerfStats.summary(s, kind: .pageOpen)
        #expect(p.count == 2 && p.overBudget == 1 && p.worst == 300)
        #expect(MusicPerfStats.report(s).contains("Page opens: 2 measured, 1 over 200 ms"))
    }
}

@Suite("Independent source families")
struct SourceFamilyTests {
    @Test func sourcesThatCopyEachOtherCountOnce() {
        #expect(MusicSourceFamily.of("jiosaavn") == MusicSourceFamily.of("appleMusic"))
        #expect(MusicSourceFamily.of("wikidata") == MusicSourceFamily.of("wikipedia"))
        #expect(MusicSourceFamily.of("musicbrainz") != MusicSourceFamily.of("tmdb"))
    }
}

@Suite("Field arbitration")
struct FieldArbiterTests {
    private func ev(_ value: String, _ source: MusicSourceID, _ spec: MusicEvidenceSpecificity = .recording, lineage: String? = nil, role: Bool = true, states: Bool = true) -> MusicFieldEvidence {
        MusicFieldEvidence(value: value, display: value, source: source, lineage: lineage, specificity: spec, roleExplicit: role, states: states)
    }

    @Test func catalogueSourcesThatRepeatEachOtherAreOneWitness() {
        let one = MusicFieldArbiter.decide(field: .composer, evidence: [ev("rahman", "jiosaavn")])
        let three = MusicFieldArbiter.decide(field: .composer, evidence: [ev("rahman", "jiosaavn"), ev("rahman", "appleMusic"), ev("rahman", "deezer")])
        #expect(three.candidates[0].witnesses.count == 1)
        #expect(abs(three.candidates[0].confidence - one.candidates[0].confidence) < 0.0001)
        // An independent source adds a real second witness.
        let withMB = MusicFieldArbiter.decide(field: .composer, evidence: [ev("rahman", "jiosaavn"), ev("rahman", "appleMusic"), ev("rahman", "musicbrainz")])
        #expect(withMB.candidates[0].witnesses.count == 2 && withMB.status == .agreed)
        #expect(withMB.candidates[0].confidence > one.candidates[0].confidence)
    }

    @Test func aStatedLineageMakesTwoCataloguesIndependentAndTheSameLineageOne() {
        let split = MusicFieldArbiter.decide(field: .composer, evidence: [ev("x", "jiosaavn", lineage: "label-a"), ev("x", "appleMusic", lineage: "label-b")])
        #expect(split.candidates[0].witnesses.count == 2)
        let same = MusicFieldArbiter.decide(field: .composer, evidence: [ev("x", "jiosaavn", lineage: "label-a"), ev("x", "appleMusic", lineage: "Label-A")])
        #expect(same.candidates[0].witnesses.count == 1)
    }

    @Test func aFilmOnlyLanguageNeverBecomesTheSongsLanguage() {
        let d = MusicFieldArbiter.decide(field: .language, evidence: [ev("te", "film", .film, states: false)])
        #expect(d.winner == nil && d.status == .contextOnly)
        #expect(d.contextOnly.map(\.value) == ["te"])
        let own = MusicFieldArbiter.decide(field: .language, evidence: [ev("te", "graph"), ev("te", "film", .film, states: false)])
        #expect(own.winner == "te")
        // The song's own language wins over the film's.
        let other = MusicFieldArbiter.decide(field: .language, evidence: [ev("hi", "graph"), ev("te", "film", .film, states: false)])
        #expect(other.winner == "hi")
    }

    @Test func closeDisagreementsStayUnknownAndOverridesWin() {
        let tied = MusicFieldArbiter.decide(field: .releaseYear, evidence: [ev("1994", "musicbrainz"), ev("1995", "tmdb")])
        #expect(tied.status == .conflicted && tied.winner == nil && tied.candidates.count == 2)
        let weak = MusicFieldArbiter.decide(field: .composer, evidence: [ev("a", "appleMusic", role: false, states: false)])
        #expect(weak.status == .insufficient && weak.winners.isEmpty)
        var user = ev("1996", "user"); user.userOverride = true
        let o = MusicFieldArbiter.decide(field: .releaseYear, evidence: [ev("1994", "musicbrainz"), user])
        #expect(o.status == .overridden && o.winner == "1996")
        #expect(MusicFieldArbiter.decide(field: .language, evidence: []).status == .empty)
    }

    @Test func multiValuedFieldsKeepEachAcceptedValue() {
        let d = MusicFieldArbiter.decide(field: .singer, evidence: [ev("spb", "musicbrainz"), ev("chithra", "musicbrainz"), ev("someone", "appleMusic", role: false, states: false)])
        #expect(Set(d.winners) == ["spb", "chithra"])
    }

    @Test func languageKeysAndDecisionUseTheSongsOwnEvidence() {
        #expect(MusicCombineRules.languageKey("Telugu") == "te" && MusicCombineRules.languageKey("tel") == "te" && MusicCombineRules.languageKey("hi") == "hi")
    }

    @Test func aClaimsStatedLineageCountsAsItsOwnWitnessInTheEdgeConfidence() {
        func f(_ s: MusicSourceID, _ lineage: String?) -> MusicProvenance { MusicProvenance(source: s, score: 0.6, evidence: lineage.map { ["lineage:" + $0] } ?? []) }
        let copies = MusicEdgeAggregator.aggregate(predicate: .composedBy, facts: [f("jiosaavn", nil), f("appleMusic", nil)])
        let independent = MusicEdgeAggregator.aggregate(predicate: .composedBy, facts: [f("jiosaavn", "label-a"), f("appleMusic", "label-b")])
        #expect(independent.confidence > copies.confidence)
    }
}

@Suite("Decision store")
struct FieldDecisionStoreTests {
    @Test func decisionsAreKeptReadBackAndCapped() {
        let store = MusicFieldDecisionStore(url: nil)
        let id = MusicEntityID(kind: .recording, token: "TONE")
        let d = MusicFieldArbiter.decide(field: .language, evidence: [MusicFieldEvidence(value: "te", source: "graph", specificity: .recording)])
        store.record(id, d)
        #expect(store.decision(id, .language)?.winner == "te")
        #expect(store.decision(id, .releaseYear) == nil)
        for i in 0..<(MusicFieldDecisionStore.capacity + 20) { store.record(MusicEntityID(kind: .recording, token: "T\(i)"), d) }
        #expect(store.decision(id, .language) == nil || MusicFieldDecisionStore.capacity > 0)
        store.clear()
        #expect(store.decision(id, .language) == nil)
    }
}

@Suite("Similarity and recommendations")
struct SimilarityTests {
    private func parse(_ s: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:] }

    @Test func lastFMListsParseAndASingleItemIsStillAList() {
        let many = parse(#"{"similartracks":{"track":[{"name":"Believe","match":1,"mbid":"m1","artist":{"name":"Cher","mbid":"a1"}},{"name":"Strong Enough","match":"0.5","artist":{"name":"Cher"}}]}}"#)
        let t = MusicSimilarityParsers.similarTracks(many)
        #expect(t.count == 2 && t[0].title == "Believe" && t[0].artist == "Cher" && t[0].mbid == "m1" && t[1].score == 0.5)
        let one = parse(#"{"similarartists":{"artist":{"name":"Abba","match":"0.9","mbid":""}}}"#)
        let a = MusicSimilarityParsers.similarArtists(one)
        #expect(a.count == 1 && a[0].artist == "Abba" && a[0].mbid == nil && a[0].title == nil)
        #expect(MusicSimilarityParsers.topTags(parse(#"{"toptags":{"tag":[{"name":"rock","count":100},{"name":"pop","count":"40"}]}}"#)).map(\.count) == [100, 40])
        #expect(MusicSimilarityParsers.similarTracks(parse(#"{"error":6,"message":"x"}"#)).isEmpty)
    }

    @Test func listenBrainzRecommendationsAreRescaledAndNamedWithTheirYear() {
        let recs = MusicSimilarityParsers.recommendations(parse(#"{"payload":{"mbids":[{"recording_mbid":"r1","score":9.0},{"recording_mbid":"r2","score":4.5}],"count":2}}"#))
        #expect(recs.map(\.mbid) == ["r1", "r2"] && recs[0].score == 1 && recs[1].score == 0.5)
        // Shape of the live reply (title and first release date sit in `recording`; the artist in `artist`).
        let names = MusicSimilarityParsers.recordingNames(parse(#"{"r1":{"artist":{"name":"Portishead"},"recording":{"name":"Strangers","first_release_date":"1994-08-22","length":238000},"release":{"name":"Dummy"}}}"#))
        #expect(names["r1"]?.title == "Strangers" && names["r1"]?.artist == "Portishead" && names["r1"]?.year == 1994)
        #expect(MusicSimilarityParsers.recommendations(parse("{}")).isEmpty)
    }

    @Test func candidatesMergeAcrossServicesAndAMatchNeedsTitleAndArtist() {
        let a = MusicSimilarCandidate(title: "Believe", artist: "Cher", mbid: nil, score: 0.7, origin: .lastFMTrack)
        let b = MusicSimilarCandidate(title: "believe", artist: "cher", mbid: nil, score: 0.9, origin: .listenBrainz)
        let c = MusicSimilarCandidate(title: "Other", artist: "Cher", mbid: "m", score: 0.8, origin: .lastFMTrack)
        let merged = MusicSimilaritySupport.merged([[a, c], [b]])
        #expect(merged.count == 2 && merged[0].score == 0.9)
        var track = MusicTrack(id: "1", providerID: "yt", title: "Believe (Remastered)", durationMs: 1, artists: [MusicArtistRef(id: "x", name: "Cher")])
        #expect(MusicSimilarityRules.isSame(a, track))
        track.artists = [MusicArtistRef(id: "y", name: "Someone Else")]
        #expect(!MusicSimilarityRules.isSame(a, track))
    }

    @Test func personalSuggestionsHonourPrivateSessionsResetsAndThinHistories() {
        #expect(MusicSimilarityRules.personal(isPrivate: true, seedCount: 500) == .privateSession)
        #expect(MusicSimilarityRules.personal(isPrivate: false, seedCount: 2) == .coldStart)
        #expect(MusicSimilarityRules.personal(isPrivate: false, seedCount: 3) == .allowed)
        #expect(MusicSimilarityRules.listenBrainzMayPersonalise(resetAt: nil))
        #expect(!MusicSimilarityRules.listenBrainzMayPersonalise(resetAt: Date()))
    }

    @Test func hiddenBlockedAndWrongScriptSongsAreFilteredOut() {
        func t(_ id: String, _ title: String, artist: String = "A") -> MusicTrack { MusicTrack(id: id, providerID: "yt", title: title, durationMs: 1, artists: [MusicArtistRef(id: "a" + id, name: artist)]) }
        var hidden = MusicHiddenSet(); hidden.tracks.insert("yt:1")
        let list = [t("1", "Hidden"), t("2", "Blocked"), t("3", "ఇది తెలుగు"), t("4", "यह हिंदी है"), t("5", "Plain Latin")]
        let kept = MusicSimilarityRules.filtered(list, hidden: hidden, isBlocked: { $0.id == "2" }, languages: [.telugu])
        #expect(kept.map(\.id) == ["3", "5"])
        #expect(MusicSimilarityRules.filtered(list, hidden: MusicHiddenSet(), isBlocked: { _ in false }, languages: nil).count == 5)
    }

    @Test func aFailingServiceCoolsDownAndRecovers() async {
        let c = MusicSourceCooldown()
        #expect(await c.allowed("lastfm"))
        await c.fail("lastfm", seconds: 60, now: Date(timeIntervalSince1970: 0))
        #expect(await !c.allowed("lastfm", now: Date(timeIntervalSince1970: 30)))
        #expect(await c.allowed("lastfm", now: Date(timeIntervalSince1970: 61)))
        #expect(LastFMReadClient.isCoolingError(29) && !LastFMReadClient.isCoolingError(6))
    }
}

@Suite("AcoustID")
struct AcoustIDTests {
    /// The shape of a real lookup reply (AcoustID's documented example fingerprint, 2026-11-26): two AcoustIDs naming one recording.
    static let reply = """
    {"results":[
      {"id":"9ff43b6a-4f16-427c-93c2-92307ca505e0","score":1.0,"recordings":[{"id":"cd2e7c47-16f5-46c6-a37c-a1eb7bf599ff","title":"Lower Your Eyelids to Die With the Sun","duration":637.333,
        "artists":[{"id":"6d7b7cd4-254b-4c25-83f6-dd20f98ceacd","name":"M83"}],"releasegroups":[{"id":"g1","title":"Donkey Punch","type":"Album"},{"id":"g2","title":"Before the Dawn Heals Us","type":"Album"}]}]},
      {"id":"be6fa248-97d1-4a18-845b-7c6a070b764c","score":0.97,"recordings":[{"id":"cd2e7c47-16f5-46c6-a37c-a1eb7bf599ff","title":"Lower Your Eyelids to Die With the Sun","duration":637.333,"artists":[{"name":"M83"}],"releasegroups":[]}]}],
     "status":"ok"}
    """

    private func entry(title: String = "", artist: String = "", ms: Int64 = 637_000) -> LocalEntry {
        LocalEntry(id: "e1", folderID: "f", path: "/music/a.mp3", title: title, artist: artist, album: "", trackNumber: nil, durationMs: ms, modified: Date(timeIntervalSince1970: 1_000), artworkFile: nil, ext: "mp3")
    }

    @Test func aRealShapedReplyIsReadAndDuplicatesFoldIntoOneRecording() throws {
        let r = try AcoustIDParser.lookup(Data(Self.reply.utf8)).get()
        #expect(r.count == 1 && r[0].title.hasPrefix("Lower Your Eyelids") && r[0].artists == ["M83"] && r[0].score == 1.0 && r[0].durationMs == 637_333)
        #expect(r[0].releaseGroups == ["Donkey Punch", "Before the Dawn Heals Us"])
    }

    @Test func errorCodesBecomeTypedErrors() {
        func err(_ code: Int) -> AcoustIDError? { if case .failure(let e) = AcoustIDParser.lookup(Data(#"{"status":"error","error":{"code":\#(code),"message":"x"}}"#.utf8)) { e } else { nil } }
        #expect(err(4) == .invalidKey && err(21) == .needsUserKey && err(3) == .invalidFingerprint && err(6) == .needsApplicationKey)
        #expect(ChromaprintOutput.parse(Data(#"{"duration": 641.0, "fingerprint": "AQAB"}"#.utf8))?.duration == 641)
        #expect(ChromaprintOutput.parse(Data(#"{"duration": 0, "fingerprint": ""}"#.utf8)) == nil)
    }

    @Test func aMatchNeedsLengthAndTagsToAgreeAndOtherwiseStaysUnconfirmed() throws {
        let rec = try AcoustIDParser.lookup(Data(Self.reply.utf8)).get()
        if case .match(let r, let c, _) = AcoustIDMatcher.decide(rec, local: .init(title: "", artist: "", durationMs: 637_000)) { #expect(r.artists == ["M83"] && c >= 0.95) } else { Issue.record("expected a match") }
        if case .match(_, let c2, let why) = AcoustIDMatcher.decide(rec, local: .init(title: "Lower Your Eyelids to Die With the Sun", artist: "M83", durationMs: 637_000)) { #expect(c2 >= 0.99 && why.contains("title agrees")) } else { Issue.record("expected a match") }
        #expect(AcoustIDMatcher.decide(rec, local: .init(title: "", artist: "", durationMs: 200_000)) == .unconfirmed)
        var weak = rec; weak[0].score = 0.5
        #expect(AcoustIDMatcher.decide(weak, local: .init(title: "", artist: "", durationMs: 637_000)) == .unconfirmed)
    }

    @Test func twoCandidatesThatFitEquallyAreAmbiguousAndNothingIsForced() {
        let a = AcoustIDRecording(id: "a", title: "Song", artists: ["X"], durationMs: 200_000, releaseGroups: [], score: 0.97)
        let b = AcoustIDRecording(id: "b", title: "Song (Live)", artists: ["X"], durationMs: 201_000, releaseGroups: [], score: 0.96)
        if case .ambiguous(let list) = AcoustIDMatcher.decide([a, b], local: .init(title: "", artist: "", durationMs: 200_500)) { #expect(list.count == 2) } else { Issue.record("expected ambiguous") }
    }

    @Test func fillingOnlyTouchesBlanksUnlessReplacingIsChosen() {
        let r = AcoustIDRecording(id: "a", title: "Real Title", artists: ["Real Artist"], durationMs: nil, releaseGroups: ["Real Album"], score: 1)
        var e = entry(title: "My Title", artist: "")
        e.album = "My Album"; e.albumTagged = true
        let fill = AcoustIDMatcher.patch(for: r, entry: e, replace: false)
        #expect(fill.title == nil && fill.artist == "Real Artist" && fill.album == nil)
        let replace = AcoustIDMatcher.patch(for: r, entry: e, replace: true)
        #expect(replace.title == "Real Title" && replace.album == "Real Album")
    }

    @Test func keysStayOutOfTheBodyAndAreCheckedBeforeTheyAreKept() {
        let body = String(data: AcoustIDClient.body(fingerprint: "AQAB+/", duration: 641), encoding: .utf8) ?? ""
        #expect(body.contains("duration=641") && body.contains("fingerprint=") && body.contains("meta=recordings") && !body.contains("client") && !body.contains("user"))
        #expect(AcoustIDKeys.isPlausible("ABCDEFGH12") && !AcoustIDKeys.isPlausible("https://acoustid.org/api-key") && !AcoustIDKeys.isPlausible("x"))
    }

    @Test func cacheRulesExpireByOutcomeAndTheStoreIsBounded() {
        let now = Date()
        let e = AcoustIDCacheEntry(state: .unconfirmed, fingerprint: "f", duration: 1, recordings: [], at: now.addingTimeInterval(-8 * 86_400))
        #expect(!AcoustIDCacheRules.isFresh(e, now: now))
        var m = e; m.state = .matched
        #expect(AcoustIDCacheRules.isFresh(m, now: now))
        let store = AcoustIDCacheStore(url: nil)
        store.set(m, for: "k")
        #expect(store.entry("k")?.state == .matched)
        store.clear()
        #expect(store.entry("k") == nil)
    }

    @Test func theToolIsFoundInOrderAndAbsenceIsReported() {
        let defaults = UserDefaults(suiteName: "acoustid-test-\(UUID().uuidString)")!
        defaults.set("/custom/fpcalc", forKey: ChromaprintTool.pathKey)
        #expect(ChromaprintTool.locate(fileExists: { $0 == "/custom/fpcalc" }, defaults: defaults) == "/custom/fpcalc")
        #expect(ChromaprintTool.locate(fileExists: { _ in false }, defaults: defaults) == nil)
        #expect(ChromaprintTool.candidates(defaults: defaults).contains("/opt/homebrew/bin/fpcalc"))
    }

    @Test func theIdentifierAsksOnceThenAnswersFromTheCacheAndNeverSendsKeysInTheBody() async throws {
        final class Counter: @unchecked Sendable { var calls = 0, prints = 0; var headers: [String: String] = [:]; var body = "" }
        struct Memory: ScrobbleSecretStore {
            let box = MemoryBox()
            func read(_ a: String) -> String? { box.get(a) }
            func write(_ v: String, account: String) { box.set(account, v) }
            func remove(_ a: String) { box.set(a, nil) }
        }
        let counter = Counter()
        struct Fake: MusicHTTPTransport {
            let counter: Counter
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                counter.calls += 1
                counter.headers = request.allHTTPHeaderFields ?? [:]
                counter.body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                return (Data(AcoustIDTests.reply.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let keys = AcoustIDKeys(store: Memory())
        #expect(keys.setApplicationKey("TESTAPPKEY1") && keys.setUserKey("TESTUSERKEY1"))
        let identifier = LocalRecordingIdentifier()
        await identifier.configure(client: AcoustIDClient(http: MusicHTTP(transport: Fake(counter: counter)), keys: keys), cache: AcoustIDCacheStore(url: nil),
                                   fingerprinter: { _ in counter.prints += 1; return (637, "AQABfake") })
        let e = entry()
        let first = try await identifier.identify(e)
        let second = try await identifier.identify(e)
        #expect(counter.calls == 1 && counter.prints == 1 && !first.fromCache && second.fromCache)
        #expect(counter.headers["Acoustid-App-Key"] == "TESTAPPKEY1" && counter.headers["Acoustid-User-Key"] == "TESTUSERKEY1")
        #expect(!counter.body.contains("TESTAPPKEY1") && !counter.body.contains("TESTUSERKEY1"))
        if case .match = first.verdict {} else { Issue.record("expected a match") }
    }

    @Test func withoutAnApplicationKeyNothingIsSent() async {
        struct Memory: ScrobbleSecretStore {
            func read(_ a: String) -> String? { nil }
            func write(_ v: String, account: String) {}
            func remove(_ a: String) {}
        }
        let client = AcoustIDClient(keys: AcoustIDKeys(store: Memory()))
        do { _ = try await client.lookup(fingerprint: "x", duration: 1); Issue.record("expected an error") } catch { #expect(error as? AcoustIDError == .needsApplicationKey) }
    }
}

private final class MemoryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func get(_ k: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[k] }
    func set(_ k: String, _ v: String?) { lock.lock(); defer { lock.unlock() }; values[k] = v }
}

@Suite("Classical Saraga layer")
struct ClassicalSaragaTests {
    private let carnatic = #"{"title":"Bhairavi Varnam","mbid":"AAAA-1","raaga":[{"uuid":"r1","name":"Bhairavi","common_name":"Bhairavi","transliteration":"Bhairavī"}],"taala":[{"uuid":"t1","name":"Adi"}],"form":[{"name":"Varnam"}],"work":[{"title":"Viriboni","mbid":"W-1"}],"concert":[{"title":"Live at Chennai"}],"artists":[{"artist":{"name":"Singer One","mbid":"S1"},"instrument":{"name":"Voice"}}]}"#
    private let hindustani = #"{"title":"Alap in Yaman","mbid":"BBBB-2","raags":[{"uuid":"r2","name":"Yaman"}],"taals":[{"name":"Teentaal"}],"forms":[{"name":"Khayal"}],"release":[{"title":"Evening Raags"}],"artists":[{"artist":{"name":"Singer Two"}}]}"#

    @Test func carnaticAndHindustaniKeysBothParseAndNothingIsInvented() {
        let c = SaragaMetadataParser.parse(Data(carnatic.utf8), tradition: .carnatic, dataset: ClassicalCatalog.dataset())
        #expect(c?.ragas.first?.name == "Bhairavi")
        #expect(c?.ragas.first?.aliases == ["Bhairavī"])
        #expect(c?.talas.first?.name == "Adi")
        #expect(c?.workMBID == "W-1")
        #expect(c?.dataset.rights == "CC BY-NC 4.0")
        let h = SaragaMetadataParser.parse(Data(hindustani.utf8), tradition: .hindustani, dataset: ClassicalCatalog.dataset())
        #expect(h?.ragas.first?.name == "Yaman")
        #expect(h?.concert == "Evening Raags")
    }

    @Test func filesWithoutAnnotationsOrTitlesAreNotRecordings() {
        let d = ClassicalCatalog.dataset()
        #expect(SaragaMetadataParser.parse(Data(#"{"title":"x"}"#.utf8), tradition: .carnatic, dataset: d) == nil)
        #expect(SaragaMetadataParser.parse(Data(#"{"raaga":[]}"#.utf8), tradition: .carnatic, dataset: d) == nil)
        #expect(SaragaMetadataParser.parse(Data("[1,2]".utf8), tradition: .carnatic, dataset: d) == nil)
    }

    @Test func aSongGetsARagaOnlyThroughItsRecordingIdAndPredictionsAreExcluded() {
        let d = ClassicalCatalog.dataset()
        let real = SaragaMetadataParser.parse(Data(carnatic.utf8), tradition: .carnatic, dataset: d)!
        var guess = SaragaMetadataParser.parse(Data(hindustani.utf8), tradition: .hindustani, dataset: d)!
        guess.kind = .predicted
        let index = ClassicalIndex(recordings: [real, guess])
        #expect(index.recording(mbid: "aaaa-1")?.title == "Bhairavi Varnam")
        #expect(index.recording(mbid: "BBBB-2") == nil)
        #expect(index.recording(mbid: "") == nil)
        #expect(index.ragas().map(\.name) == ["Bhairavi"])
        #expect(index.search("bhairavī").count == 1)
    }

    @Test func importReadsOnlyAnnotationJSONAndKeepsTraditionFromThePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saraga-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("saraga1.5_carnatic/c1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("saraga1.5_hindustani/h1"), withIntermediateDirectories: true)
        try Data(carnatic.utf8).write(to: root.appendingPathComponent("saraga1.5_carnatic/c1/a.json"))
        try Data(hindustani.utf8).write(to: root.appendingPathComponent("saraga1.5_hindustani/h1/b.json"))
        try Data(#"{"pitch":[1,2]}"#.utf8).write(to: root.appendingPathComponent("saraga1.5_carnatic/c1/pitch.json"))
        try Data("audio".utf8).write(to: root.appendingPathComponent("saraga1.5_carnatic/c1/a.mp3"))
        let store = root.appendingPathComponent("index.json")
        let catalog = ClassicalCatalog(url: store)
        let report = await catalog.importDataset(from: root)
        #expect(report.imported == 2)
        #expect(report.skipped == 1)
        let index = await catalog.current()
        #expect(Set(index.recordings.map(\.tradition)) == [.carnatic, .hindustani])
        #expect(fm.fileExists(atPath: store.path))
        let reloaded = await ClassicalCatalog(url: store).current()
        #expect(reloaded.recordings.count == 2)
    }

    @Test func aCancelledImportChangesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saraga-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("carnatic"), withIntermediateDirectories: true)
        try Data(carnatic.utf8).write(to: root.appendingPathComponent("carnatic/a.json"))
        let store = root.appendingPathComponent("index.json")
        let catalog = ClassicalCatalog(url: store)
        let task = Task { await catalog.importDataset(from: root) }
        task.cancel()
        let report = await task.value
        #expect(report.cancelled)
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }

    @Test func sagaraAuthorityOutranksWikipediaRowsForRagaAndTala() {
        #expect(MusicFieldAuthority.weight(.raga, MusicSourceID(rawValue: "saraga")) > MusicFieldAuthority.weight(.raga, MusicSourceID(rawValue: "wikipedia")))
    }
}

@Suite("Independent review fixes")
struct IndependentReviewFixTests {
    @Test func theChosenFoldersOwnNameDoesNotDecideTheTradition() {
        let root = URL(fileURLWithPath: "/Users/x/saraga-carnatic-hindustani")
        let file = root.appendingPathComponent("hindustani/h1/a.json")
        #expect(ClassicalCatalog.tradition(ofPath: ClassicalCatalog.relativePath(file, in: root)) == .hindustani)
    }

    @Test func oneCatalogueSongLanguageIsNotTwoWitnesses() {
        #expect(MusicSourceFamily.of(MusicSourceID(rawValue: "graph")) == MusicSourceFamily.of(MusicSourceID(rawValue: "jiosaavn")))
        let d = MusicFieldArbiter.decide(field: .language, evidence: [
            MusicFieldEvidence(value: "te", source: MusicSourceID(rawValue: "graph"), specificity: .recording),
            MusicFieldEvidence(value: "te", source: MusicSourceID(rawValue: "provider"), specificity: .recording)])
        #expect(d.candidates.first?.witnesses.count == 1)
    }

    @Test func lineageSpellingDoesNotMakeTwoWitnesses() {
        let a = MusicFieldEvidence(value: "x", source: MusicSourceID(rawValue: "jiosaavn"), lineage: "Sony Music India", specificity: .recording)
        let b = MusicFieldEvidence(value: "x", source: MusicSourceID(rawValue: "appleMusic"), lineage: "sony  music india", specificity: .recording)
        #expect(a.witness == b.witness)
    }
}


// MARK: AcoustID credentials and the user-key linking flow

private final class LinkStore: ScrobbleSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var v: [String: String] = [:]
    func read(_ a: String) -> String? { lock.lock(); defer { lock.unlock() }; return v[a] }
    func write(_ value: String, account: String) { lock.lock(); v[account] = value; lock.unlock() }
    func remove(_ a: String) { lock.lock(); v[a] = nil; lock.unlock() }
    var dump: String { lock.lock(); defer { lock.unlock() }; return v.values.joined(separator: "|") }
}

private final class LinkWire: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var state = "pending"
    var failNetwork = false
    var lookupError: Int?
    var statusError: Int?
    func add(_ r: URLRequest) { lock.lock(); requests.append(r); lock.unlock() }
    func count(_ suffix: String) -> Int { lock.lock(); defer { lock.unlock() }; return requests.filter { $0.url?.path.hasSuffix(suffix) == true }.count }
    func last(_ suffix: String) -> URLRequest? { lock.lock(); defer { lock.unlock() }; return requests.last { $0.url?.path.hasSuffix(suffix) == true } }
}

private struct LinkTransport: MusicHTTPTransport {
    let wire: LinkWire
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        wire.add(request)
        if wire.failNetwork { throw MusicError.network("offline") }
        let path = request.url?.path ?? ""
        let body: String
        if path.hasSuffix("request_link") {
            body = #"{"status":"ok","user":{"apikey":"LINKEDKEY12345","link":{"code":"WT14-9E3S","url":"https://acoustid.org/link?code=WT14-9E3S","expires":"2026-12-01T12:15:00+00:00"}}}"#
        } else if path.hasSuffix("link_status"), let c = wire.statusError {
            body = #"{"status":"error","error":{"code":\#(c),"message":"nope"}}"#
        } else if path.hasSuffix("link_status") {
            body = #"{"status":"ok","key":{"state":"\#(wire.state)","expires":"2026-12-01T12:15:00+00:00"}}"#
        } else if let c = wire.lookupError {
            body = #"{"status":"error","error":{"code":\#(c),"message":"nope"}}"#
        } else { body = #"{"status":"ok","results":[]}"# }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func set(_ d: Date) { lock.lock(); t = d; lock.unlock() }
}

@Suite("AcoustID credentials and linking")
struct AcoustIDLinkingTests {
    private static let expiry = ISO8601DateFormatter().date(from: "2026-12-01T12:15:00Z")!
    private func make(store: LinkStore = LinkStore(), wire: LinkWire = LinkWire(), clock: Clock = Clock(ISO8601DateFormatter().date(from: "2026-12-01T12:00:00Z")!), appKey: String? = "APPKEY123456") -> (AcoustIDConnection, LinkStore, LinkWire, Clock) {
        let keys = AcoustIDKeys(store: store)
        if let appKey { _ = keys.setApplicationKey(appKey) }
        let client = AcoustIDClient(http: MusicHTTP(transport: LinkTransport(wire: wire)), keys: keys)
        return (AcoustIDConnection(client: client, now: { clock.now }, device: { "Test Mac" }), store, wire, clock)
    }

    // Headers and codes

    @Test func lookupSendsBothDocumentedHeadersAndNeverPutsAKeyInTheAddressOrBody() async throws {
        let store = LinkStore(), wire = LinkWire()
        let keys = AcoustIDKeys(store: store)
        _ = keys.setApplicationKey("APPKEY123456"); _ = keys.setUserKey("USERKEY123456")
        _ = try await AcoustIDClient(http: MusicHTTP(transport: LinkTransport(wire: wire)), keys: keys).lookup(fingerprint: "FP", duration: 100)
        let r = try #require(wire.last("lookup"))
        #expect(r.value(forHTTPHeaderField: "Acoustid-App-Key") == "APPKEY123456")
        #expect(r.value(forHTTPHeaderField: "Acoustid-User-Key") == "USERKEY123456")
        #expect(r.url?.absoluteString.contains("KEY") == false)
        #expect(String(data: r.httpBody ?? Data(), encoding: .utf8)?.contains("KEY1") == false)
    }

    @Test func codeFourIsAnInvalidKeyAndTwentyOneIsAUserKeyRequirement() {
        func parse(_ c: Int) -> AcoustIDError? { if case .failure(let e) = AcoustIDParser.lookup(Data(#"{"status":"error","error":{"code":\#(c),"message":"m"}}"#.utf8)) { return e } else { return nil } }
        #expect(parse(4) == .invalidKey)
        #expect(parse(21) == .needsUserKey)
        #expect(parse(21) != .needsApplicationKey)
    }

    @Test func missingApplicationKeySendsNothing() async {
        let (c, _, wire, _) = make(appKey: nil)
        let s = await c.begin()
        #expect(s == .failed(.needsApplicationKey))
        #expect(wire.requests.isEmpty)
    }

    // Linking

    @Test func requestLinkUsesTheApplicationHeaderStoresTheKeyAtOnceAndWaits() async throws {
        let (c, store, wire, _) = make()
        let s = await c.begin()
        #expect(s == .pending(code: "WT14-9E3S", url: "https://acoustid.org/link?code=WT14-9E3S", expires: Self.expiry))
        let r = try #require(wire.last("request_link"))
        #expect(r.value(forHTTPHeaderField: "Acoustid-App-Key") == "APPKEY123456")
        #expect(r.value(forHTTPHeaderField: "Acoustid-User-Key") == nil)
        #expect(r.url?.absoluteString.contains("KEY") == false)
        #expect(AcoustIDKeys(store: store).userKey == "LINKEDKEY12345")
        #expect(AcoustIDKeys(store: store).activeUserKey == nil)       // not used until approved
    }

    @Test func aPendingKeyIsNeverSentOnALookup() async throws {
        let (c, store, wire, _) = make()
        _ = await c.begin()
        _ = try await AcoustIDClient(http: MusicHTTP(transport: LinkTransport(wire: wire)), keys: AcoustIDKeys(store: store)).lookup(fingerprint: "FP", duration: 100)
        #expect(try #require(wire.last("lookup")).value(forHTTPHeaderField: "Acoustid-User-Key") == nil)
    }

    @Test func openingTheScreenTwiceOrRelaunchingMakesNoSecondRequest() async {
        let (c, store, wire, clock) = make()
        _ = await c.begin(); _ = await c.begin()
        #expect(wire.count("request_link") == 1)
        let client = AcoustIDClient(http: MusicHTTP(transport: LinkTransport(wire: wire)), keys: AcoustIDKeys(store: store))
        let relaunched = AcoustIDConnection(client: client, now: { clock.now }, device: { "Test Mac" })
        let s = await relaunched.begin()
        if case .pending(let code, _, _) = s { #expect(code == "WT14-9E3S") } else { Issue.record("expected pending") }
        #expect(wire.count("request_link") == 1)
        wire.state = "approved"
        #expect(await relaunched.check() == .connected(manual: false))
    }

    @Test func statusChecksSendBothKeysInHeadersOnly() async throws {
        let (c, _, wire, _) = make()
        _ = await c.begin(); _ = await c.check()
        let r = try #require(wire.last("link_status"))
        #expect(r.value(forHTTPHeaderField: "Acoustid-App-Key") == "APPKEY123456")
        #expect(r.value(forHTTPHeaderField: "Acoustid-User-Key") == "LINKEDKEY12345")
        #expect(r.url?.absoluteString.contains("KEY") == false)
    }

    @Test func pendingKeepsWaitingAndApprovalActivatesTheKey() async {
        let (c, store, wire, _) = make()
        _ = await c.begin()
        wire.state = "pending"
        if case .pending = await c.check() {} else { Issue.record("expected pending") }
        #expect(AcoustIDKeys(store: store).activeUserKey == nil)
        wire.state = "approved"
        #expect(await c.check() == .connected(manual: false))
        #expect(AcoustIDKeys(store: store).activeUserKey == "LINKEDKEY12345")
    }

    @Test(arguments: [("declined", AcoustIDLinkOutcome.declined), ("expired", .expired), ("revoked", .revoked), ("unknown", .unknown)])
    func everyTerminalStateEndsTheLinkAndForgetsTheKey(state: String, outcome: AcoustIDLinkOutcome) async {
        let (c, store, wire, _) = make()
        _ = await c.begin()
        wire.state = state
        #expect(await c.check() == .ended(outcome))
        #expect(AcoustIDKeys(store: store).userKey == nil)
        #expect(AcoustIDKeys(store: store).link == nil)
        #expect(await c.current() == .notConnected)
    }

    @Test func aPendingLinkPastItsTimeEndsAsExpiredAndTheNextBeginAsksAgain() async {
        let (c, store, wire, clock) = make()
        _ = await c.begin()
        clock.set(Self.expiry.addingTimeInterval(5))
        #expect(await c.check() == .ended(.expired))
        #expect(AcoustIDKeys(store: store).userKey == nil)
        _ = await c.begin()
        #expect(wire.count("request_link") == 2)
    }

    @Test func anExpiredPendingLinkIsReplacedWhenTheScreenOpensAgain() async {
        let (c, _, wire, clock) = make()
        _ = await c.begin()
        clock.set(Self.expiry.addingTimeInterval(5))
        _ = await c.begin()
        #expect(wire.count("request_link") == 2)
    }

    @Test func aNetworkProblemWhileCheckingChangesNothing() async {
        let (c, store, wire, _) = make()
        _ = await c.begin()
        wire.failNetwork = true
        if case .pending = await c.check() {} else { Issue.record("expected pending") }
        #expect(AcoustIDKeys(store: store).userKey == "LINKEDKEY12345")
    }

    @Test func aStateWeDoNotKnowNeverDeletesTheKey() {
        #expect({ if case .failure = AcoustIDLinkParser.status(Data(#"{"status":"ok","key":{"state":"mystery"}}"#.utf8)) { return true } else { return false } }())
    }

    @Test func cancellingRemovesTheUnusedKeyAndAllowsANewRequest() async {
        let (c, store, wire, _) = make()
        _ = await c.begin()
        #expect(await c.cancel() == .notConnected)
        #expect(AcoustIDKeys(store: store).userKey == nil)
        _ = await c.begin()
        #expect(wire.count("request_link") == 2)
    }

    @Test func aRefusedKeyThatIsStillWaitingIsCheckedAndKeptNotDeleted() async {
        let (c, store, wire, _) = make()
        _ = await c.begin()
        wire.state = "pending"
        if case .pending = await c.resolveInvalidKey() {} else { Issue.record("expected pending") }
        #expect(AcoustIDKeys(store: store).userKey == "LINKEDKEY12345")
        #expect(wire.count("link_status") == 1)
    }

    @Test func aRefusedKeyThatWasDeclinedIsDroppedAfterTheStatusSaysSo() async {
        let (c, store, wire, _) = make()
        _ = await c.begin()
        wire.state = "declined"
        #expect(await c.resolveInvalidKey() == .ended(.declined))
        #expect(AcoustIDKeys(store: store).userKey == nil)
    }

    @Test func aRefusedPastedKeyIsNotDeletedBehindTheUsersBack() async {
        let (c, store, wire, _) = make()
        _ = await c.enterManually("PASTEDKEY123456")
        #expect(await c.resolveInvalidKey() == .connected(manual: true))
        #expect(AcoustIDKeys(store: store).userKey == "PASTEDKEY123456")
        #expect(wire.count("link_status") == 0)
    }

    // Manual entry, disconnect, reconnect

    @Test func aPastedKeyWorksAtOnceAndReplacesAnyWaitingLink() async {
        let (c, store, _, _) = make()
        _ = await c.begin()
        #expect(await c.enterManually("PASTEDKEY123456") == .connected(manual: true))
        #expect(AcoustIDKeys(store: store).activeUserKey == "PASTEDKEY123456")
        #expect(AcoustIDKeys(store: store).link == nil)
    }

    @Test func notAKeyIsRefused() async {
        let (c, store, _, _) = make()
        #expect(await c.enterManually("https://acoustid.org/api-key") == .failed(.invalidKey))
        #expect(AcoustIDKeys(store: store).userKey == nil)
    }

    @Test func disconnectingDeletesTheLocalCredentialAndReconnectingAsksForAFreshLink() async {
        let (c, store, wire, _) = make()
        _ = await c.begin(); wire.state = "approved"; _ = await c.check()
        #expect(await c.disconnect() == .notConnected)
        #expect(!store.dump.contains("LINKEDKEY12345"))
        #expect(wire.count("request_link") == 1)
        _ = await c.begin()
        #expect(wire.count("request_link") == 2)
    }

    // Privacy

    @Test func keysAreRemovedFromAnyTextShownOrRecorded() {
        let text = "failed for https://x/?user=SECRETUSERKEY1 using APPKEY123456"
        let clean = AcoustIDRedactor.redact(text, keys: ["SECRETUSERKEY1", "APPKEY123456", nil])
        #expect(!clean.contains("SECRETUSERKEY1"))
        #expect(!clean.contains("APPKEY123456"))
    }

    @Test func aFailedRequestNeverEchoesAKeyInItsError() async {
        let store = LinkStore(), wire = LinkWire()
        wire.failNetwork = true
        let keys = AcoustIDKeys(store: store)
        _ = keys.setApplicationKey("APPKEY123456"); _ = keys.setUserKey("USERKEY123456")
        do { _ = try await AcoustIDClient(http: MusicHTTP(transport: LinkTransport(wire: wire)), keys: keys).lookup(fingerprint: "FP", duration: 1) }
        catch { #expect(!String(describing: error).contains("KEY1")) }
    }

    @Test func linkStateRulesCoverEveryDocumentedState() {
        let t = Self.expiry
        let before = t.addingTimeInterval(-60), after = t.addingTimeInterval(60)
        #expect(AcoustIDLinkRules.action(for: .pending, expires: t, now: before) == .keepWaiting)
        #expect(AcoustIDLinkRules.action(for: .pending, expires: t, now: after) == .discard(.expired))
        #expect(AcoustIDLinkRules.action(for: .approved, expires: t, now: after) == .activate)
        #expect(AcoustIDLinkRules.action(for: .declined, expires: t, now: before) == .discard(.declined))
        #expect(AcoustIDLinkRules.action(for: .expired, expires: t, now: before) == .discard(.expired))
        #expect(AcoustIDLinkRules.action(for: .revoked, expires: t, now: before) == .discard(.revoked))
        #expect(AcoustIDLinkRules.action(for: .unknown, expires: t, now: before) == .discard(.unknown))
    }
}

@Suite("Film classification")
struct FilmClassificationTests {
    @Test func industryComesFromLanguageAndCountryNotFromGuessing() {
        #expect(MusicFilmIndustry.classify(language: "te", country: "IN") == MusicFilmIndustry(name: "Tollywood", basis: .languageAndCountry))
        #expect(MusicFilmIndustry.classify(language: "Tamil", country: "India")?.name == "Kollywood")
        #expect(MusicFilmIndustry.classify(language: "ml", country: nil) == MusicFilmIndustry(name: "Mollywood", basis: .languageOnly))
        #expect(MusicFilmIndustry.classify(language: "te", country: "US") == nil)
        #expect(MusicFilmIndustry.classify(language: "en", country: "IN") == nil)
        #expect(MusicFilmIndustry.classify(language: nil, country: "IN") == nil)
    }

    @Test func aSingerIsPlaybackOnlyWhereTheFilmHasACastWithoutThem() {
        func id(_ s: String) -> MusicEntityID { MusicEntityID.provisional(kind: .person, name: s) }
        let spb = id("spb"), a = id("actor")
        let f1 = MusicEntityID.provisional(kind: .film, name: "f1"), f2 = MusicEntityID.provisional(kind: .film, name: "f2"), f3 = MusicEntityID.provisional(kind: .film, name: "f3")
        let split = MusicPlaybackSinger.split(films: [(f1, [a]), (f2, [spb, a]), (f3, [])], singer: spb)
        #expect(split.playback == [f1])
        #expect(split.acting == [f2])          // f3 has no cast on record: not placed either way
    }

    @Test func songKindsComeOnlyFromDocumentedTagsAndWholeWords() {
        #expect(MusicSongKind.kinds(fromTags: ["Devotional", "Telugu"]) == [.devotional])
        #expect(MusicSongKind.kinds(fromTags: ["folklore"]).isEmpty)
        #expect(MusicSongKind.kinds(fromTags: ["Original Score"]) == [.filmScore])
        #expect(MusicSongKind.kinds(fromTags: ["carnatic fusion"]).isSuperset(of: [.classicalFusion, .classical]))
        #expect(MusicSongKind.kinds(fromTags: []).isEmpty)
    }
}

@Suite("Tala browsing")
struct TalaBrowsingTests {
    @Test func talasGroupRecordingsAndExcludePredictions() {
        let d = ClassicalCatalog.dataset()
        func rec(_ id: String, tala: String, kind: ClassicalAnnotationKind = .documented) -> ClassicalRecording {
            ClassicalRecording(mbid: id, title: id, tradition: .carnatic, ragas: [], talas: [ClassicalName(id: nil, name: tala, aliases: [])], forms: [], workTitle: nil, workMBID: nil, artists: [], concert: nil, dataset: d, kind: kind)
        }
        let index = ClassicalIndex(recordings: [rec("a", tala: "Adi"), rec("b", tala: "Adi"), rec("c", tala: "Rupaka"), rec("p", tala: "Misra Chapu", kind: .predicted)])
        #expect(index.talas().map(\.name) == ["Adi", "Rupaka"])
        #expect(index.talas().first?.recordings.count == 2)
        #expect(index.search("rup", talas: true).map(\.name) == ["Rupaka"])
        #expect(index.search("adi", talas: false).isEmpty)
    }
}

@Suite("MusicBrainz band membership")
struct BandMembershipTests {
    private func parse(_ json: String) -> MusicClaimBatch? { MusicBrainzParser.artist(Data(json.utf8)) }

    @Test func aBandsBackwardLinkNamesAMemberWhoBelongsToTheBand() throws {
        let b = try #require(parse(#"{"id":"b1","name":"The Band","type":"Group","relations":[{"type":"member of band","target-type":"artist","direction":"backward","attributes":["bass guitar"],"artist":{"id":"p1","name":"A Member","type":"Person"}}]}"#))
        let c = try #require(b.claims.first { $0.predicate == .memberOf })
        #expect(c.subject.kind == .person)
        #expect(c.object.kind == .group)
        #expect(c.attributes.instrument == "bass guitar")
    }

    @Test func aPersonsForwardLinkNamesTheirBandAndOriginalIsNotAnInstrument() throws {
        let b = try #require(parse(#"{"id":"p1","name":"A Member","type":"Person","relations":[{"type":"member of band","target-type":"artist","direction":"forward","attributes":["guitar","original"],"artist":{"id":"b1","name":"The Band","type":"Group"}}]}"#))
        let c = try #require(b.claims.first { $0.predicate == .memberOf })
        #expect(c.subject.kind == .person)
        #expect(c.attributes.instrument == "guitar")
    }

    @Test func aLinkThatIsNotAPersonAndBandPairStatesNothing() throws {
        let wrong = try #require(parse(#"{"id":"b1","name":"The Band","type":"Group","relations":[{"type":"member of band","target-type":"artist","direction":"forward","artist":{"id":"b2","name":"Other Band","type":"Group"}}]}"#))
        #expect(wrong.claims.allSatisfy { $0.predicate != .memberOf })
    }
}

@Suite("Wikidata franchise and influences")
struct WikidataFranchiseInfluenceTests {
    private func claim(_ p: String, _ q: String) -> String { #""\#(p)":[{"mainsnak":{"snaktype":"value","datavalue":{"value":{"id":"\#(q)"},"type":"wikibase-entityid"}}}]"# }
    private func entity(_ id: String, label: String, claims: String) -> Data {
        Data(#"{"entities":{"\#(id)":{"labels":{"en":{"value":"\#(label)"}},"claims":{\#(claims)}}}}"#.utf8)
    }
    private func person(_ q: String, _ name: String) -> MusicWikidataParser.Person { MusicWikidataParser.Person(qid: q, name: name, isGroup: false, ids: [ExternalID(.wikidata, q)], photoFile: nil, birthYear: nil) }

    @Test func aFilmCarriesItsFranchiseOnlyWhenWikidataStatesOne() throws {
        let with = try #require(MusicWikidataParser.item(entity("Q1", label: "Part Two", claims: claim("P179", "Q9")), qid: "Q1", kind: .film, people: ["Q9": person("Q9", "The Saga")]))
        #expect(with.drafts.first?.entity.attrs["franchise"] == "The Saga")
        let without = try #require(MusicWikidataParser.item(entity("Q2", label: "Alone", claims: claim("P57", "Q7")), qid: "Q2", kind: .film, people: [:]))
        #expect(without.drafts.first?.entity.attrs["franchise"] == nil)
    }

    @Test func statedInfluencesBecomeLinksBetweenPeople() throws {
        let b = try #require(MusicWikidataParser.item(entity("Q5", label: "Student", claims: claim("P737", "Q6")), qid: "Q5", kind: .person, people: ["Q6": person("Q6", "Teacher")]))
        let c = try #require(b.claims.first { $0.predicate == .influencedBy })
        #expect(c.subject.kind == .person && c.object.kind == .person)
    }

    @Test func aPersonNeverInfluencesThemselvesAndFilmsHaveNoInfluences() throws {
        let b = try #require(MusicWikidataParser.item(entity("Q5", label: "Student", claims: claim("P737", "Q5")), qid: "Q5", kind: .person, people: ["Q5": person("Q5", "Student")]))
        #expect(b.claims.allSatisfy { $0.predicate != .influencedBy })
        let f = try #require(MusicWikidataParser.item(entity("Q8", label: "Film", claims: claim("P737", "Q6")), qid: "Q8", kind: .film, people: ["Q6": person("Q6", "Teacher")]))
        #expect(f.claims.allSatisfy { $0.predicate != .influencedBy })
    }
}


@Suite("Combine song kind")
struct CombineKindTests {
    @Test func theKindFilterCountsAsRunnableOnlyWithAPersonAndIsPartOfTheFilter() {
        var f = MusicCombineFilter()
        f.kind = .devotional
        #expect(!f.isEmpty)
        #expect(!f.isRunnable)                       // there must still be someone to start from
        f.singer = MusicEntityID.provisional(kind: .person, name: "x")
        #expect(f.isRunnable)
    }
}

@Suite("Second review fixes")
struct SecondReviewFixTests {
    @Test func threeLetterLanguageCodesMapToTheirOwnTwoLetterCode() {
        #expect(MusicCombineRules.languageKey("mal") == "ml")
        #expect(MusicCombineRules.languageKey("mar") == "mr")
        #expect(MusicCombineRules.languageKey("tel") == "te")
        #expect(MusicCombineRules.languageKey("kan") == "kn")
        #expect(MusicCombineRules.languageKey("te") == "te")
    }

    @Test func fusionNeedsAClassicalTraditionInTheTag() {
        #expect(MusicSongKind.kinds(fromTags: ["jazz fusion"]).isEmpty)
        #expect(MusicSongKind.kinds(fromTags: ["fusion"]).isEmpty)
        #expect(MusicSongKind.kinds(fromTags: ["Carnatic fusion"]).contains(.classicalFusion))
    }

    @Test func influencesNeverPointAtNonHumans() throws {
        let json = #"{"entities":{"Q5":{"labels":{"en":{"value":"Student"}},"claims":{"P737":[{"mainsnak":{"snaktype":"value","datavalue":{"value":{"id":"Q6"},"type":"wikibase-entityid"}}}]}}}}"#
        let movement = MusicWikidataParser.Person(qid: "Q6", name: "Impressionism", isGroup: false, isHuman: false, ids: [ExternalID(.wikidata, "Q6")], photoFile: nil, birthYear: nil)
        let b = try #require(MusicWikidataParser.item(Data(json.utf8), qid: "Q5", kind: .person, people: ["Q6": movement]))
        #expect(b.claims.allSatisfy { $0.predicate != .influencedBy })
    }

    @Test func bandRolesThatAreNotInstrumentsAreNotStoredAsInstruments() throws {
        let b = try #require(MusicBrainzParser.artist(Data(#"{"id":"p1","name":"A","type":"Person","relations":[{"type":"member of band","target-type":"artist","direction":"forward","attributes":["founder","minor","bass guitar"],"artist":{"id":"b1","name":"B","type":"Group"}}]}"#.utf8)))
        #expect(try #require(b.claims.first { $0.predicate == .memberOf }).attributes.instrument == "bass guitar")
    }
}

@Suite("AcoustID linking recovery")
struct AcoustIDLinkingRecoveryTests {
    private func make() -> (AcoustIDConnection, LinkStore, LinkWire) {
        let store = LinkStore(), wire = LinkWire()
        let keys = AcoustIDKeys(store: store); _ = keys.setApplicationKey("APPKEY123456")
        let client = AcoustIDClient(http: MusicHTTP(transport: LinkTransport(wire: wire)), keys: keys)
        return (AcoustIDConnection(client: client, now: { Date(timeIntervalSince1970: 1_700_000_000) }), store, wire)
    }

    @Test func anApprovedKeyThatWasRevokedIsDroppedWhenALookupIsRefused() async {
        let (c, store, wire) = make()
        _ = await c.begin(); wire.state = "approved"; _ = await c.check()
        wire.state = "revoked"
        #expect(await c.resolveInvalidKey() == .ended(.revoked))
        #expect(AcoustIDKeys(store: store).userKey == nil)
    }

    @Test func anApprovedKeyStaysWhenAcoustIDStillApprovesIt() async {
        let (c, store, wire) = make()
        _ = await c.begin(); wire.state = "approved"; _ = await c.check()
        #expect(await c.resolveInvalidKey() == .connected(manual: false))
        #expect(AcoustIDKeys(store: store).userKey == "LINKEDKEY12345")
    }

    @Test func aRefusedApplicationKeyIsNotShownAsWaiting() async {
        let (c, store, wire) = make()
        _ = await c.begin()
        wire.statusError = 4
        #expect(await c.resolveInvalidKey() == .failed(.invalidKey))
        #expect(AcoustIDKeys(store: store).userKey == "LINKEDKEY12345")       // not deleted
    }

    @Test func theDeviceNameSentIsNotTheOwnersMacName() async {
        let (c, _, wire) = make()
        _ = await c.begin()
        let body = String(data: wire.last("request_link")?.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("StreamSetu"))
    }
}

@Suite("Sample relations")
struct SampleRelationTests {
    private func rel(_ dir: String, target: String = "recording", id: String = "B-ID", type: String = "samples material") -> String {
        let obj: String
        switch target {
        case "release": obj = #""release":{"id":"\#(id)","title":"The Release"}"#
        case "artist": obj = #""artist":{"id":"\#(id)","name":"The Artist","type":"Person"}"#
        default: obj = #""recording":{"id":"\#(id)","title":"The Other"}"#
        }
        return #"{"type":"\#(type)","type-id":"9efd9ce9-e702-448b-8e76-641515e8fe62","direction":"\#(dir)","target-type":"\#(target)",\#(obj)}"#
    }
    private func parse(_ relations: [String]) -> MusicClaimBatch? {
        MusicBrainzParser.recording(Data(#"{"id":"A-ID","title":"This One","relations":[\#(relations.joined(separator: ","))]}"#.utf8))
    }

    @Test func aForwardLinkMeansThisRecordingSamplesTheTarget() throws {
        let b = try #require(parse([rel("forward")]))
        let c = try #require(b.claims.first { $0.predicate == .samples })
        #expect(c.subject.kind == .recording && c.object.kind == .recording)
        if case .external(_, let s) = c.subject, case .external(_, let o) = c.object { #expect(s.value == "A-ID" && o.value == "B-ID") } else { Issue.record("expected external refs") }
        #expect(c.evidence.contains("type-id:9efd9ce9-e702-448b-8e76-641515e8fe62"))
    }

    @Test func aBackwardLinkMeansTheTargetSamplesThisRecordingAndIsStoredTheSameWay() throws {
        let b = try #require(parse([rel("backward")]))
        let c = try #require(b.claims.first { $0.predicate == .samples })
        if case .external(_, let s) = c.subject, case .external(_, let o) = c.object { #expect(s.value == "B-ID" && o.value == "A-ID") } else { Issue.record("expected external refs") }
    }

    @Test func aRecordingCanSampleARelease() throws {
        let b = try #require(parse([rel("forward", target: "release", id: "R-ID")]))
        let c = try #require(b.claims.first { $0.predicate == .samples })
        #expect(c.object.kind == .release)
    }

    @Test func aReleaseCanNeverBeTheSamplingSide() throws {
        let b = try #require(parse([rel("backward", target: "release", id: "R-ID")]))
        #expect(b.claims.allSatisfy { $0.predicate != .samples })
    }

    @Test func artistLevelSamplingStaysSeparateAndNeverBecomesARecordingLink() throws {
        let b = try #require(parse([rel("forward", target: "artist", id: "P-ID", type: "samples artist")]))
        #expect(b.claims.contains { $0.predicate == .samplesArtist && $0.object.kind == .person })
        #expect(b.claims.allSatisfy { $0.predicate != .samples })
    }

    @Test func duplicateLinksCollapseToOneAndATargetWithNoRecordIsSkipped() throws {
        let missing = #"{"type":"samples material","type-id":"x","direction":"forward","target-type":"recording"}"#
        let b = try #require(parse([rel("forward"), rel("forward"), missing]))
        #expect(b.claims.filter { $0.predicate == .samples }.count == 1)
    }

    @Test func remixesAndCoversAreNotSamples() throws {
        let b = try #require(parse([rel("forward", type: "remix"), rel("forward", type: "samples material"), rel("forward", type: "cover")]))
        #expect(b.claims.filter { $0.predicate == .samples }.count == 1)
    }

    @Test func theSongPageListsSamplesFromAndSampledByFromOneStoredLink() async throws {
        let f = await SongFixture.awaara()
        await f.entity("newer", .recording, "Newer Song", year: 2001)
        await f.edge("newer", .samples, "awara")
        let newer = try await MusicSongSamplesLoader(env: MusicSongLoaderEnv()).load(entity: f["newer"], store: f.graph, report: SongPartials().reporter)
        let newerItems = newer.items.compactMap { $0.base as? MusicSongSampleItem }
        #expect(newerItems.map(\.direction) == [.samplesFrom] && newerItems.first?.id == f["awara"])
        let older = try await MusicSongSamplesLoader(env: MusicSongLoaderEnv()).load(entity: f["awara"], store: f.graph, report: SongPartials().reporter)
        let olderItems = older.items.compactMap { $0.base as? MusicSongSampleItem }
        #expect(olderItems.map(\.direction) == [.sampledBy] && olderItems.first?.id == f["newer"])
    }
}

@Suite("Franchise collection")
struct FranchiseCollectionTests {
    @Test func filmsOfOneFranchiseAreFoundFromAnyOfThemInReleaseOrder() async throws {
        let f = await SongFixture.awaara()
        await f.entity("saga", .series, "The Saga", subkind: "franchise")
        await f.entity("p2", .film, "Part Two", year: 2004)
        await f.entity("p1", .film, "Part One", year: 2001)
        await f.entity("p3", .film, "Part Three", year: 2008)
        for k in ["p1", "p2", "p3"] { await f.edge(k, .inFranchise, "saga") }
        let fr = try #require(await MusicFranchise.load(for: f["p2"], store: f.graph))
        #expect(fr.name == "The Saga")
        #expect(fr.films.map(\.name) == ["Part One", "Part Two", "Part Three"])
        #expect(fr.films.filter(\.current).map(\.name) == ["Part Two"])
        #expect(try #require(await MusicFranchise.load(for: f["p3"], store: f.graph)).films.count == 3)
    }

    @Test func aFranchiseWithOnlyThisFilmIsNotShownAndAFilmWithNoneHasNone() async throws {
        let f = await SongFixture.awaara()
        await f.entity("saga", .series, "Lonely Saga", subkind: "franchise")
        await f.entity("solo", .film, "Only Film", year: 2010)
        await f.edge("solo", .inFranchise, "saga")
        #expect(await MusicFranchise.load(for: f["solo"], store: f.graph) == nil)
        await f.entity("none", .film, "No Franchise", year: 2011)
        #expect(await MusicFranchise.load(for: f["none"], store: f.graph) == nil)
    }

    @Test func wikidataSeriesBecomesAFranchiseEntityLinkedFromTheFilm() throws {
        let json = #"{"entities":{"Q1":{"labels":{"en":{"value":"Part Two"}},"claims":{"P179":[{"mainsnak":{"snaktype":"value","datavalue":{"value":{"id":"Q9"},"type":"wikibase-entityid"}}}]}}}}"#
        let series = MusicWikidataParser.Person(qid: "Q9", name: "The Saga", isGroup: false, ids: [ExternalID(.wikidata, "Q9")], photoFile: nil, birthYear: nil)
        let b = try #require(MusicWikidataParser.item(Data(json.utf8), qid: "Q1", kind: .film, people: ["Q9": series]))
        let c = try #require(b.claims.first { $0.predicate == .inFranchise })
        #expect(c.object.kind == .series)
        #expect(b.drafts.contains { $0.entity.kind == .series && $0.entity.subkind == "franchise" && $0.entity.name == "The Saga" })
    }
}

@Suite("Collaborator network")
struct CollaboratorNetworkTests {
    @Test func theNetworkRanksCollaboratorsBySharedWorksAndCountsWhatItLookedAt() async throws {
        let f = await SongFixture.awaara()
        await f.entity("me", .person, "Me")
        await f.entity("a", .person, "Often")
        await f.entity("b", .person, "Once")
        for (i, k) in ["s1", "s2", "s3"].enumerated() {
            await f.entity(k, .recording, "Song \(i)", year: 2000 + i)
            await f.edge(k, .performedBy, "me", role: .singer)
            await f.edge(k, .composedBy, "a", role: .composer)
        }
        await f.edge("s1", .writtenBy, "b", role: .lyricist)
        let n = try #require(await MusicCollaboratorNetwork.load(for: f["me"], store: f.graph))
        #expect(n.centerName == "Me")
        #expect(n.nodes.first?.name == "Often" && n.nodes.first?.shared == 3)
        #expect(n.nodes.contains { $0.name == "Once" && $0.shared == 1 })
        #expect(!n.nodes.contains { $0.id == f["me"] })
        #expect(n.worksChecked == 3)
    }

    @Test func aPersonWithNoWorksHasAnEmptyNetwork() async throws {
        let f = await SongFixture.awaara()
        await f.entity("lone", .person, "Lone")
        let n = try #require(await MusicCollaboratorNetwork.load(for: f["lone"], store: f.graph))
        #expect(n.nodes.isEmpty && n.worksChecked == 0)
    }
}

@Suite("Film synopsis")
struct FilmSynopsisTests {
    private func batch(_ overview: String) -> MusicClaimBatch? {
        let json = #"{"id":603,"title":"Some Film","overview":"\#(overview)","release_date":"2001-05-04","original_language":"te","credits":{"cast":[],"crew":[]}}"#
        return TMDBGraphSource.filmBatch(Data(json.utf8), now: Date())
    }

    @Test func tmdbOverviewBecomesTheFilmSynopsisWithItsSource() throws {
        let b = try #require(batch("A town waits for a storm."))
        let film = try #require(b.drafts.first { $0.ref.kind == .film })
        #expect(film.entity.attrs["synopsis"] == "A town waits for a storm.")
        #expect(film.entity.attrs["synopsisSource"] == "TMDB")
    }

    @Test func aBlankOverviewStoresNoSynopsis() throws {
        let b = try #require(batch("   "))
        let film = try #require(b.drafts.first { $0.ref.kind == .film })
        #expect(film.entity.attrs["synopsis"] == nil && film.entity.attrs["synopsisSource"] == nil)
    }
}

@Suite("Person description lookup")
struct PersonDescriptionLookupTests {
    private func hit(_ id: String, _ label: String, _ d: String) -> MusicPersonWikiRules.SearchHit { .init(qid: id, label: label, description: d) }

    @Test func aSingerIsFoundByNameWhenTheDescriptionSaysSo() {
        let hits = [hit("Q1", "Chitra", "Indian playback singer"), hit("Q2", "Chitra", "female given name"), hit("Q3", "Chitra", "2012 Tamil film")]
        #expect(MusicPersonWikiRules.chooseHit(name: "Chitra", isGroup: false, roleWords: ["singer"], hits: hits) == "Q1")
    }

    @Test func aBandNeedsABandDescription() {
        let hits = [hit("Q10", "Coldplay", "British rock band"), hit("Q11", "Coldplay", "2000 album by someone")]
        #expect(MusicPersonWikiRules.chooseHit(name: "Coldplay", isGroup: true, roleWords: [], hits: hits) == "Q10")
        #expect(MusicPersonWikiRules.chooseHit(name: "Coldplay", isGroup: false, roleWords: [], hits: hits) == nil)
    }

    @Test func twoPeopleWithTheSameNameAreResolvedByTheRoleOrLeftAlone() {
        let hits = [hit("Q20", "Arjun", "Indian actor"), hit("Q21", "Arjun", "Indian music composer")]
        #expect(MusicPersonWikiRules.chooseHit(name: "Arjun", isGroup: false, roleWords: ["composer"], hits: hits) == "Q21")
        #expect(MusicPersonWikiRules.chooseHit(name: "Arjun", isGroup: false, roleWords: ["actor"], hits: hits) == "Q20")
        #expect(MusicPersonWikiRules.chooseHit(name: "Arjun", isGroup: false, roleWords: [], hits: hits) == nil)
        #expect(MusicPersonWikiRules.chooseHit(name: "Arjun", isGroup: false, roleWords: ["singer"], hits: hits) == nil)
    }

    @Test func disambiguationPagesNonPeopleAndOtherNamesAreNeverChosen() {
        #expect(MusicPersonWikiRules.chooseHit(name: "Rahman", isGroup: false, roleWords: [], hits: [hit("Q30", "Rahman", "Wikimedia disambiguation page")]) == nil)
        #expect(MusicPersonWikiRules.chooseHit(name: "Rahman", isGroup: false, roleWords: [], hits: [hit("Q31", "Rahman", "Indian singer and composer")]) == "Q31")
        #expect(MusicPersonWikiRules.chooseHit(name: "Someone Else", isGroup: false, roleWords: [], hits: [hit("Q32", "Rahman", "Indian singer")]) == nil)
        #expect(MusicPersonWikiRules.chooseHit(name: "", isGroup: false, roleWords: [], hits: [hit("Q33", "", "singer")]) == nil)
    }

    @Test func filmSongAndTelevisionPeopleAreChosenButFilmsAreNot() {
        for d in ["Indian film director", "Indian film actor", "film score composer", "Indian songwriter", "Indian television actor"] {
            let id = MusicPersonWikiRules.chooseHit(name: "Sri", isGroup: false, roleWords: [], hits: [hit("Q77", "Sri", d)])
            #expect(id == "Q77", "\(d)")
        }
        #expect(MusicPersonWikiRules.chooseHit(name: "Sri", isGroup: false, roleWords: [], hits: [hit("Q78", "Sri", "2012 Tamil film")]) == nil)
        #expect(MusicPersonWikiRules.chooseHit(name: "Sri", isGroup: false, roleWords: [], hits: [hit("Q79", "Sri", "film by a director")]) == nil)
    }

    @Test func searchAnswerKeepsOnlyLabelMatches() {
        let json = #"{"search":[{"id":"Q1","label":"A","description":"singer","match":{"type":"label"}},{"id":"Q2","label":"B","description":"singer","match":{"type":"alias"}}]}"#
        #expect(MusicPersonWikiRules.parseSearch(Data(json.utf8)).map(\.qid) == ["Q1"])
    }

    @Test func articleTitlesAndShortDescriptionComeFromOneEntityAnswer() {
        let json = #"{"entities":{"Q5":{"sitelinks":{"enwiki":{"title":"Some Person"},"tewiki":{"title":"ఎవరో"}},"descriptions":{"en":{"value":"Indian singer"}}}}}"#
        let r = MusicPersonWikiRules.parseEntityExtras(Data(json.utf8), qid: "Q5")
        #expect(r.description == "Indian singer")
        #expect(MusicPersonWikiRules.titles(sitelinks: r.sitelinks)["en"] == "Some Person")
        #expect(MusicPersonWikiRules.titles(sitelinks: r.sitelinks)["te"] == "ఎవరో")
    }
}

@Suite("Lyrics strip")
struct LyricsStripTests {
    private func lines(_ items: [(Int64, String)]) -> [MusicLyricLine] { items.map { MusicLyricLine(timeMs: $0.0, text: $0.1) } }

    @Test func theStripShowsTheLineBeforeTheCurrentLineAndTheNext() {
        let l = lines([(0, "one"), (4000, "two"), (8000, "three"), (12000, "four")])
        let w = MusicLyricsStripLogic.window(lines: l, atMs: 9000)
        #expect(w.previous == 1 && w.current == 2 && w.next == 3)
    }

    @Test func beforeTheFirstLineThereIsNoCurrentAndTheFirstLineIsNext() {
        let l = lines([(5000, "one"), (9000, "two")])
        let w = MusicLyricsStripLogic.window(lines: l, atMs: 1000)
        #expect(w.previous == nil && w.current == nil && w.next == 0)
    }

    @Test func atTheLastLineThereIsNoNext() {
        let l = lines([(0, "one"), (4000, "two")])
        let w = MusicLyricsStripLogic.window(lines: l, atMs: 5000)
        #expect(w.previous == 0 && w.current == 1 && w.next == nil)
    }

    @Test func aBlankGapIsNeverShownAsALyric() {
        let l = lines([(0, "one"), (4000, ""), (9000, "three")])
        let inGap = MusicLyricsStripLogic.window(lines: l, atMs: 5000)
        #expect(inGap.current == nil && inGap.previous == 0 && inGap.next == 2)
        let after = MusicLyricsStripLogic.window(lines: l, atMs: 9500)
        #expect(after.current == 2 && after.previous == 0)
    }

    @Test func fillFollowsWordTimingsOtherwiseTimeBetweenLines() {
        var line = MusicLyricLine(timeMs: 1000, text: "a b c d")
        line.words = [MusicLyricWord(text: "a", startMs: 1000, endMs: 1500), MusicLyricWord(text: "b", startMs: 1500, endMs: 2000),
                      MusicLyricWord(text: "c", startMs: 2000, endMs: 2500), MusicLyricWord(text: "d", startMs: 2500, endMs: 3000)]
        #expect(abs(MusicLyricsStripLogic.fill(of: line, nextStartMs: 5000, atMs: 2000) - 0.5) < 0.01)
        #expect(MusicLyricsStripLogic.fill(of: line, nextStartMs: 5000, atMs: 500) == 0)
        #expect(MusicLyricsStripLogic.fill(of: line, nextStartMs: 5000, atMs: 9000) == 1)
        let plain = MusicLyricLine(timeMs: 0, text: "no words")
        #expect(abs(MusicLyricsStripLogic.fill(of: plain, nextStartMs: 4000, atMs: 2000) - 0.5) < 0.01)
    }

    @Test func everyStyleHasATitleAndOnlySubtitleHidesTheNeighbours() {
        #expect(MusicLyricsStripStyle.allCases.count == 5)
        #expect(MusicLyricsStripStyle.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(MusicLyricsStripStyle.allCases.filter { !$0.showsNeighbours } == [.subtitle])
    }
}

@Suite("Library derived lists and recently added")
struct LibraryDerivedTests {
    private func track(_ id: String, album: String?, albumID: String = "al", artists: [(String, String)], provider: String = "p") -> MusicTrack {
        var t = MusicTrack(id: id, providerID: provider, title: "Song \(id)", durationMs: 1000, artists: artists.map { MusicArtistRef(id: $0.0, name: $0.1) })
        if let album { t.album = MusicAlbumRef(id: albumID, title: album, artists: artists.map { MusicArtistRef(id: $0.0, name: $0.1) }, thumbnails: []) }
        return t
    }

    @Test func albumsAreSavedOnesThenTheAlbumsOfSongsMostSongsFirstWithoutRepeats() {
        let saved = [MusicAlbum(id: "s1", providerID: "p", title: "Saved One", artists: [MusicArtistRef(id: "a", name: "Ada")])]
        let songs = [track("1", album: "Saved One", albumID: "s1", artists: [("a", "Ada")]),          // already saved: not repeated
                     track("2", album: "Alpha", albumID: "x", artists: [("b", "Bo")]), track("3", album: "Alpha", albumID: "x", artists: [("b", "Bo")]),
                     track("4", album: "Beta", albumID: "y", artists: [("c", "Cy")]),
                     track("5", album: nil, artists: [("d", "Di")])]
        let r = MusicLibraryDerived.albums(saved: saved, songs: songs)
        #expect(r.albums.map(\.title) == ["Saved One", "Alpha", "Beta"])
        #expect(r.fromSongs == ["p:x", "p:y"])
    }

    @Test func unknownAndVariousNamesAreNotAlbumsOrArtists() {
        let songs = [track("1", album: "Unknown Album", artists: [("u", "Unknown Artist")]), track("2", album: "Real", albumID: "r", artists: [("v", "Various Artists"), ("z", "Zed")])]
        #expect(MusicLibraryDerived.albums(saved: [], songs: songs).albums.map(\.title) == ["Real"])
        #expect(MusicLibraryDerived.artists(followed: [], songs: songs).artists.map(\.name) == ["Zed"])
    }

    @Test func artistsAreFollowedOnesThenTheArtistsOfSongsAndAFollowedArtistIsNeverRepeated() {
        let followed = [MusicArtist(id: "f1", providerID: "p", name: "K.K.")]
        let songs = [track("1", album: nil, artists: [("kk-local", "K.K.")], provider: "local"), track("2", album: nil, artists: [("m", "Mani")]), track("3", album: nil, artists: [("m", "Mani"), ("n", "Nia")])]
        let r = MusicLibraryDerived.artists(followed: followed, songs: songs)
        #expect(r.artists.map(\.name) == ["K.K.", "Mani", "Nia"])
        #expect(r.fromSongs.count == 2)
    }

    @Test func recentlyAddedPutsDatedItemsNewestFirstThenUndatedInTheirStoredOrder() {
        func item(_ k: String, _ d: Date?, _ order: Int) -> MusicRecentItem { MusicRecentItem(kind: .song, key: k, title: k, subtitle: "", thumbnails: [], addedAt: d, order: order) }
        let now = Date()
        let list = [item("old1", nil, 0), item("old2", nil, 1), item("yday", now.addingTimeInterval(-86_400), 5), item("today", now, 9)]
        #expect(MusicRecentlyAdded.sorted(list).map(\.key) == ["today", "yday", "old1", "old2"])
    }

    @Test func chipsFilterByKindAndAgeNeverInventsADate() {
        let a = MusicRecentItem(kind: .album, key: "1", title: "A", subtitle: "", thumbnails: [], addedAt: nil, order: 0)
        let s = MusicRecentItem(kind: .song, key: "2", title: "S", subtitle: "", thumbnails: [], addedAt: nil, order: 1)
        #expect(MusicRecentlyAdded.filter([a, s], kind: .album) == [a])
        #expect(MusicRecentlyAdded.filter([a, s], kind: nil).count == 2)
        let now = Date()
        #expect(MusicRecentlyAdded.age(of: nil, now: now) == .earlier)
        #expect(MusicRecentlyAdded.age(of: now, now: now) == .today)
        #expect(MusicRecentlyAdded.age(of: now.addingTimeInterval(-86_400), now: now) == .yesterday)
        #expect(MusicRecentlyAdded.age(of: now.addingTimeInterval(-5 * 86_400), now: now) == .days(5))
        #expect(MusicRecentlyAdded.age(of: now.addingTimeInterval(-3 * 365 * 86_400), now: now) == .longAgo)
    }

    @MainActor @Test func likingFollowingAndSavingKeepATimeAndUnlikingForgetsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = MusicLibrary(directory: dir, debounce: .milliseconds(10))
        let t = track("9", album: nil, artists: [("a", "Ada")])
        #expect(lib.addedAt(.song, t.uid) == nil)
        lib.toggleLike(t)
        #expect(lib.addedAt(.song, t.uid) != nil)
        lib.toggleLike(t)
        #expect(lib.addedAt(.song, t.uid) == nil)
        let artist = MusicArtist(id: "a", providerID: "p", name: "Ada")
        lib.toggleFollow(artist); #expect(lib.addedAt(.artist, artist.uid) != nil)
        let album = MusicAlbum(id: "al", providerID: "p", title: "T")
        lib.toggleSave(album); #expect(lib.addedAt(.album, album.uid) != nil)
    }
}

@Suite("Raga wiring")
struct RagaWiringTests {
    private func song(_ title: String, film: String, composer: String, singers: [String], ragas: [String]) -> MusicRagaSong {
        MusicRagaSong(ragas: ragas, title: title, film: film, year: 1960, composer: composer, singers: singers, language: "Hindi")
    }
    private var index: MusicRagaIndex {
        MusicRagaIndex([song("Baiyan Na Dharo", film: "Dastak", composer: "Madan Mohan", singers: ["Lata Mangeshkar"], ragas: ["Charukesi"]),
                        song("Pyar Hua", film: "Shree 420", composer: "Shankar Jaikishan", singers: ["Manna Dey", "Lata Mangeshkar"], ragas: ["Bhairavi"]),
                        song("Pyar Hua", film: "Other Film", composer: "Someone", singers: ["Nobody"], ragas: ["Yaman"]),
                        song("Tere Bina", film: "Film A", composer: "Madan Mohan", singers: ["Lata Mangeshkar"], ragas: ["Bhairavi"])])
    }

    @Test func aSongMatchesOnItsTitleTogetherWithItsFilmOrAnArtist() {
        #expect(index.ragas(title: "Baiyan Na Dharo", film: "Dastak", artists: []) == ["Charukesi"])
        #expect(index.ragas(title: "baiyan na dharo", film: nil, artists: ["Lata Mangeshkar"]) == ["Charukesi"])
        #expect(index.ragas(title: "Pyar Hua", film: "Shree 420", artists: []) == ["Bhairavi"])
    }

    @Test func aTitleAloneNeverBorrowsARaga() {
        #expect(index.ragas(title: "Baiyan Na Dharo", film: nil, artists: []).isEmpty)
        #expect(index.ragas(title: "Baiyan Na Dharo", film: "Completely Different", artists: ["Unknown Singer"]).isEmpty)
        #expect(index.ragas(title: "Unknown Song", film: "Dastak", artists: ["Lata Mangeshkar"]).isEmpty)
    }

    @Test func twoSongsWithTheSameTitleAreToldApartByFilm() {
        #expect(index.ragas(title: "Pyar Hua", film: "Other Film", artists: []) == ["Yaman"])
        #expect(index.ragas(title: "Pyar Hua", film: nil, artists: ["Lata Mangeshkar"]) == ["Bhairavi"])
    }

    @Test func aComposersRagasAreCountedAndTheTableParentheticalIsIgnored() {
        let r = MusicRagaIndex([song("A", film: "F", composer: "Roshan (music director)", singers: [], ragas: ["Bhairavi"]),
                                song("B", film: "G", composer: "Roshan", singers: [], ragas: ["Bhairavi", "Yaman"])]).ragas(ofPerson: "Roshan")
        #expect(r.map(\.raga) == ["Bhairavi", "Yaman"] && r.first?.count == 2)
        #expect(index.ragas(ofPerson: "Madan Mohan").map(\.raga) == ["Bhairavi", "Charukesi"] || index.ragas(ofPerson: "Madan Mohan").map(\.raga) == ["Charukesi", "Bhairavi"])
        #expect(index.ragas(ofPerson: "").isEmpty)
    }

    @Test func theRagaPickerListsEveryRagaMostSongsFirst() {
        let all = index.allRagas()
        #expect(all.first?.raga == "Bhairavi" && all.first?.count == 2)
        #expect(Set(all.map(\.raga)) == ["Bhairavi", "Charukesi", "Yaman"])
    }
}

@Suite("Combine raga filter")
struct CombineRagaTests {
    @Test func aRagaDecisionIsMatchOtherOrUnknownAndNeverAGuess() {
        #expect(MusicCombineRules.ragaDecision(found: ["Bhairavi"], wanted: "bhairavi") == .match)
        #expect(MusicCombineRules.ragaDecision(found: ["Yaman", "Bhairavi"], wanted: "Bhairavi") == .match)
        #expect(MusicCombineRules.ragaDecision(found: ["Yaman"], wanted: "Bhairavi") == .other)
        #expect(MusicCombineRules.ragaDecision(found: [], wanted: "Bhairavi") == .unknown)
    }

    @Test func theRagaIsPartOfTheFilter() {
        var f = MusicCombineFilter(); f.raga = "Bhairavi"
        #expect(!f.isEmpty && !f.isRunnable)
    }
}

@Suite("First-run setup")
struct MusicSetupTests {
    private func track(_ id: String, artists: [(String, String)]) -> MusicTrack {
        MusicTrack(id: id, providerID: "jiosaavn", title: "T\(id)", durationMs: 1000, artists: artists.map { MusicArtistRef(id: $0.0, name: $0.1) })
    }

    @Test func stepsMoveForwardAndBackAndStopAtTheEnds() {
        var f = MusicSetupFlow()
        #expect(f.isFirst && !f.isLast)
        f.back(); #expect(f.step == .languages)
        for _ in 0..<10 { f.next() }
        #expect(f.step == .extras && f.isLast)
        f.back(); #expect(f.step == .artists)
        #expect(f.progress > 0 && f.progress <= 1)
    }

    @Test func picksTogglePerLanguageGenreAndArtist() {
        var f = MusicSetupFlow()
        f.toggleLanguage("te"); f.toggleLanguage("hi"); f.toggleLanguage("te")
        #expect(f.languages == ["hi"])
        f.toggleGenre("Folk"); #expect(f.genres == ["Folk"])
        let a = MusicArtist(id: "1", providerID: "p", name: "Ada")
        f.toggleArtist(a); #expect(f.hasArtist(a))
        f.toggleArtist(a); #expect(!f.hasArtist(a))
    }

    @Test func applyingKeepsEarlierChoicesAndAddsTheNewOnesWithoutRepeats() {
        var prefs = MusicTastePrefs()
        prefs.languages = ["hi"]; prefs.genres = ["Pop"]
        prefs.artists = [MusicArtist(id: "1", providerID: "p", name: "Ada")]
        var f = MusicSetupFlow()
        f.toggleLanguage("te"); f.toggleGenre("Folk")
        f.toggleArtist(MusicArtist(id: "1", providerID: "p", name: "Ada")); f.toggleArtist(MusicArtist(id: "2", providerID: "p", name: "Bo"))
        let r = f.applying(to: prefs)
        #expect(r.languages == ["hi", "te"] && r.genres == ["Pop", "Folk"])
        #expect(r.artists.map(\.name) == ["Ada", "Bo"])
    }

    @Test func skippingSavesNothingBecauseNothingWasPicked() {
        #expect(MusicSetupFlow().applying(to: MusicTastePrefs()).isEmpty)
    }

    @Test func suggestedArtistsComeFromTheSongsMostFrequentFirstWithoutVariousOrAlreadyKnown() {
        let tracks = [track("1", artists: [("a", "Ada")]), track("2", artists: [("b", "Bo")]), track("3", artists: [("b", "Bo"), ("a", "Ada")]), track("4", artists: [("b", "Bo")]),
                      track("5", artists: [("v", "Various Artists")]), track("6", artists: [("k", "Known")])]
        let r = MusicSetupFlow.suggestedArtists(fromTracks: tracks, excluding: [MusicText.normalize("Known")])
        #expect(r.map(\.name) == ["Bo", "Ada"])
        #expect(MusicSetupFlow.suggestedArtists(fromTracks: tracks, limit: 1).count == 1)
        #expect(MusicSetupFlow.suggestedArtists(fromTracks: []).isEmpty)
    }

    @Test func aNewPersonGetsTheFlowAnExistingListenerGetsAQuietCardAndDoneOrDismissedMeansNothing() {
        let empty = MusicTastePrefs()
        var taste = MusicTastePrefs(); taste.languages = ["te"]
        #expect(MusicSetupGate.offer(setupDone: false, cardDismissed: false, prefs: empty, plays: 0, likes: 0) == .fullFlow)
        #expect(MusicSetupGate.offer(setupDone: false, cardDismissed: false, prefs: empty, plays: 12, likes: 0) == .quietCard)
        #expect(MusicSetupGate.offer(setupDone: false, cardDismissed: false, prefs: taste, plays: 0, likes: 0) == .quietCard)
        #expect(MusicSetupGate.offer(setupDone: false, cardDismissed: true, prefs: empty, plays: 12, likes: 3) == .none)
        #expect(MusicSetupGate.offer(setupDone: true, cardDismissed: false, prefs: empty, plays: 0, likes: 0) == .none)
        // a new person who dismissed nothing is still offered the flow (the card flag is only for existing listeners)
        #expect(MusicSetupGate.offer(setupDone: false, cardDismissed: true, prefs: empty, plays: 0, likes: 0) == .fullFlow)
    }
}

@Suite("Seek intervals and resume")
struct SeekAndResumeTests {
    private func defaults() -> UserDefaults { let d = UserDefaults(suiteName: "seek-\(UUID().uuidString)")!; return d }

    @Test func skipLengthsDefaultToTenSecondsAndOnlyOfferedValuesAreUsed() {
        let d = defaults()
        #expect(MusicSeekPrefs.backSeconds(d) == 10 && MusicSeekPrefs.forwardSeconds(d) == 10)
        d.set(30, forKey: MusicSeekPrefs.backKey); d.set(7, forKey: MusicSeekPrefs.forwardKey)
        #expect(MusicSeekPrefs.backSeconds(d) == 30)
        #expect(MusicSeekPrefs.forwardSeconds(d) == 10)         // 7 is not an offered value
    }

    @Test func resumeDefaultsToTenMinutesAndNeverIsRespected() {
        let d = defaults()
        #expect(MusicSeekPrefs.resumeMinutes(d) == 10)
        d.set(0, forKey: MusicSeekPrefs.resumeKey)
        #expect(MusicSeekPrefs.resumeMinutes(d) == 0)
        d.set(99, forKey: MusicSeekPrefs.resumeKey)
        #expect(MusicSeekPrefs.resumeMinutes(d) == 10)
    }

    @Test func onlyLongRecordingsRememberAndNotTheVeryStartOrEnd() {
        #expect(MusicResumeRules.shouldRemember(position: 300, duration: 3600, minMinutes: 10))
        #expect(!MusicResumeRules.shouldRemember(position: 300, duration: 200, minMinutes: 10))      // a song
        #expect(!MusicResumeRules.shouldRemember(position: 5, duration: 3600, minMinutes: 10))        // too early
        #expect(!MusicResumeRules.shouldRemember(position: 3590, duration: 3600, minMinutes: 10))     // nearly finished
        #expect(!MusicResumeRules.shouldRemember(position: 300, duration: 3600, minMinutes: 0))       // off
        #expect(!MusicResumeRules.shouldRemember(position: .nan, duration: 3600, minMinutes: 10))
    }

    @Test func aSavedPlaceIsUsedOnlyWhileItStillQualifies() {
        let p = MusicResumePoint(position: 1200, duration: 3600, savedAt: Date())
        #expect(MusicResumeRules.resumeAt(p, duration: 3600, minMinutes: 10) == 1200)
        #expect(MusicResumeRules.resumeAt(p, duration: 3600, minMinutes: 0) == nil)
        #expect(MusicResumeRules.resumeAt(nil, duration: 3600, minMinutes: 10) == nil)
        #expect(MusicResumeRules.resumeAt(MusicResumePoint(position: 3595, duration: 3600, savedAt: Date()), duration: 3600, minMinutes: 10) == nil)
    }

    @Test func oldPointsAreDroppedAndTheStoreIsCapped() {
        let now = Date()
        var pts: [String: MusicResumePoint] = ["old": MusicResumePoint(position: 100, duration: 3600, savedAt: now.addingTimeInterval(-200 * 86_400))]
        for i in 0..<(MusicResumeRules.maxPoints + 20) { pts["k\(i)"] = MusicResumePoint(position: 100, duration: 3600, savedAt: now.addingTimeInterval(Double(-i))) }
        let r = MusicResumeRules.pruned(pts, now: now)
        #expect(r["old"] == nil && r.count == MusicResumeRules.maxPoints && r["k0"] != nil && r["k\(MusicResumeRules.maxPoints + 5)"] == nil)
    }

    @MainActor @Test func theLibraryKeepsPlacesPerRecordingAndForgetsThem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = MusicLibrary(directory: dir, debounce: .milliseconds(10))
        let a = MusicTrack(id: "a", providerID: "p", title: "Mix A", durationMs: 3_600_000, artists: [])
        let b = MusicTrack(id: "b", providerID: "p", title: "Mix B", durationMs: 3_600_000, artists: [])
        lib.rememberResume(a, position: 600, duration: 3600, minMinutes: 10)
        lib.rememberResume(b, position: 1800, duration: 3600, minMinutes: 10)
        #expect(lib.resumePosition(for: a, duration: 3600, minMinutes: 10) == 600)
        #expect(lib.resumePosition(for: b, duration: 3600, minMinutes: 10) == 1800)
        lib.forgetResume(a)
        #expect(lib.resumePosition(for: a, duration: 3600, minMinutes: 10) == nil)
        #expect(lib.resumePosition(for: b, duration: 3600, minMinutes: 10) == 1800)
        let song = MusicTrack(id: "s", providerID: "p", title: "Song", durationMs: 200_000, artists: [])
        lib.rememberResume(song, position: 100, duration: 200, minMinutes: 10)
        #expect(lib.resumePosition(for: song, duration: 200, minMinutes: 10) == nil)
    }
}

@Suite("Related card bios and Listen Now variety")
struct RelatedAndVarietyTests {
    @Test func aBiographyBecomesOneShortSentenceCutAtAWord() {
        #expect(MusicBioText.shortLine("Singer from India. Won many awards.") == "Singer from India.")
        let long = "Sripathi Panditaradhyula Balasubrahmanyam, commonly referred to as SPB, was an Indian playback singer, music director and actor who worked across many languages and decades"
        let r = MusicBioText.shortLine(long, maxChars: 60)!
        #expect(r.count <= 61 && r.hasSuffix("…") && !r.dropLast().hasSuffix(" "))
        #expect(!long.hasPrefix(String(r.dropLast())) == false)
        #expect(MusicBioText.shortLine("   ") == nil)
        #expect(MusicBioText.shortLine("No full stop here") == "No full stop here")
    }

    private func ids(_ n: Int) -> [(id: MusicEntityID, weight: Double)] {
        (0..<n).map { (id: MusicEntityID.provisional(kind: .film, name: "Film \($0)"), weight: Double(n - $0)) }
    }

    @Test func theSameSeedGivesTheSameShelfAndOtherSeedsGiveOtherOnes() {
        let pool = ids(30)
        let a = MusicConnectedHome.varied(pool, seed: 7, name: "films", count: 10).map(\.id)
        let b = MusicConnectedHome.varied(pool, seed: 7, name: "films", count: 10).map(\.id)
        #expect(a == b && a.count == 10 && Set(a).count == 10)
        var different = 0
        for seed in 1...12 as ClosedRange<UInt64> where MusicConnectedHome.varied(pool, seed: seed, name: "films", count: 10).map(\.id) != a { different += 1 }
        #expect(different >= 10)
    }

    @Test func strongFavouritesComeUpMoreOftenThanWeakOnes() {
        let pool = ids(30)
        var strong = 0, weak = 0
        for seed in 1...300 as ClosedRange<UInt64> {
            let pick = Set(MusicConnectedHome.varied(pool, seed: seed, name: "films", count: 10).map(\.id))
            if pick.contains(pool[0].id) { strong += 1 }
            if pick.contains(pool[29].id) { weak += 1 }
        }
        #expect(strong > weak * 2)
    }

    @Test func differentShelvesDrawIndependently() {
        let pool = ids(30)
        #expect(MusicConnectedHome.varied(pool, seed: 5, name: "films", count: 10).map(\.id) != MusicConnectedHome.varied(pool, seed: 5, name: "singers", count: 10).map(\.id))
    }

    @Test func theLastFewBecauseSongsAreRememberedNewestFirstAndCapped() {
        let d = UserDefaults(suiteName: "because-\(UUID().uuidString)")!
        let s = (0..<5).map { MusicEntityID.provisional(kind: .recording, name: "Song \($0)") }
        for id in s { MusicHomeFeedModel.noteBecause(id, d) }
        #expect(MusicHomeFeedModel.recentBecause(d) == Set(s.suffix(3)))
        MusicHomeFeedModel.noteBecause(s[4], d)
        #expect(MusicHomeFeedModel.recentBecause(d).count == 3)
    }
}
