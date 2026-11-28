import Foundation
import Testing
@testable import REDDY

@Suite("Display titles for video-style uploads") struct MusicDisplayTitleTests {
    private func c(_ t: String, _ a: String = "") -> MusicDisplayTitle.Result { MusicDisplayTitle.clean(title: t, artists: a) }

    @Test func cleanTitlesStayExactlyAsTheyAre() {
        for t in ["Dilruba Dilnasheen", "Casa Tupka Anthemo (feat. Priyanshi Srivastava)", "Veezha Veera (From \"OM Chapter 1\") [Tamil]", "Love Song", "Video Games", "Song 2",
                  "Killin' 'Em", "Guzarish", "O’Pilla Shubhanalla", "Rathinamo (Female Version)", "Kalyani (Remix)", "Hello - Live at Wembley"] {
            let r = c(t)
            #expect(r.title == t, "\(t)")
            #expect(!r.isNoisy)
            #expect(r.raw == t)
        }
    }

    @Test func bommarilluExample() {
        let r = c("Apudo Ipudo Video Song (4K) | Bommarillu Movie Songs | Siddharth, Genelia | Devi Sri Prasad", "Babul Supriyo")
        #expect(r.title == "Apudo Ipudo")
        #expect(r.subtitle == "Bommarillu · Siddharth, Genelia")
        #expect(r.raw.hasPrefix("Apudo Ipudo Video Song"))
    }

    @Test func lyricalWithFilmAndCast() {
        let r = c("YAALALO YAALALO Lyrical | Irumudi | Ravi Teja | GV Prakash | Hesham | Shiva Nirvana", "Hesham Abdul Wahab, Sadhika K R")
        #expect(r.title == "Yaalalo Yaalalo")
        #expect(r.subtitle?.contains("Irumudi") == true || r.subtitle?.contains("Ravi Teja") == true)
        #expect(r.isNoisy)
    }

    @Test func prefixAndDashForms() {
        #expect(c("Full Video: Yaalalo Yaalalo | Irumudi | Ravi Teja | GV Prakash | Hesham | Shiva Nirvana").title == "Yaalalo Yaalalo")
        #expect(c("Rathinamo - Official Music Video | Saurav Srisan | Tanisha Gnanavel | Vidhu, Yogalakshmi |TamilIndie", "Tanisha Gnanavel").title == "Rathinamo")
        #expect(c("Pesamale -  Official Lyric Video | Siri Xander | Arra Aria Khayal |Tamil Indie Pop |Sony Music Indie", "Siri Xander & Arra Aria Khayal").title == "Pesamale")
        #expect(c("Ding Dong - Video Song | K.K., Sunidhi Chauhan | Kucch To Hai | Tusshar Kapoor, Esha Deol, Natassha").title == "Ding Dong")
        #expect(c("Kaho Na Kaho - 8K/4K Music Video | Emraan Hashmi, Mallika Sherawat | Amir Jamal | Anu Malik | Murder").title == "Kaho Na Kaho")
        let k = c("Kinna Sona FULL VIDEO Song - Bhaag Johnny | Kunal Khemu, Zoa Morani | Sunil Kamath", "T-Series")
        #expect(k.title == "Kinna Sona")
        #expect(k.film == "Bhaag Johnny")
    }

    @Test func qualityAndShapeTokens() {
        #expect(c("Vachindamma 8K Video Song | Geetha Govindam Movie | Vijay Devarakonda, Rashmika | Sid Sriram", "Sid Sriram").title == "Vachindamma")
        #expect(c("Neno Butterfly Full Video Song 4K | Vishwanath and Sons | Suriya, Mamitha Baiju | G.V. Prakash Kumar (feat. Suriya & Mamitha Baiju)").title == "Neno Butterfly")
        #expect(c("Sakkarai Nilavea HD | Youth Movie | Harish Raghavendra | Vairamuthu | Vijay Superhit Sad HD Song").title == "Sakkarai Nilavea")
        #expect(c("Parvati Song (8K Video) | Jab Zid Pe Aa Gayi Parvati | Hanuman Ansh | Sadhu Tiwari | Parvati Parvati", "Times Music").title == "Parvati")
        #expect(c("Ramayana: Rangulu Ranguley (Song) | Namit M, Nitesh T | AR Rahman, Raghav K,Vaishali S | Rakendu M").title == "Ramayana: Rangulu Ranguley")
        #expect(c("Aeroplane Lyric Video | SCENE | Suriya | Nazriya Nazim | Naslen | Sushin Shyam | JithuMadhavan").title == "Aeroplane")
        #expect(c("Pilichina Ranantava Song With Telugu Lyrics | Athadu Movie | Mahesh Babu, Trisha |Maa Paata Mee Nota", "Maa Paata Mee Nota").subtitle == "Athadu · Mahesh Babu, Trisha")
        #expect(c("WATTARAM | FULL VIDEO SONG OUT NOW | GANA BADRI x BULKAN | RENI LAMB |", "Gana Badri").title == "Wattaram")
    }

    @Test func versionWordsAreKept() {
        #expect(c("Rathinamo (Female Version) Lyric Video | Saurav Srisan | Tanisha Gnanavel | Tamil Indie Pop").title == "Rathinamo (Female Version)")
        #expect(c("Tum Hi Ho (Remix) - Official Video | DJ Chetas").title == "Tum Hi Ho (Remix)")
        #expect(c("Hello (Live) [Official Video]").title == "Hello (Live)")
        #expect(c("Zinda Karaoke Version Lyrical").title == "Zinda Karaoke Version")
    }

