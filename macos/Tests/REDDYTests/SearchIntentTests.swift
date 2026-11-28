import Foundation
import Testing
@testable import REDDY

/// `SearchIntent` decides what a bare Return in the top search box does when no row is highlighted: a question or request goes to Setu, a title is searched. These tables are the contract: requests in English,
/// Hinglish and Telugu in Latin letters must ask; titles that merely look like questions must search; and a highlighted row always opens.
@Suite("Search intent: search or ask") struct SearchIntentTests {
    static let requests: [String] = [
        "how do I turn on subtitles",
        "how to fix buffering",
        "why is my guide empty",
        "where is my backup",
        "can I change the theme",
        "open settings",
        "turn on subtitles",
        "turn off the sleep timer",
        "play something relaxing",
        "play my favourites",
        "my guide is empty again today",
        "subtitles not working",
        "login error 401",
        "backup failed",
        "how do i add an xtream playlist",
        "where do i find the equalizer",
        "what does crossfade do",
        "is my backup running?",
        "kaise subtitles on kare",
        "subtitles kaise on kare",
        "queue clear kaise",
        "song play ela",
        "lyrics kaise dekhe",
        "sound nahi aa raha",
        "guide khali kyun hai",
        "queue ekkada undi",
        "help",
        "setu how do i add a playlist",
        "show me my favourites",
        "how can i download songs for offline",
        "why won't the app lock open",
        "tell me how to use the sleep timer",
        "i want to change the language",
        "i cant hear any audio",
        "enable subtitles",
        "disable notifications",
        "change the theme to dark",
        "why cant i see lyrics",
        "where is the side panel button",
        "how do i change country for charts",
        "ela subtitles on cheyali",
        "crossfade ela on cheyali",
        "reminders not working",
        "icloud sync not working",
        "download failed",
        "recording failed",
        "where is my queue",
        "how do i make a kids profile",
        "explain smart mix settings"
    ]

    static let titles: [String] = [
        "How Deep Is Your Love",
        "Where Is My Mind",
        "Who Framed Roger Rabbit?",
        "How To Train Your Dragon",
        "Kaise Hua",
        "Kyun Ki",
        "Kahan Ho Tum",
        "Inception",
        "Breaking Bad",
        "Open Season",
        "Show Me the Money",
        "Show Me Love",
        "Why Don't We Just Dance",
        "Can't Stop the Feeling",
        "Is This Love",
        "Do I Wanna Know?",
        "What Is Love",
        "What's Up Doc",
        "I Want to Break Free",
        "Tell Me Why",
        "Help Me Rhonda",
        "Set It Off",
        "Stop Making Sense",
        "Clear and Present Danger",
        "Turn Up the Music",
        "How Do I Live",
        "Why Does It Always Rain on Me",
        "Where Is the Love",
        "Who Let the Dogs Out",
        "Are You Gonna Go My Way",
        "Will It Rain",
        "Is There Anybody Out There",
        "Go to Hell",
        "Open Water",
        "Add It Up",
        "Start Me Up",
        "Change of Heart",
        "Fix You",
        "Play That Funky Music",
        "Play Dirty",
        "How I Met Your Mother",
        "Can I Get a Witness",
        "Kaisi Paheli",
        "Ela Ela",
        "Tum Hi Ho",
        "Aaj Ki Raat",
        "Telugu movies 2024",
        "bbc one",
        "star wars",
        "Naatu Naatu",
        "Mere Mehboob Qayamat Hogi",
        "What If...?",
        "Why Him?",
        "Where the Wild Things Are",
        "Can You Feel the Love Tonight",
        "Do You Want to Build a Snowman",
        "Is It Wrong to Try to Pick Up Girls in a Dungeon?",
        "Stuck in the Middle with You",
        "Missing Link",
        "Broken Arrow",
        "Empty Chairs",
        "",
        "  ",
        "The Lion King",
        "Kantara",
        "Pushpa 2",
        "Tere Naam",
        "Kabhi Khushi Kabhie Gham"
    ]

    @Test func requestsAndQuestionsAskSetu() {
        #expect(Self.requests.count >= 45)
        for q in Self.requests { #expect(SearchIntent.classify(q) == .ask, "\(q)") }
    }

    @Test func titlesThatLookLikeQuestionsStillSearch() {
        #expect(Self.titles.count >= 45)
        for q in Self.titles { #expect(SearchIntent.classify(q) == .search, "\(q)") }
    }

    @Test func emptyAndBlankTextSearches() {
        #expect(SearchIntent.classify("") == .search)
        #expect(SearchIntent.classify("   ") == .search)
        #expect(SearchIntent.classify("?") == .search)
    }

    @Test func caseAndPunctuationDoNotChangeTheClass() {
        for q in ["HOW DO I TURN ON SUBTITLES", "how do i turn on subtitles!!", "  How do I turn on subtitles?  ", "How do I turn on subtitles"] { #expect(SearchIntent.classify(q) == .ask, "\(q)") }
        for q in ["HOW DEEP IS YOUR LOVE", "how deep is your love?", "  how deep is your love  "] { #expect(SearchIntent.classify(q) == .search, "\(q)") }
    }

    // MARK: what Return does

    @Test func aHighlightedRowAlwaysOpensEvenForATitleThatReadsLikeAQuestion() {
        let title = "How Deep Is Your Love"
        #expect(SearchIntent.returnAction(query: title, mode: .automatic, hasHighlightedRow: true) == .openHighlighted)
        #expect(SearchIntent.returnAction(query: "how do i turn on subtitles", mode: .automatic, hasHighlightedRow: true) == .openHighlighted)
    }

    @Test func bareReturnWithNoHighlightFollowsTheClassification() {
        #expect(SearchIntent.returnAction(query: "how do i turn on subtitles", mode: .automatic, hasHighlightedRow: false) == .ask)
        #expect(SearchIntent.returnAction(query: "How Deep Is Your Love", mode: .automatic, hasHighlightedRow: false) == .search)
        #expect(SearchIntent.returnAction(query: "Inception", mode: .automatic, hasHighlightedRow: false) == .search)
    }

    @Test func shiftReturnForcesAskAndOptionReturnForcesSearch() {
        #expect(SearchIntent.returnAction(query: "Inception", mode: .forceAsk, hasHighlightedRow: false) == .ask)
        #expect(SearchIntent.returnAction(query: "Inception", mode: .forceAsk, hasHighlightedRow: true) == .ask)
        #expect(SearchIntent.returnAction(query: "how do i turn on subtitles", mode: .forceSearch, hasHighlightedRow: false) == .search)
        #expect(SearchIntent.returnAction(query: "how do i turn on subtitles", mode: .forceSearch, hasHighlightedRow: true) == .openHighlighted)
    }

    @Test func returnWithNothingTypedDoesNothing() {
        for m in [SearchIntent.ReturnMode.automatic, .forceAsk, .forceSearch] { #expect(SearchIntent.returnAction(query: "  ", mode: m, hasHighlightedRow: false) == .nothing) }
    }

    @Test func theTopBarPlaceholderInvitesAQuestionOnlyWhereSetuIsAvailable() {
        let on = TopBarState(tab: .home, initials: "A", accountMenuOpen: false, width: 1400)
        #expect(on.searchPlaceholder(narrow: false) == "Search or ask Setu")
        let kids = TopBarState(tab: .home, initials: "A", accountMenuOpen: false, width: 1400, askEnabled: false)
        #expect(kids.searchPlaceholder(narrow: false) == "Search everything")
    }
}
