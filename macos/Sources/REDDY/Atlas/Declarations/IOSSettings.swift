import Foundation

/// Controls on the iPhone and iPad Settings pages that have no settings-catalogue entry. Plain data; the text was written from reading the iPhone and iPad code. Each id is used by an `.atlas("...")` marker in ios/StreamSetu.
enum AtlasIOSSettings {
    private static let phone: AtlasPlatforms = [.iPhone, .iPad]

    private static func c(_ id: String, _ title: String, _ summary: String, _ path: [String], safety: AtlasSafety = .read, reviewed: Bool = false) -> AtlasEntry {
        .make(id, .control, title, summary, path: path, platforms: phone, safety: safety, guideOnly: safety == .never, reviewed: reviewed)
    }
    private static func s(_ id: String, _ title: String, _ summary: String, _ path: [String], reviewed: Bool = false) -> AtlasEntry {
        .make(id, .screen, title, summary, path: path, platforms: phone, reviewed: reviewed)
    }

    static let all: [AtlasEntry] = screens + controls

    private static let screens: [AtlasEntry] = [
        s("screen.ios.settings.backup", "Backup and Restore", "Create a backup file, restore from one, and see automatic backups kept on this device.", ["Settings", "Backup and Restore"], reviewed: true),
        s("screen.ios.settings.storage", "Storage and Maintenance", "Clear caches, check and tidy the database, make a diagnostic report, and clear history or remove everything.", ["Settings", "Storage and Maintenance"], reviewed: true),
    ]