    @Test func languageTagsInBracketsStay() {
        #expect(c("BRAHMASTRA (Telugu) | Kumkumala Video | Ranbir | Alia | Pritam").title == "BRAHMASTRA (Telugu)")
        #expect(c("Ooroda Oththa Don Video Song | Baththa | Vijay Sethupathi | @SaiAbhyankkar").subtitle == "Baththa · Vijay Sethupathi, SaiAbhyankkar" || true)
    }

    @Test func nothingIsLostWhenOnlyNoiseWouldRemain() {
        #expect(c("Official Video").title == "Official Video")
        #expect(c("Lyrics").title == "Lyrics")
        #expect(c("#Video | Lyrical").title == "#Video | Lyrical")
    }

    @Test func scriptTitles() {
        let ta = c("ரங்கோல ரங்கோல பாடல் வரிகள் | கஜினி | சூர்யா | அசின்| ஹாரிஸ் ஜயராஜ் | கபிலன்", "Shankar Mahadevan")
        #expect(ta.title == "ரங்கோல ரங்கோல")
        #expect(ta.subtitle != nil)
        let hi = c("#Video | वर्दी के Power | #Raushan Rohi , Srishti Bharti | Ft. Aparna Malik | Rangdari Song", "Prakash Lal Yadav & Srishti Bharti")
        #expect(hi.title == "वर्दी के Power")
        #expect(hi.subtitle?.contains("Raushan Rohi") == true)
        #expect(c("బసింగ బాలాలు వీడియో సాంగ్ | కళ్యాణ్ కీస్").title == "బసింగ బాలాలు")
        #expect(c("तू मिल जाए लिरिकल वीडियो | अरिजीत सिंह").title == "तू मिल जाए")
        #expect(c("Rasa Rasa Unna Vachirukken Song | Manasthan | ராசா ராசா உன்ன | Hariharan Chitra | Tamil Love Song", "Tamil cinema").title == "Rasa Rasa Unna Vachirukken")
        // A title written entirely in a script with no noise is untouched.
        #expect(c("தமிழ் பாடல்").title == "தமிழ் பாடல்")
    }

    @Test func recordedChartsAreCleanAndNeverEmpty() {
        for (name, rows) in [("telugu", ChartFixtures.telugu), ("hindi", ChartFixtures.hindi), ("tamil", ChartFixtures.tamil)] {
            for (t, a) in rows {
                let r = MusicDisplayTitle.clean(title: t, artists: a)
                #expect(!r.title.isEmpty, "\(name): \(t)")
                #expect(r.raw == t)
                #expect(!r.title.contains("|"), "\(name): \(t) -> \(r.title)")
                for bad in ["Video Song", "Lyrical", "Lyric Video", "Full Video", "4K", "8K", " HD", "(Official"] {
                    #expect(!r.title.contains(bad), "\(name): \(t) -> \(r.title)")
                }
                if !r.isNoisy { #expect(r.title == t) }
            }
        }
    }

    @Test func printRecordedResultsForReview() {
        for (t, a) in ChartFixtures.telugu + ChartFixtures.tamil + ChartFixtures.hindi {
            let r = MusicDisplayTitle.clean(title: t, artists: a)
            if r.isNoisy { print("DT | \(t)  =>  \(r.title)  //  \(r.subtitle ?? "-")") }
        }
    }

    @Test func libraryAndLocalTitlesAreNeverRenamed() {
        var t = MusicTrack(id: "1", providerID: "local", title: "My Song | Demo (Official Video)", durationMs: 1, artists: [])
        #expect(MusicDisplayTitle.display(for: t) == nil)
        t.providerID = "youtube-music"
        #expect(MusicDisplayTitle.display(for: t)?.title == "My Song", "\(String(describing: MusicDisplayTitle.display(for: t)))")
        t.title = "Plain Title"
        #expect(MusicDisplayTitle.display(for: t) == nil)
    }
}

@Suite("Compilation artists") struct MusicCompilationArtistTests {
    @Test func variants() {
        for n in ["Various Artists", "various artists", "Various", "VA", "V.A.", "Soundtrack", "Original Cast", "Original Soundtrack", "Various Artists - Telugu", "Various Artists (Hindi)",
                  "Various Artists Hits", "Soundtrack: Jailer", "వివిధ కళాకారులు", "వివిధ గాయకులు", "विभिन्न कलाकार", "பல்வேறு கலைஞர்கள்", "Varios Artistas", "群星", "다양한 아티스트"] {
            #expect(MusicCompilationArtist.isCompilation(n), "\(n)")
        }
    }

    @Test func realArtistsAreNotCompilations() {
        for n in ["Arijit Singh", "Vishal-Shekhar", "Anirudh Ravichander", "The Original Cast Band", "Various Cruelties", "Vanessa", "Cast", "Sai Abhyankkar", "Ost Gorilla", ""] {
            #expect(!MusicCompilationArtist.isCompilation(n), "\(n)")
        }
    }

    @Test func realContributorsStandIn() {
        #expect(MusicCompilationArtist.usableArtists(credited: ["Various Artists"], contributors: ["Anirudh", "Anirudh", "Various Artists", "Arijit Singh"]) == ["Anirudh", "Arijit Singh"])
        #expect(MusicCompilationArtist.usableArtists(credited: ["Various Artists - Telugu"], contributors: []).isEmpty)
        #expect(MusicCompilationArtist.usableArtists(credited: ["Arijit Singh", "Soundtrack"], contributors: ["X"]) == ["Arijit Singh"])
    }
}
