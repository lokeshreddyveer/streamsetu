import Foundation

/// Real summaries for the clusters of Music controls that carried only a one-line template: YouTube Music accounts, Listen Together, Devices, scrobbling, the lyrics toolbar, effects, and the player and queue.
/// Merged into `MusicRefinements.table`. Each text says what pressing the control does and where it is, from the control's own label and the page it sits on.
enum MusicControlRefinements {
    private static func t(_ name: String, _ summary: String, path: [String]? = nil, aliases: [String] = [], related: [String] = []) -> (String, AtlasRefinement) {
        ("control.music." + name, AtlasRefine.r(summary, path: path, aliases: aliases, related: related))
    }

    static let table: [String: AtlasRefinement] = Dictionary(uniqueKeysWithValues: accounts + rooms + devices + scrobbling + lyrics + effects + player)

    // MARK: YouTube Music accounts (sidebar, bottom)

    static let accounts: [(String, AtlasRefinement)] = [
        t("accountsSignInWithGoogle", "Opens a Google sign-in window for YouTube Music. Your session is kept in the Keychain and the account menu at the bottom of the sidebar then shows you as signed in.", aliases: ["sign in to youtube music"], related: ["recipe.music.signInYouTubeMusic"]),
        t("accountsSignInToYoutubeMusicWith", "The same sign-in as Sign in with Google, offered from the account menu: it opens Google's own sign-in window.", related: ["recipe.music.signInYouTubeMusic"]),
        t("accountsAddAccount", "Signs in a second Google account so you can switch between them from the account menu."),
        t("accountsAddAnotherGoogleAccount", "Opens the Google sign-in window again to add another account next to the one you already use."),
        t("accountsSwitchChannel", "Chooses which of your YouTube channels (brand accounts) Music uses for likes and history."),
        t("accountsSwitchYoutubeChannel", "Chooses which of your YouTube channels Music uses for likes and history."),
        t("accountsChooseAChannel", "Lists the YouTube channels on this Google account so you can pick one."),
        t("accountsSwitchTo", "Makes this account or channel the one Music uses."),
        t("accountsSwitch", "Switches to the account or channel you picked."),
        t("accountsCurrentChannel", "Shows the channel Music is using now."),
        t("accountsSignOut", "Signs this account out of YouTube Music on this Mac. Nothing is deleted on YouTube."),
        t("accountsSignOutOfYoutubeMusic", "Signs out of YouTube Music on this Mac and clears the saved session. Nothing is deleted on YouTube."),
        t("accountsRemoveAccount", "Takes this account off this Mac, with its saved session."),
        t("accountsRemove", "Removes the selected account from the account menu."),
        t("accountsCancelSignIn", "Stops the sign-in without changing anything."),
        t("accountsTrySigningInAgain", "Tries the Google sign-in again after it failed."),
        t("accountsTryLoadingTheChannelsAgain", "Loads the list of your YouTube channels again after it failed."),
        t("accountsCancel", "Closes this account dialog without changing anything."), t("accountsClose", "Closes this account dialog."), t("accountsOk", "Confirms and closes the account message."),
    ]

    // MARK: Listen Together

