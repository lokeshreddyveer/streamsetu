import Foundation

/// Atlas entries about Setu itself and the top search box that hands questions to it: the Setu panel's controls, what Setu can and cannot do, the keys in the search box, and the places that open Setu with a ready question.
/// Written from AssistantView, ReddyTopBar, RootView.submitSearch, SearchIntent and the assistant's tool list.
enum AtlasSetu {
    private static func e(_ kind: AtlasKind, _ id: String, _ title: String, _ summary: String, _ path: [String], aliases: [String] = [], detail: String? = nil, platforms: AtlasPlatforms = .all,
                          shortcut: String? = nil, related: [String] = [], reach: AtlasReach = .none, safety: AtlasSafety = .read) -> AtlasEntry {
        .make(id, kind, title, summary, path: path, reach: reach, aliases: aliases, detail: detail, platforms: platforms, shortcut: shortcut, related: related, safety: safety, reviewed: true)
    }

    static let all: [AtlasEntry] = panel + searchBar + handoffs

    // MARK: the Setu panel

    static let panel: [AtlasEntry] = [
        e(.control, "control.setu.shareScreen", "Share my screen with Setu (eye button)", "The eye button in the Setu header. On, Setu is told which screen you are on, what is playing, the title you have open, the text in the search box and your library counts, plus a short summary of what you usually watch. Off, it sees only what you type.",
          ["Setu", "Eye button"], aliases: ["let setu see my screen", "setu cant see what is playing", "stop sharing with the assistant", "turn off setu seeing my screen", "assistant context", "eye icon"],
          detail: "The summary of what you usually watch (top genres and languages) is built on this device from your history. While Watch Privately plays, Setu is told only that you are viewing privately. Nothing is sent online unless you connected an AI service.", related: ["meta.privacySetu", "screen.assistant"]),
        e(.control, "control.setu.newChat", "Start a new chat with Setu", "The circular arrow in the Setu header clears the conversation so the next question starts fresh.", ["Setu", "New chat"],
          aliases: ["clear the chat", "reset setu", "forget the conversation", "start over with setu", "new conversation"], related: ["screen.assistant"]),
        e(.control, "control.setu.modelMenu", "Setu engine menu and Allow online AI services", "The small pill under Setu's name shows the engine in use: Built-in help, Apple Intelligence or a provider you connected. Its menu lists the ready providers with a model, and a switch, Allow online AI services. Off, only the on-device model and your own Ollama are used. On, Setu tries the next model when one fails.",
          ["Setu", "Engine menu"], aliases: ["which model is setu using", "turn off cloud ai", "built-in help", "switch gemini", "change the ai model", "setu engine", "allow online ai", "ai provider"],
          detail: "Built-in help answers questions about the app with no AI and no network. Provider keys are added in Settings, Library, Trakt, Debrid and AI; Setu never sees them.", reach: .settingsPage("Library"), safety: .never),
        e(.control, "control.setu.starterChips", "Setu starter questions", "On an empty chat Setu offers a few tappable questions. Tap one to send it.", ["Setu"], aliases: ["suggested questions", "setu suggestions", "what can i ask setu"], related: ["meta.canDoHere"]),
        e(.control, "control.setu.answerButtons", "Buttons under a Setu answer", "A Setu answer can carry Open this (goes to the screen), Show me (points at the control and opens its screen first if needed), Change it (a setting Setu may change, which you confirm) and other-topic chips. Each button is checked again when you press it.",
          ["Setu"], aliases: ["open this button", "show me button", "change it button", "did you mean chips", "setu buttons"], related: ["meta.setuCanChange"]),
        e(.meta, "meta.setuCanChange", "What Setu can change, and what it never changes", "With a button you confirm, Setu can change about fifty preferences (appearance, playback, subtitles, browsing, library refresh), run playback controls, switch engine or track, refresh playlists or the guide, add favourites and Watch Later, open screens and copy a redacted problem report. It never changes app lock, proxy, VPN, App DNS, parental controls and PINs, profiles, iCloud and network sync, keys and sign-ins, and it never deletes data or resets anything.",
          ["Setu", "What I can do"], aliases: ["can setu change my settings", "does setu delete things", "is it safe to let setu", "what are setu's limits", "setu permissions", "will setu change things without asking"],
          detail: "Every change is a button; the profile, the playback and the screen must still match when you press it.", related: ["screen.assistant", "meta.setuTools"]),
        e(.meta, "meta.setuTools", "What Setu can look up", "Setu answers questions about every screen, setting, shortcut and fix in the app with no AI. It can also search your library and cast, read the TV guide, read the current stream's numbers (engine, bitrate, dropped frames, stalls), check a playlist's health safely (no login is sent), check guide status, summarise your viewing statistics, read Wikipedia summaries for actors and films and, on the Mac, work with Music.",
          ["Setu", "What I can do"], aliases: ["what can you do", "can setu find a movie", "can setu fix buffering", "setu features", "what does setu know", "what can i ask"],
          detail: "When nothing in the app matches a question, Setu says which topics are closest and offers to open the nearest screen instead of guessing.", related: ["meta.canDoHere", "meta.setuCanChange"]),
        e(.shortcut, "shortcut.setu.send", "Send a message to Setu", "Command Return sends what you typed in the Setu panel. Escape closes the panel.", ["Keyboard", "Setu"], aliases: ["send to setu with keyboard", "close setu with escape", "setu keyboard"],
          platforms: .mac, shortcut: "⌘↩", related: ["screen.assistant"]),
    ]

