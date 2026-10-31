[← Back to the README](../README.md)

# Fire TV and Android in detail

## Connect your own sources

- **Xtream Codes**: server, user name and password.
- **M3U playlists**: a web link, or a file from the device or a USB drive.
- **Stalker / Ministra portals**: portal address and the MAC address of the box it should act as. Live TV only for now.
- **Jellyfin and Emby** (movies and series; server, user name and password) and **Plex** (movies and shows; server and access token). The password is kept in the system's secure storage; the sign-in token is renewed by itself.
- **HDHomeRun tuners**, **TVHeadend** servers and **Enigma2 receivers** on your own network (live channels; the guide comes from TVHeadend's own XMLTV).
- **WebDAV shares** (a NAS or cloud drive) and **a folder of videos on the phone**: video files appear as movies, by folder.
- **Extra request headers** per connection (one per line, written as `Name: value || Name: value` in the form), and an app-wide **HTTP or SOCKS proxy** that never touches addresses on your own network.
- A **custom User-Agent** per connection, for providers that insist on a particular player.
- **Combined libraries**: several connections shown as one library, without copying anything. A title that exists in two connections is one title to you; you choose which connection plays it.
- **Test before you save**: a connection is tried once, by hand, with no automatic retries. A login that works but returns nothing is rejected, and an unfinished setup is kept as a draft you can come back to.
- **Phone setup** (Fire TV): scan a QR code, type the connection on your phone, approve it on the TV. The link works for five minutes, on your home network only.

## Watch

- **Sound in the background** (phones): when you leave the app, what is playing carries on as sound, with controls on the lock screen and in the notification shade. Back from a radio station keeps it playing under a mini player; the down arrow in the player does the same for anything.
- **Multi-View**: up to four live channels on one screen, sound from one. A provider that allows one connection plays only one of them, and the screen says so.
- **Skip intro**: a button in the first minutes of an episode. The first time you jump forward early in a series it learns where that series' opening ends.
- **Sleep timer**, **subtitles from a file**, **subtitle and sound timing** (mpv), and **a picture of the frame** saved to Pictures/StreamSetu.
- **Programme reminders** from the TV Guide: a notification a minute before it starts, which opens the channel.
- **Live TV** with channel groups, channel numbers, a three-column browser (folders, channels, live picture), fullscreen, last-channel recall, and typing a channel number.
- **TV Guide** from XMLTV: a timeline grid, programme details, a "now" line, and matching by the provider's guide id or by channel name when ids are missing. A time shift for providers whose guide runs early or late.
- **Catch-up** for channels where the provider offers an archive.
- **Movies and series** with fullscreen detail pages, story and cast from the provider, seasons and episodes, resume, "Start over", "Up next", and a "Continue Forward" or "Catch Up" choice when you skipped an episode. Autoplay never runs across a missing episode.
- **Radio**: stations marked `radio="true"` (or in a Radio category) play with an audio-only screen.
- **Resume anywhere**: progress is saved only after a picture has really played, and a failed seek can never overwrite your earlier position.

## Find things fast

- **Folders** are the provider's own categories. You can search them, favorite, pin, reorder (up, down, first, last), hide, lock behind a PIN, give them a display name, and reset any of it. Nothing you do changes the provider's playlist; it is all stored on your device.
- **Collections** of your own, and a shortcut row for Favorites, Watch Later, Recently Watched and Continue Watching.
- **Channel Manager** (Settings): hide channels, rename them, tie one to another guide channel, and check which channels answer (a channel that does not answer in time is never counted as dead). Your changes survive a refresh of the playlist.
- **Statistics**: how long you watched, by day and hour, and your most watched channels, movies and series. It stays on the device and can be cleared.
- **Artwork from TMDB**: with your own free API key, pictures and descriptions your provider left out are filled in.
- **Themes and accent colours**, and **Hindi and Telugu** for the main screens (Settings, Appearance, Language). Text that has no translation yet stays in English; titles and descriptions always come from your provider.
- **Search** runs on a local text index, so it works offline. It reads queries the way you mean them ("hindi movies 2024" is Hindi titles from 2024), fixes a misspelt word from the words in your own library when nothing matches and says what it searched for, and groups results as Live TV, Movies, Series, Episodes, TV Guide programmes, Folders and Collections. It keeps recent searches for each screen. The iPhone, iPad, Mac, Android phone and Fire TV apps all search this way.
- **Sorting** only offers orders the catalog can truly support (recently added, A–Z, release year, rating, recently watched, new episodes first…), remembered per section and per folder.

## Playback you can trust

- **Two engines**: Media3 ExoPlayer for HLS, MP4, DASH and MPEG-TS, and mpv for MKV, AVI and unusual formats. Automatic chooses per stream; if a format fails it tries the other engine once. Switching engine retries the *same* stream; a different provider stream is only ever your choice.
- **Recovery**: a stream stuck loading is treated as failed; failures are sorted into network, login, copy-protection, decoder and format problems, and only the relevant action is offered.
- **One-connection providers** are respected: a new stream waits for the old one to close.
- **Separate buffering** for Live TV and for movies, with per-connection overrides.
- **Stream details** on screen: engine, resolution, codecs, buffer, dropped frames.

## Built for the remote

- Everything works with a Fire TV remote: arrows, OK, **hold OK for a menu**, Back, and digits.
- Back always goes one step up: close a menu → leave a page → folders → sidebar → Home → library chooser.
- Smooth, restrained motion with one shared set of timings; reduced-motion is respected.
- Optional soft **interface sounds**, off until you turn them on in Settings. Five sets of original tones (Signature, Wood, Crystal, Soft, Arcade) plus Minimal; they never touch the TV's volume.

## Assistant, Trakt and debrid

- **Setu** (Mac, iPhone and iPad) is a chat opened from a round button at the bottom right. It answers from your own library and from the app's own numbers, and everything it suggests is a button you tap. A tick appears only when the action worked; when it did not, it says why. It is switched off in a kids profile. On iPhone and iPad it is new and has not yet been tried on a device.
- **Your own AI.** You choose the service and add your own key. The key is kept in the system's secure storage and sent only to that service. Only the words you type are sent, plus, if you leave the eye button on, the name of the screen, what is playing and a few library counts. Playlist addresses, logins and tokens are never sent.
- **Trakt and debrid** use your own accounts and keys, and do nothing until you sign in.
- The AI answers from what the model knows. It has no live web search.

## Privacy and safety

- The Android apps can check GitHub for a newer release (Settings, About, Updates). It is on by default, runs once a day, and only when nothing is playing. Only the public release list is requested, and nothing about you is sent. A downloaded file is used only if its checksum matches the release notes and it is signed with the same key as the installed app, and the system installer always asks you to confirm. You can turn the check off.
- No account, no advertising, no analytics, no crash reporting sent anywhere. The only exceptions are services you set up yourself: your AI, Trakt, a debrid service, TMDB and OpenSubtitles, each with your own key and each told only what it needs.
- Logins live in the system's secure storage (Android Keystore, Apple Keychain) and are never shown, logged or exported.
- Diagnostic reports and backups remove addresses, user names, passwords and tokens.
- Folder locks are a real PIN lock: the PIN is stored only as a salted hash, and locked titles are also left out of search and banners.
- Backups hold favorites, folder arrangements, progress and settings, never logins or playlist links.
