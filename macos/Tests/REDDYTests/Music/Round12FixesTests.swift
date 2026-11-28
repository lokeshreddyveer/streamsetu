import Foundation
import Testing
@testable import REDDY

@MainActor @Suite("Round 12 fixes") struct Round12FixesTests {
    @Test func anAlbumWhoseIdIsItsOwnTitleHasNoPage() {
        #expect(!MusicAlbumRef(id: "", title: "Pushpa").hasPage)
        #expect(!MusicAlbumRef(id: "Pushpa", title: "Pushpa").hasPage, "a text-only album arrives with its title as its id")
        #expect(MusicAlbumRef(id: "MPREb_123", title: "Pushpa").hasPage)
    }

    @Test func aSongPageSuggestionNamesTheReasonNotTheSource() {
        let reason = MusicSongReason(kind: .providerSuggestion, subject: "Some Source")
        #expect(!reason.key.contains("%"), "no placeholder: the source's name is never put in the line")
        #expect(reason.key == "Suggested for this song")
    }

    @Test func onlyASingerAPerformerOrAFeaturedArtistIsASingerOnAnAlbum() {
        func edge(_ role: MusicRole?) -> MusicEdge {
            let s = MusicEntityID.provisional(kind: .recording, providerUID: "p:1"), o = MusicEntityID.provisional(kind: .person, providerUID: "p:a")
            if let role { return MusicEdge(subject: s, predicate: .performedBy, object: o, role: role) }
            return MusicEdge(subject: s, predicate: .performedBy, object: o)
        }
        #expect(MusicSoundtrackSinging.isSinger(edge(.singer)))
        #expect(MusicSoundtrackSinging.isSinger(edge(nil)), "a performer with no stated role is a performer")
        #expect(MusicSoundtrackSinging.isSinger(edge(.featured)))
        #expect(!MusicSoundtrackSinging.isSinger(edge(.instrumentalist)))
        #expect(!MusicSoundtrackSinging.isSinger(edge(.conductor)))
        #expect(!MusicSoundtrackSinging.isSinger(edge(.remixer)))
        #expect(!MusicSoundtrackSinging.isSinger(edge(.actor)), "an actor never gets a singing credit")
    }

    @Test func aGuestOrAPausedProfileCannotReplaceTheQueue() {
        let hub = MusicHub.shared
        #expect(hub.canReplaceQueue() == (!hub.gated && !hub.room.controlsLocked))
    }
}