    private static let controls: [AtlasEntry] = [
        c("control.ios.alerts.lookNow", "Look Now", "Looks through the guide for the next day and a half for programmes that match your alert words, and sets a reminder for each.", ["Settings", "Subscriptions and Alerts", "Look Now"], reviewed: true),
        c("control.ios.appDNS.clearCache", "Clear DNS Cache", "Forgets the names the app has already looked up.", ["Settings", "App DNS", "Clear DNS Cache"], reviewed: true),
        c("control.ios.appDNS.localSystem", "Use system DNS for local devices", "Keeps addresses on your own network on the normal system DNS.", ["Settings", "App DNS", "Use system DNS for local devices"], reviewed: true),
        c("control.ios.appDNS.provider", "DNS provider", "Opens the list of secure DNS services; tap one to look names up through it.", ["Settings", "App DNS", "DNS provider"], reviewed: true),
        c("control.ios.appDNS.test", "Test App DNS", "Checks that the chosen DNS service answers and can look up your playlist provider and guide.", ["Settings", "App DNS", "Test App DNS"], reviewed: true),
        c("control.ios.appearance.customApply", "Apply custom theme", "Uses the colours and gloss you set in the custom theme editor. It shows when the Custom theme is chosen.", ["Settings", "Appearance", "Apply custom theme"], reviewed: true),
        c("control.ios.appearance.customReset", "Start Again", "Puts the custom theme back to the standard colours.", ["Settings", "Appearance", "Start Again"], reviewed: true),
        c("control.ios.appearance.replayStory", "Replay the Full Story", "Plays the full opening story again.", ["Settings", "Appearance", "Replay the Full Story"], reviewed: true),
        c("control.ios.artwork.cellular", "Use mobile data", "Lets artwork matching use mobile data as well as Wi-Fi.", ["Settings", "Artwork and Details", "Use mobile data"], reviewed: true),
        c("control.ios.artwork.matchNow", "Match now", "Starts matching posters and details straight away. It needs background matching switched on.", ["Settings", "Artwork and Details", "Match now"], reviewed: true),
        c("control.ios.artwork.trending", "Use TMDB weekly trending", "Ranks Top This Week and Trending in Your Library by this week's trending titles.", ["Settings", "Artwork and Details", "Use TMDB weekly trending"], reviewed: true),
        c("control.ios.backup.apply", "Restore", "Brings back everything the backup contains. Nothing is deleted; matching items are merged.", ["Settings", "Backup and Restore", "Restore"], reviewed: true),
        c("control.ios.backup.create", "Create Backup", "Saves the items ticked under Include to a file you can keep or share. Playlists are saved without passwords.", ["Settings", "Backup and Restore", "Create Backup"], reviewed: true),
        c("control.ios.backup.now", "Back Up Now", "Makes an automatic backup on this device right now.", ["Settings", "Backup and Restore", "Back Up Now"], reviewed: true),
        c("control.ios.backup.option", "What to include", "A switch for each kind of data that goes into a new backup.", ["Settings", "Backup and Restore", "What to include"], reviewed: true),
        c("control.ios.backup.restore", "Restore from a File", "Reads a backup file and shows what it contains before anything is restored.", ["Settings", "Backup and Restore", "Restore from a File"], reviewed: true),
        c("control.ios.backup.restoreAuto", "Restore an automatic backup", "Opens one of the automatic backups kept on this device (the latest five) and shows what it contains.", ["Settings", "Backup and Restore", "Restore an automatic backup"], reviewed: true),
        c("control.ios.channelManager.autoMatch", "Use Automatic Matching", "Lets the app match the channel to the guide by itself again. It shows when you picked a guide entry.", ["Settings", "Channel Manager", "Use Automatic Matching"], reviewed: true),
        c("control.ios.channelManager.edit", "Edit a channel", "Opens the channel to rename it, set its guide entry or reset it. Swipe a channel to hide or show it.", ["Settings", "Channel Manager", "Edit a channel"], reviewed: true),
        c("control.ios.channelManager.filter", "Channel filter", "Shows all channels, only hidden ones, only changed ones, or only channels with no guide.", ["Settings", "Channel Manager", "Channel filter"], reviewed: true),
        c("control.ios.channelManager.guideEntry", "Choose guide entry", "Pick the guide entry that belongs to this channel.", ["Settings", "Channel Manager", "Choose guide entry"], reviewed: true),
        c("control.ios.channelManager.reset", "Reset Changes", "Removes your rename and guide entry for this channel.", ["Settings", "Channel Manager", "Reset Changes"], safety: .never, reviewed: true),
        c("control.ios.channelManager.save", "Save channel changes", "Saves the new name and guide entry.", ["Settings", "Channel Manager", "Save channel changes"], reviewed: true),
        c("control.ios.crashReports.deleteAll", "Delete All crash reports", "Removes every saved crash report.", ["Settings", "About", "Crash Reports", "Delete All crash reports"], safety: .never, reviewed: true),
        c("control.ios.crashReports.keep", "Keep crash reports", "Saves crash reports on this device so you can look at them and share them. Off by default.", ["Settings", "About", "Crash Reports", "Keep crash reports"], reviewed: true),
        c("control.ios.feedback.autoShare", "Share playback logs automatically", "Sends the recent playback log to the developer when a stream fails for good, without asking each time. Off by default.", ["Settings", "About", "Send Feedback", "Share playback logs automatically"], reviewed: true),
        c("control.ios.feedback.clearLog", "Clear Playback Log", "Deletes the saved playback log on this device.", ["Settings", "About", "Send Feedback", "Clear Playback Log"], safety: .never, reviewed: true),
        c("control.ios.feedback.diagnostics", "Include diagnostics", "Adds a short technical summary to a problem report. It never holds logins, passwords or full stream addresses.", ["Settings", "About", "Send Feedback", "Include diagnostics"], reviewed: true),
        c("control.ios.feedback.sendEmail", "Send by Email", "Opens your mail app with the message ready.", ["Settings", "About", "Send Feedback", "Send by Email"], reviewed: true),
        c("control.ios.feedback.sendLog", "Send My Log Now", "Sends the playback log straight away.", ["Settings", "About", "Send Feedback", "Send My Log Now"], reviewed: true),
        c("control.ios.feedback.type", "Feedback type", "Choose Problem or Idea or feature request.", ["Settings", "About", "Send Feedback", "Feedback type"], reviewed: true),
        c("control.ios.folders.section", "Folder section", "Chooses whether to organise Live TV, Movies or Series folders.", ["Settings", "Library and Guide", "Folder section"], reviewed: true),
        c("control.ios.health.reset", "Reset These Numbers", "Clears the playback counts and times on this device.", ["Settings", "Playback Health", "Reset These Numbers"], safety: .never, reviewed: true),
        c("control.ios.health.sendLog", "Send My Log", "Sends the playback log to the developer. Shown only in builds that can send logs.", ["Settings", "Playback Health", "Send My Log"], reviewed: true),
        c("control.ios.health.useEngine", "Use the faster engine", "Sets this playlist to the player engine that starts movies faster.", ["Settings", "Playback Health", "Use the faster engine"], reviewed: true),
        c("control.ios.icloud.erase", "Erase iCloud Data", "Removes what StreamSetu stored in your iCloud and turns sync off. Everything on this device stays.", ["Settings", "iCloud Sync", "Erase iCloud Data"], safety: .never, reviewed: true),
        c("control.ios.icloud.syncNow", "Sync Now", "Sends and fetches iCloud changes right away. It shows when iCloud Sync is on.", ["Settings", "iCloud Sync", "Sync Now"], reviewed: true),
        c("control.ios.lan.add", "Add a Device", "Pairs another device on this network. It shows when Sync on this network is on.", ["Settings", "Sync on this network", "Add a Device"], reviewed: true),
        c("control.ios.lan.syncNow", "Sync Now", "Syncs with paired devices on this network right away.", ["Settings", "Sync on this network", "Sync Now"], reviewed: true),
        c("control.ios.parental.lockFolder", "Lock a folder", "Switch on to hide that folder until the PIN is entered. The switches work once you have unlocked.", ["Settings", "Parental Controls", "Lock a folder"], safety: .never, reviewed: true),
        c("control.ios.parental.removePIN", "Remove PIN", "Removes the PIN after you enter it. Folder locks are kept, but nothing is hidden without a PIN.", ["Settings", "Parental Controls", "Remove PIN"], safety: .never, reviewed: true),
        c("control.ios.parental.savePIN", "Save PIN", "Stores a PIN of four to eight digits, entered twice.", ["Settings", "Parental Controls", "Save PIN"], safety: .never, reviewed: true),
        c("control.ios.parental.unlockConfirm", "Unlock", "Enter the PIN to show locked folders for a while. How long is set by Unlock lasts (15 minutes by default).", ["Settings", "Parental Controls", "Unlock"], safety: .never, reviewed: true),
        c("control.ios.storage.clearArtwork", "Clear Artwork Cache", "Deletes saved posters so they are fetched again.", ["Settings", "Storage and Maintenance", "Clear Artwork Cache"], reviewed: true),
        c("control.ios.storage.clearHistory", "Clear Watch History", "Removes what you watched and your resume points, after a confirmation. Favourites and collections stay.", ["Settings", "Storage and Maintenance", "Clear Watch History"], safety: .never, reviewed: true),
        c("control.ios.storage.clearTemp", "Clear Temporary Files", "Removes temporary files the app no longer needs.", ["Settings", "Storage and Maintenance", "Clear Temporary Files"], reviewed: true),
        c("control.ios.storage.integrity", "Check Database Integrity", "Checks the library database for damage.", ["Settings", "Storage and Maintenance", "Check Database Integrity"], reviewed: true),
        c("control.ios.storage.optimize", "Optimize Database", "Tidies the library database so it stays quick.", ["Settings", "Storage and Maintenance", "Optimize Database"], reviewed: true),
        c("control.ios.storage.rebuildSearch", "Rebuild Search Index", "Builds the search index again if results look wrong.", ["Settings", "Storage and Maintenance", "Rebuild Search Index"], reviewed: true),
        c("control.ios.storage.removeEverything", "Remove Everything", "Deletes all playlists and saved logins, the library, favourites, collections, history, search history, hidden items, renames, the artwork cache and the guide from this device.", ["Settings", "Storage and Maintenance", "Remove Everything"], safety: .never, reviewed: true),
        c("control.ios.storage.report", "Create Diagnostic Report", "Makes a text report of the app's state to share when asking for help. Passwords, tokens and stream addresses are removed.", ["Settings", "Storage and Maintenance", "Create Diagnostic Report"], reviewed: true),
    ]
}