    static let rooms: [(String, AtlasRefinement)] = [
        t("listeningRoomStartARoomOnThisDevice", "Makes this Mac the host of a room. It shows a room code that friends on a reachable network enter to join, and you decide who is let in.", aliases: ["host a listening room", "start a party"], related: ["recipe.music.startListenTogether"]),
        t("listeningRoomShowANewRoomCode", "Replaces the room code with a new one, so people holding the old code can no longer join."),
        t("listeningRoomLetIn", "Accepts a person who asked to join your room."), t("listeningRoomRefuse", "Turns down a person who asked to join your room."),
        t("listeningRoomAddToTheQueue", "Accepts a guest's suggested song and adds it to the room's queue."), t("listeningRoomDoNotAdd", "Declines a guest's suggested song."),
        t("listeningRoomRemoveFromTheRoom", "Removes a guest from the room."),
        t("listeningRoomLookForRooms", "Searches your network for rooms you can join as a guest.", aliases: ["find a listening room"]), t("listeningRoomStopLooking", "Stops searching for rooms."),
        t("listeningRoomJoinTheRoomOn", "Joins the room found on the named device."), t("listeningRoomJoin", "Joins the room with the code you entered. While you are a guest playback controls follow the host.", related: ["shortcut.music.roomLock"]),
        t("listeningRoomLeaveTheRoom", "Leaves the room you joined and goes back to your own music."), t("listeningRoomEndRoom", "Ends the room you host and disconnects every guest."),
        t("listeningRoomCopyCode", "Copies the room code so you can send it."), t("listeningRoomShareInvite", "Shares an invite to the room with the share sheet."), t("listeningRoomCopyInvite", "Copies an invite to the room to the clipboard."),
        t("listeningRoomSuggestASongToTheHost", "A guest's way to suggest a song; the host chooses whether to add it to the queue."),
    ]

    // MARK: Devices

    static let devices: [(String, AtlasRefinement)] = [
        t("devicesAllowOtherDevicesToControlThis", "The switch that lets your other devices on the same Wi-Fi pair with this Mac and control its playback. It is off until you turn it on.", aliases: ["allow remote control"], related: ["recipe.music.pairDevice"]),
        t("devicesShowAPairingCodeForAnother", "Shows the code another device enters to pair with this Mac. Too many wrong codes lock pairing for a while.", related: ["diag.music.pairingLocked"]),
        t("devicesLookForMyDevices", "Searches your Wi-Fi for your other devices that allow control.", related: ["diag.music.devicesNotFound"]), t("devicesStopLooking", "Stops searching for devices."),
        t("devicesPairWith", "Starts pairing with the device you picked; you then enter the code it shows."), t("devicesPair", "Pairs with the code you entered."), t("devicesConnectTo", "Connects to an already paired device so you can control it."),
        t("devicesDisconnect", "Stops controlling the connected device."), t("devicesSendThisDeviceSQueueTo", "Sends what is queued on this Mac to the device you control, so it plays there."),
        t("devicesCopyCode", "Copies the pairing code."), t("devicesTryAgain", "Tries the search or the connection again."), t("devicesRemove", "Removes a paired device, so it can no longer control this Mac."),
        t("devicesCancel", "Closes the pairing step without pairing."),
    ]

    // MARK: Scrobbling

    static let scrobbling: [(String, AtlasRefinement)] = [
        t("settingsScrobblingConnectLastFm", "Signs in to Last.fm so Music can send what you play. Scrobbling stays off until a service is connected.", aliases: ["connect lastfm"], related: ["recipe.music.connectLastFm"]),
        t("settingsScrobblingDisconnectLastFm", "Signs out of Last.fm; Music stops sending plays to it."), t("settingsScrobblingCancelLastFmSignIn", "Stops the Last.fm sign-in that is waiting."),
        t("settingsScrobblingConnectListenbrainz", "Connects ListenBrainz with your user token so plays are sent there.", related: ["recipe.music.connectLastFm"]), t("settingsScrobblingDisconnectListenbrainz", "Disconnects ListenBrainz; plays are no longer sent to it."),
        t("settingsScrobblingOpenListenbrainzSettings", "Opens the ListenBrainz website's settings page, where your token is."), t("settingsScrobblingVerifyYourMetabrainzEmail", "Opens MetaBrainz to verify your email, which ListenBrainz needs before it accepts plays."),
        t("settingsScrobblingOpenProfile", "Opens your profile on the connected service in the browser."),
        t("settingsScrobblingAddACleanupRule", "Adds a rule that tidies titles or artists before they are scrobbled, for example removing a remaster tag."), t("settingsScrobblingEmptyRule", "A cleanup rule with nothing in it yet; fill in the field and what to do with it."),
        t("settingsScrobblingField", "Which part of the play the cleanup rule looks at: the title, artist or album."), t("settingsScrobblingOn", "Switches this cleanup rule on or off."),
        t("settingsScrobblingEditWhatThisTrackScrobblesAs", "Changes the title, artist or album that is sent for this one track, without changing the song itself."), t("settingsScrobblingRemoveEdit", "Removes a saved edit so the track is sent as it is."),
        t("settingsScrobblingRemoveTheEditForThisTrack", "Removes the edit for this track so it is scrobbled with its own details."), t("settingsScrobblingSave", "Saves the edit or rule."), t("settingsScrobblingCancel", "Closes the editor without saving."),
    ]

