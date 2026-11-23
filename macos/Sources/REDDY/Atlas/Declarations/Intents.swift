import Foundation

/// What Siri, the Shortcuts app and Spotlight can do with StreamSetu on iPhone and iPad (ios/StreamSetu/Intents/StreamSetuIntents.swift), and the Setu button.
enum AtlasIntents {
    private static func intent(_ id: String, _ title: String, _ summary: String, aliases: [String] = [], path: [String] = ["Siri and Shortcuts"], detail: String? = nil, related: [String] = []) -> AtlasEntry {
        .make("intent.\(id)", .intent, title, summary, path: path, aliases: aliases + ["siri", "shortcuts app", "voice command"], detail: detail, platforms: [.iPhone, .iPad], related: related, reviewed: true)
    }

    static let all: [AtlasEntry] = [
        intent("playChannel", "Play a Channel", "Starts a live channel from your playlists. In Siri say “Play <channel> in StreamSetu” or “Watch <channel> on StreamSetu”, or add the action Play a Channel in the Shortcuts app and pick the channel. The app opens and the channel plays.",
               aliases: ["play channel with siri", "hey siri play", "watch channel by voice", "voice play channel", "shortcut play channel"],
               detail: "Siri suggests your favourite channels first and searches the channel names in your library. If it cannot find the channel it says so.", related: ["screen.tab.liveTV"]),
        intent("pausePlayback", "Pause StreamSetu", "Pauses what is playing. In Siri say “Pause StreamSetu”, or use the Pause StreamSetu action in the Shortcuts app.", aliases: ["pause with siri", "voice pause", "hey siri pause"], related: ["intent.resumePlayback"]),
        intent("resumePlayback", "Resume StreamSetu", "Continues what was paused. In Siri say “Resume StreamSetu”, or use the Resume StreamSetu action in the Shortcuts app.", aliases: ["resume with siri", "voice play", "continue playback by voice"], related: ["intent.pausePlayback"]),
        intent("stopPlayback", "Stop StreamSetu", "Stops playback. It is an action in the Shortcuts app named Stop StreamSetu. It has no spoken phrase of its own, so Siri needs a shortcut you make with that action.", aliases: ["stop with siri", "stop by voice"], related: ["menu.playback.stop"]),
        intent("sleepTimer", "Set a Sleep Timer", "Stops playback after the number of minutes you give, from 1 to 600; 30 is the default. In Siri say “Set a sleep timer in StreamSetu”. If nothing is playing it says so and sets nothing.",
               aliases: ["sleep timer with siri", "stop playing in 30 minutes", "fall asleep timer", "timer by voice"], related: ["menu.playback.sleepTimer"]),
        intent("nextChannel", "Next Channel", "Switches to the next channel in the list you are watching from. In Siri say “Next channel in StreamSetu”.", aliases: ["next channel by voice", "channel up siri", "change channel siri"], related: ["menu.playback.nextChannel", "gesture.ios.playerZap"]),
        intent("askSetu", "Ask Setu", "On iPhone and iPad, Setu is the round sparkles button at the bottom right of the screen, labelled Setu assistant. Tap it and a sheet opens on iPhone, or a popover on a wide iPad, where you type a question. The button is hidden in a kids profile, while the keyboard is up and while the chat is open. There is no Siri phrase for Ask Setu yet.",
               aliases: ["setu", "assistant", "ask the assistant", "help button", "sparkles button", "chat", "where is setu", "ask for help", "ai helper", "talk to the app"], path: ["Setu button"],
               detail: "On the Mac the same button sits at the bottom right and opens a chat above it.", related: ["setting.integrations"]),
    ]
}