    // MARK: the top search box

    static let searchBar: [AtlasEntry] = [
        e(.control, "control.search.topBar", "Search or ask Setu (top search box)", "The box at the top reads Search or ask Setu. Type a title, channel, person or command and the results appear below as you type. Type a question or request (how do I, why is, open, turn on, or the same in Hinglish or Telugu) and the first row becomes Ask Setu with your words.",
          ["Top bar", "Search"], aliases: ["search box", "search bar", "top search", "ask setu from the search bar", "search or ask", "where do i ask setu", "type a question in search"],
          detail: "Return with no row highlighted asks Setu when the text reads as a question or request and searches otherwise. A row you highlight with the arrow keys always opens, so a song called How Deep Is Your Love is never turned into a question. In a kids profile the box only searches.",
          platforms: .mac, shortcut: "⌘K", related: ["control.search.askSetuRow", "shortcut.search.askSetu", "shortcut.search.forceAsk", "shortcut.search.forceSearch"]),
        e(.control, "control.search.askSetuRow", "Ask Setu row in the search results", "The first row under the search box, Ask Setu followed by your words, with Setu's sparkle icon. Press Return or click it to send the text to Setu; the results close and Setu answers. It is shown for anything you type, and it is the strong, tinted row (Return is its key) when the text reads as a question or request; for a plain title it is quieter and its key is Command Return.",
          ["Top bar", "Search", "Ask Setu row"], aliases: ["ask setu row", "ask setu from search results", "send my search to setu", "setu row in search"], platforms: .mac, shortcut: "↩", related: ["control.search.topBar"]),
        e(.shortcut, "shortcut.search.askSetu", "Return in the search box asks Setu for a question", "In the top search box, plain Return sends what you typed to Setu when it reads as a question or request (how, why, where, can I, open, turn on, my guide is empty, kaise, ela...), unless you highlighted a result row, which opens instead. Command Return always asks Setu. Anything else opens the best result, then the best screen or setting, and only then asks Setu. Not in a kids profile.",
          ["Keyboard", "Search"], aliases: ["command return search", "ask setu from search", "what does cmd return do in search", "return asks setu", "search or ask rule"], platforms: .mac, shortcut: "⌘↩", related: ["control.search.topBar"], reach: .searchCommand("focus")),
        e(.shortcut, "shortcut.search.forceAsk", "Shift Return in the search box always asks Setu", "Hold Shift and press Return in the top search box to send the text to Setu even when it looks like a title, whatever row is highlighted.", ["Keyboard", "Search"],
          aliases: ["force ask setu", "shift enter search", "make search ask setu"], platforms: .mac, shortcut: "⇧↩", related: ["control.search.topBar"]),
        e(.shortcut, "shortcut.search.forceSearch", "Option Return in the search box always searches", "Hold Option and press Return in the top search box to search even when the text looks like a question (for a title such as How Do I Live). With no result it does nothing instead of asking Setu.", ["Keyboard", "Search"],
          aliases: ["force search", "option enter search", "search instead of asking setu", "stop search asking setu"], platforms: .mac, shortcut: "⌥↩", related: ["control.search.topBar"]),
    ]

    // MARK: places that open Setu with a ready question

    static let handoffs: [AtlasEntry] = [
        e(.control, "control.settings.askSetu", "Ask Setu (Settings header)", "The button at the top of the Settings window opens Setu with a ready question and brings the main window forward, so you can ask about the setting you are looking at.", ["Settings", "Ask Setu"],
          aliases: ["help in settings", "ask for help with a setting", "ask setu about settings"], platforms: .mac, related: ["screen.assistant"]),
        e(.control, "control.addSource.helpMeWithThis", "Help me with this (Add Playlist)", "In the Add Playlist window, opens Setu with a question about the kind of source you are filling in (Xtream, M3U, Jellyfin, Emby, Plex and so on) so it can list the fields and what to type.", ["Add Playlist", "Help me with this"],
          aliases: ["i dont know what to enter", "setu help add source", "help me add a playlist", "what do i type here"], platforms: .mac, related: ["screen.assistant"]),
        e(.intent, "intent.openSetting", "Open a Setting (Siri and Shortcuts)", "The Shortcuts action Open a Setting, and Open a target in StreamSetu, jumps to a screen or setting that Setu knows about.", ["Siri and Shortcuts"],
          aliases: ["siri open a setting", "shortcut to jump to a screen", "open settings with siri"], platforms: [.iPhone, .iPad], related: ["intent.askSetu"]),
    ]
}