    // MARK: Lyrics toolbar and sharing

    static let lyrics: [(String, AtlasRefinement)] = [
        t("lyricsSmallerLyricsText", "Makes the lyrics text smaller.", aliases: ["lyrics font smaller"]), t("lyricsLargerLyricsText", "Makes the lyrics text larger.", aliases: ["lyrics font bigger"]),
        t("lyricsShowLyricsEarlier", "Nudges this song's lyrics earlier when they come too late. Each press moves them one small step; Reset the lyrics offset undoes it.", related: ["setting.music.lyricsOffset"]),
        t("lyricsShowLyricsLater", "Nudges this song's lyrics later when they come too early.", related: ["setting.music.lyricsOffset"]), t("lyricsResetTheLyricsOffset", "Puts this song's lyrics timing back to normal."),
        t("lyricsTranslateTheLyricsOnThisDevice", "Translates the lyrics on this Mac and shows the translation under each line. The language is set in Settings, Lyrics.", related: ["setting.music.translateLyricsInto"]),
        t("lyricsJumpToCurrentLine", "Scrolls the lyrics back to the line being sung after you scrolled away."), t("lyricsBackToThisSong", "Returns to the lyrics of the song that is playing."),
        t("lyricsGoodLyrics", "Tells the community lyrics service these lyrics are right."), t("lyricsBadLyrics", "Tells the community lyrics service these lyrics are wrong, and lets you say why."),
        t("lyricsReportAProblemWithTheseLyrics", "Reports a problem with these lyrics; you choose a reason."), t("lyricsReason", "Choose the reason for the report."), t("lyricsSent", "Your report was sent."),
        t("lyricsSearchSourcesWithTheseWords", "Searches the lyrics sources again using words you type, for a song that was not found by its title."), t("lyricsAutomaticFirstMatchInYourOrder", "Lets Music use the first source in your order that has lyrics.", related: ["setting.music.lyricsSources"]),
        t("lyricsPickLinesToShare", "Starts picking lines of the lyrics to share as a card.", aliases: ["share lyrics"]), t("lyricsSharePickedLines", "Shares the lines you picked as a card."), t("lyricsCancelPickingLines", "Stops picking lines without sharing."),
        t("lyricsCopyTheLyricsAsText", "Copies the lyrics as plain text."), t("lyricsUseTheStoryLayout", "Makes the shared card tall, in a story layout."), t("lyricsShowTheAppNameOnThe", "Shows the app's name on the shared card."),
        t("lyricsDone", "Closes the sharing sheet."), t("lyricsVia", "Names the source the lyrics came from."),
    ]

    // MARK: Effects

    static let effects: [(String, AtlasRefinement)] = [
        t("effectsTempoPitchAndReverb", "Opens tempo, pitch and reverb for the playing song, with presets, and a page for the Equalizer.", related: ["control.music.effectsPopover"]),
        t("effectsResetTempo", "Puts the tempo back to the song's own speed."), t("effectsResetPitch", "Puts the pitch back to the song's own."), t("effectsReverb", "How much reverb is added to the sound."),
        t("effectsResetAllEffects", "Puts tempo, pitch and reverb back to normal in one press."), t("effectsSaveTheCurrentSoundAsA", "Saves the current tempo, pitch and reverb as a preset you can pick again."), t("effectsSavePreset", "Saves the preset under the name you typed."),
        t("effectsPreset", "Picks a saved or built-in preset."), t("effectsDeletePreset", "Deletes a preset you saved."), t("effectsEqualizer", "Opens the equalizer: seven bands, a bass and treble pad, presets and stereo widening.", related: ["setting.music.equalizer"]),
        t("effectsDone", "Closes the effects."), t("effectsCancel", "Closes without saving."),
    ]

    // MARK: Player and queue

    static let player: [(String, AtlasRefinement)] = [
        t("playerAndQueuePrevious", "Goes to the previous song. Command D does the same.", related: ["shortcut.music.nextPrev"]), t("playerAndQueueNext", "Skips to the next song. Command Right Arrow does the same.", related: ["shortcut.music.nextPrev"]),
        t("playerAndQueuePlay", "Starts this song or resumes playback."), t("playerAndQueueRemoveFromQueue", "Takes this song out of the queue. Command Z in the queue brings it back.", related: ["control.music.queueUndo"]),
        t("playerAndQueueOpenNowPlaying", "Opens the Now Playing view for the song that is playing."), t("playerAndQueueOpenFullWindowNowPlaying", "Opens the full-window Now Playing view.", related: ["screen.music.player"]),
        t("playerAndQueueOpenFullWindow", "More player actions, Open Full Window: opens the full-window Now Playing view.", related: ["screen.music.player"]),
        t("playerAndQueueGoToArtist", "Opens the page of the playing song's artist."), t("playerAndQueueGoToAlbum", "Opens the page of the playing song's album."),
        t("playerAndQueueRetryPlayingThisTrack", "Tries to start the song again after it failed to play.", related: ["diag.music.songWontPlay"]), t("playerAndQueueChooseAnotherAudioSource", "Opens a list of other copies of this song so you can play a different one.", related: ["diag.music.songWontPlay"]),
        t("playerAndQueueComments", "Opens the comments for the playing song."), t("playerAndQueueSleepTimer", "The sleep timer menu: 15, 30, 45, 60 or 90 minutes, or End of this track.", related: ["control.music.sleepTimerMusic"]),
        t("playerAndQueueCancelSleepTimer", "Cancels the running music sleep timer.", related: ["control.music.sleepTimerMusic"]), t("playerAndQueueMorePlayerActions", "The three dots in the player bar, with the actions that no longer fit.", related: ["control.music.playerBarMore"]),
        t("playerAndQueueUseFullPlayerBar", "Switches the floating compact player to the full-width strip.", related: ["control.music.playerBarPill"]), t("playerAndQueueEditLyrics", "Opens the lyrics editor for the playing song, to add or time its lyrics."),
        t("playerAndQueueAutoplay", "Turns Autoplay on or off: keep similar music coming when the queue runs low.", related: ["setting.music.autoplay"]), t("autoplayMenuToggle", "Autoplay switch inside the shuffle menu.", related: ["setting.music.autoplay"]),
        t("shuffleMode", "Chooses the shuffle style used when Shuffle is on.", related: ["setting.music.shuffleWholeQueue"]), t("shuffleReshuffle", "Shuffles the queue again into a new order."), t("shuffleQueueMenu", "The shuffle options of the queue: style, reshuffle and autoplay."),
        t("queueKeepAuto", "Keeps an autoplay song in the queue so it stays after the autoplay list changes."), t("playerBarAudioQuality", "Shows the codec, bitrate and sample rate of the stream that is playing.", related: ["control.music.audioQualityChip"]),
        t("playerBarOutput", "Where Music plays on this Mac: the output device menu.", related: ["setting.music.outputDevice"]), t("playerBarOutputDevice", "Choose the speakers or headphones Music plays through.", related: ["setting.music.outputDevice"]),
        t("playerBarVolumeStep", "Volume up or down in steps; the mouse wheel over the volume button and the arrow keys do the same.", related: ["shortcut.music.volumeKeys"]),
    ]
}
