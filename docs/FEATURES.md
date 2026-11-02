[← Back to the README](../README.md)

# What each app does

A tick means the app has it today. A dash means it does not have it yet. The table was checked against the code of each app, and a feature I could not confirm for every app is left out rather than guessed. On the Android phone the TV Guide is a list of channels with what is on now and next, not the full grid.

| | Mac | iPhone | iPad | Android phone / tablet | Fire TV / Android TV |
|---|:-:|:-:|:-:|:-:|:-:|
| **Connections** | | | | | |
| Xtream Codes login | ✓ | ✓ | ✓ | ✓ | ✓ |
| M3U link | ✓ | ✓ | ✓ | ✓ | ✓ |
| M3U file from the device | ✓ | ✓ | ✓ | ✓ | ✓ |
| Stalker / Ministra portal | ✓ | – | – | ✓ | ✓ |
| Jellyfin, Emby, Plex | ✓ | ✓ | ✓ | ✓ | ✓ |
| HDHomeRun, TVHeadend, Enigma2 | ✓ | ✓ | ✓ | ✓ | ✓ |
| WebDAV server and local video files | ✓ | ✓ | ✓ | ✓ | ✓ |
| Custom User-Agent per connection | ✓ | ✓ | ✓ | ✓ | ✓ |
| Extra request headers per connection, and a proxy | ✓ | ✓ | ✓ | ✓ | ✓ |
| App DNS: encrypted DNS (Cloudflare, Google, Quad9, AdGuard, Control D or your own) for StreamSetu only, no VPN | ✓ (not yet for MPV) | ✓ | ✓ | ✓ | ✓ |
| **Watching** | | | | | |
| Live TV with groups and channel numbers | ✓ | ✓ | ✓ | ✓ | ✓ |
| TV Guide, XMLTV | ✓ | ✓ | ✓ | ✓ | ✓ |
| Catch-up for past programmes | ✓ | ✓ | ✓ | ✓ | ✓ |
| Radio mode | ✓ | ✓ | ✓ | ✓ | ✓ |
| Movies and series with resume and Up Next | ✓ | ✓ | ✓ | ✓ | ✓ |
| Multi-View, several channels at once | ✓ | ✓ | ✓ | ✓ | ✓ |
| Picture in Picture | ✓ | ✓ | ✓ | ✓ | – |
| AirPlay | ✓ | ✓ | ✓ | – | – |
| Chromecast | – | – | – | ✓ | – |
| Sound keeps playing in the background, with lock-screen controls and a mini player | – | ✓ | ✓ | ✓ | – |
| Sleep timer | ✓ | ✓ | ✓ | ✓ | ✓ |
| Skip intro | ✓ | ✓ | ✓ | ✓ | ✓ |
| Search the whole catalog from inside the player, with All, Movies, Series and Live TV | ✓ | ✓ | ✓ | ✓ | ✓ |
| Go to an exact time | ✓ | ✓ | ✓ | ✓ | ✓ |
| Remembered audio, subtitles, speed and timing for each title or channel | ✓ | ✓ | ✓ | ✓ | ✓ |
| Subtitles from OpenSubtitles, with your own free key | ✓ | ✓ | ✓ | ✓ | ✓ |
| Picture tuning, brightness, contrast, saturation, gamma | ✓ | ✓ | ✓ | ✓ with mpv | ✓ with mpv |
| Volume boost above 100% | ✓ | ✓ | ✓ | ✓ | ✓ |
| Subtitle size, colour, position and background in the player | ✓ | ✓ | ✓ | ✓ | ✓ |
| Choose the resolution of a stream that offers several | ✓ | ✓ | ✓ | ✓ | ✓ |
| Stats overlay with decoder, bitrate, buffer and dropped frames | ✓ | ✓ | ✓ | ✓ | ✓ |
| Sound keeps playing while you browse, with a small now-playing box | – | ✓ | ✓ | ✓ | ✓ |
| Subtitles from a file, and subtitle and sound timing | ✓ | ✓ | ✓ | ✓ timing with mpv | ✓ timing with mpv |
| Save a picture of the frame | ✓ | ✓ | ✓ | ✓ | ✓ |
| Programme reminders | ✓ | ✓ | ✓ | ✓ | ✓ |
| Swipe to change channel | – | ✓ | ✓ | – | – |
| Touch gestures in the player, double-tap skip, brightness, volume | – | ✓ | ✓ | ✓ | – |
| Player engines | AVPlayer + mpv | AVPlayer + mpv | AVPlayer + mpv | ExoPlayer + mpv | ExoPlayer + mpv |
| **Your library** | | | | | |
| Favorites, Watch Later, Recently Watched, Continue Watching | ✓ | ✓ | ✓ | ✓ | ✓ |
| Collections of your own | ✓ | ✓ | ✓ | ✓ | ✓ |
| Folders: reorder, hide, rename, PIN lock | ✓ | ✓ | ✓ | ✓ | ✓ |
| Search that works offline | ✓ | ✓ | ✓ | ✓ | ✓ |
| New-episode badge on series you watch | ✓ | ✓ | ✓ | ✓ | ✓ |
| Smart lists: Unwatched, Unwatched favorites, Added in 30 days | ✓ | ✓ | ✓ | – | – |
| Smart collections of your own: a saved rule (language, years, rating, added, unwatched, favourites, connection, words) | – | – | – | – | ✓ |
| Subtitle results ranked by how likely each is to match, each with the reason; automatic subtitles load only a confident match | – | – | – | ✓ | ✓ |
| Settings search, and an Essential or Advanced list of settings | – | – | – | – | ✓ |
| Projector mode: brighter pages, text and focus frame for projectors (video is not changed) | – | – | – | – | ✓ |
| Add-ons: extra connections described by a small file that can only reach the servers it names | – | – | – | – | ✓ |
| Playback capabilities: what the device reports about decoders, HDR and audio (read only) | – | – | – | – | ✓ |
| Search by actor or director, read from your playlists one movie at a time | ✓ | ✓ | ✓ | ✓ | ✓ |
| Queue: Play Next and Add to Queue | ✓ | ✓ | ✓ | ✓ | ✓ |
| Favorites in your own order | ✓ | ✓ | ✓ | ✓ | ✓ |
| Skip recap and Skip credits, as well as Skip intro | ✓ | ✓ | ✓ | ✓ | ✓ |
| For You row and a timeline of a film's whole franchise | ✓ | ✓ | ✓ | ✓ | ✓ |
| A different player engine for Live TV, movies, series and past programmes | ✓ | ✓ | ✓ | ✓ | ✓ |
| Quality and sound badges on movie and series pages (4K, HDR, Dolby Vision, Atmos, 5.1) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Subtitles fetched by themselves when a title has none in your language, with your OpenSubtitles account | ✓ | ✓ | ✓ | ✓ | ✓ |
| Green tick on watched titles and a bar on started ones | ✓ | ✓ | ✓ | ✓ | ✓ |
| Filter Movies and Series by language, quality, rating, decade and watch status, in the Sort menu on Mac, iPhone and iPad and in the Filter panel on TV (which also has a box to find a filter by name and can narrow by connection) | ✓ | ✓ | ✓ | – | ✓ |
| "In folder …" on a movie or series page, showing where it sits and opening that folder (useful after a search) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Play the best version of a film first (4K, then 1080p, never a cinema recording first), with the next best tried if one does not play | ✓ | ✓ | ✓ | ✓ | ✓ |
| Opening animation when the app starts (tap to skip; fades only with Reduce Motion) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Play a stream in another app (VLC, MX Player, IINA, Infuse and others) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Profiles: up to four people on one device, each with their own favourites, collections, history and resume points, a kids profile that keeps locked folders hidden, and PINs | ✓ | ✓ | ✓ | ✓ | ✓ |
| Tonight: what is on now and next on your favourite channels, what is set to record, and the next episode of your series | ✓ | ✓ | ✓ | ✓ | ✓ |
| Guide alerts: add a word (a sport, a team, a show) and get a reminder when a programme with it is coming up | ✓ | ✓ | ✓ | ✓ | ✓ |
| Subscription end dates for playlists that report them (Xtream), with a warning from a week before | ✓ | ✓ | ✓ | ✓ | ✓ |
| A live channel that stops working tries the same channel in your other playlists | ✓ | ✓ | ✓ | ✓ | ✓ |
| Podcasts: search, follow and play, with your place kept | ✓ | ✓ | ✓ | ✓ | ✓ |
| Watch Privately: play one title, series or channel without leaving history, resume points, statistics, lock-screen details or anything to sync | ✓ | ✓ | ✓ | ✓ | ✓ |
| Your week: time watched, the most watched title, new episodes and subscriptions ending, with an optional Sunday evening notification | ✓ | ✓ | ✓ | ✓ | ✓ |
| Your usual time: what you often put on around the same hour, one tap to play, with an optional reminder ten minutes before | ✓ | ✓ | ✓ | ✓ | ✓ |
| Privacy report: what is kept on the device and what can leave it, with each item's current state | ✓ | ✓ | ✓ | ✓ | ✓ |
| Viewing limits for a kids profile: minutes a day and night hours, with the profile's PIN adding time | ✓ | ✓ | ✓ | ✓ | ✓ |
| Start from the beginning: a live programme that began a while ago can be played from its start through catch-up | ✓ | ✓ | ✓ | ✓ | ✓ |
| Offline Home: with no connection, Home shows the downloads that still play | ✓ | ✓ | ✓ | ✓ | ✓ |
| Now playing on your other devices, with Play here, over Wi-Fi sync | ✓ | ✓ | ✓ | ✓ | ✓ |
| "More with" a person you keep watching, built on the device from the cast already read | ✓ | ✓ | ✓ | ✓ | ✓ |
| Multi-view warns before opening more streams than your provider allows | ✓ | ✓ | ✓ | ✓ | ✓ |
| Record a programme every week | ✓ app must be open | – | – | – | – |
| Search Movies and Series by actor or director, and by a sentence such as "telugu movies 2024 unwatched" (running time, as in "under 2 hours", on Mac, iPhone and iPad only; on Android and Fire TV it is in the main Search) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Home screen widget for Continue Watching, and a Live Activity for downloads | – | ✓ | ✓ widget | – | – |
| SharePlay: watch a film or a live channel together over FaceTime, started from the player or from a film's page | – | ✓ | ✓ | – | – |
| Match the TV's frame rate to the video (24, 25, 30, 50, 60 Hz) | – | – | – | – | ✓ |
| Downloads to watch without a connection, with a ring that fills and a percentage on the button and the poster | ✓ | ✓ | ✓ | ✓ | – |
| Record a live channel | ✓ | – | – | ✓ | ✓ |
| Schedule a recording from the TV Guide | ✓ app must be open | – | – | ✓ | ✓ |
| Downloads delete themselves after you watch them (off by default) | ✓ | ✓ | ✓ | ✓ | – |
| Share a channel, movie or series as a `streamsetu://` link | ✓ | ✓ | ✓ | ✓ | – |
| All playlists together, Apple / Combined libraries, Android | ✓ | ✓ | ✓ | ✓ | ✓ |
| Hide, rename and check channels, Channel Manager, health check | ✓ | ✓ | ✓ | ✓ | ✓ |
| Watch statistics | ✓ | ✓ | ✓ | ✓ | ✓ |
| Artwork and details from TMDB, your own API key | ✓ | ✓ | ✓ | ✓ | ✓ |
| Parental controls | ✓ | ✓ | ✓ | ✓ | ✓ |
| Themes and accent colours | ✓ | ✓ | ✓ | ✓ | ✓ |
| Screen reader labels | ✓ | ✓ | ✓ | ✓ phone | – |
| Hindi and Telugu, the main screens; some text is still English | ✓ | ✓ | ✓ | ✓ | ✓ |
| **More like this** | | | | | |
| Suggestions under a movie or series by franchise, director, genre, cast and story, each with its reason | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Assistant and your own services** | | | | | |
| Setu, an assistant in a chat bubble: finds something to watch, answers about your screen, settings and playback problems, and offers actions you tap to confirm (new: tried on the Mac first) | ✓ | ✓ | ✓ | – | – |
| Bring your own AI: Apple Intelligence, Gemini, OpenRouter, Claude, OpenAI, Groq, NVIDIA, Ollama Cloud, or Ollama on your network, with each one's price and free limit shown | ✓ | ✓ | ✓ | ✓ without Apple Intelligence | ✓ without Apple Intelligence |
| Ask AI from the search box when a request finds nothing | ✓ | ✓ | ✓ | ✓ | ✓ |
| Search box commands: go to a screen, play, resume, last channel, add or remove a favourite or Watch Later | ✓ | ✓ | ✓ | ✓ | ✓ |
| Sort and filter words in the search box ("top rated telugu movies", "newest series", "comedy not horror"), and moods ("date night", "something short") | ✓ | ✓ | ✓ | some words | some words |
| Trakt: tells Trakt what you watch and copies your watchlist into Watch Later, with your own Trakt app keys | ✓ | ✓ | ✓ | ✓ | ✓ |
| Debrid: play Real-Debrid, AllDebrid and Premiumize links with your own token (magnet links are not accepted on iPhone and iPad) | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Sync and updates** | | | | | |
| iCloud sync between your Apple devices | ✓ | ✓ | ✓ | – | – |
| Sync on this network (Wi-Fi, no account) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Backup and restore, and automatic weekly backups | ✓ | ✓ | ✓ | ✓ | ✓ |
| Refresh playlists when the app opens | ✓ | ✓ | ✓ | ✓ | ✓ |
| Refresh while the app is closed | – | ✓ iOS decides when | ✓ iOS decides when | ✓ | ✓ |
| Siri and Shortcuts | – use Open URL links | ✓ | ✓ | – | – |
| `streamsetu://` links: play a channel or movie, search, open a tab, pause, resume, sleep | ✓ | ✓ | ✓ | play and search | play and search |
| "Continue watching" row on the Android TV home screen | – | – | – | – | ✓ Android TV; not Fire TV |
| Updates itself | ✓ Sparkle | TestFlight | TestFlight | ✓ checks GitHub, asks before installing | ✓ checks GitHub, asks before installing |

Stalker portals are left out of the iPhone and iPad builds that go through TestFlight and the App Store, because Apple reviews a portal's set-top-box identity differently; the Mac and Android apps keep them. The iPad runs the iPhone app, laid out for the larger screen. On the Apple apps, Picture in Picture and AirPlay work for streams AVPlayer plays; a stream played by mpv does not support them. Android phones and tablets run the same app as the Fire TV, with a touch layout chosen automatically when the device is not a television.

## Sync on this network

Any of your devices on the same Wi-Fi can share **favourites, Watch Later, collections and resume points** directly, with no account and no server, between Mac, iPhone, iPad, Android phones and Fire TV. It is **off by default**: turn it on in Settings, under Sync on this network, then open **Add a device** on both devices and confirm that both show the same six digits. Everything is encrypted between the two devices, and an unpaired device is refused. The protocol is written down in `docs/WIFI-SYNC.md`.

## iCloud sync

On the Mac, iPhone and iPad, **iCloud sync** keeps your setup the same on every device signed in to the same Apple ID. It is **off by default**: you turn it on in Settings, under iCloud.

- It carries your playlists, favourites, collections, watch history and resume positions, folder organisation and settings.
- Your playlist logins can travel in iCloud Keychain, which Apple encrypts end to end. There is a separate switch for this, so you can leave logins off and type them on each device instead.
- The data is stored in your own private iCloud, not on our servers. We cannot see it.
- Settings shows the sync status, **Sync Now**, and **Erase iCloud Data** to remove what was stored.
- Android phones, Android tablets and the Fire TV have no iCloud, since it is an Apple service. They keep their data on the device, and can save and restore a backup.

## Each app in a few words

- **Mac**: the full app. A top bar for Home, Live TV, Movies, Series and TV Guide, a list of folders and shortcuts beside each, Cmd+K search, a Multi-View window, a Files screen for local videos and WebDAV servers, a Command Center for managing folders and channels, statistics, and automatic updates.
- **iPhone**: Home, Live TV, Movies, Series and More in a tab bar. A full player with Picture in Picture, AirPlay, swipe to change channel, catch-up, radio mode, sleep timer and a mini player. Multi-View, reminders for programmes, Siri and Shortcuts ("Play BBC One in StreamSetu"), backups, and iCloud sync.
- **iPad**: the iPhone app on a larger screen, with the same features.
- **Android phone and tablet**: the iPhone layout in a touch design. Poster and channel grids, sheets for menus, folder chips, a banner, Live TV channels that load as you scroll, and a player you tap, drag and swipe, with chips for picture, sound, subtitles and speed, which turns with the phone. Sound keeps playing when you leave the app, with controls on the lock screen and a mini player; it can also cast to a Chromecast.
- **Fire TV and Android TV**: made for the remote. A sidebar that opens with Back, folders beside the content, hold OK for a menu that slides in from the right edge over the page, a Live TV screen that plays the channel you pick in a preview beside the list, with what is on now and next taken from your downloaded guide or, when that has nothing, from the provider, folders with their own icons and long names that scroll, a faster TV Guide, Back from a live channel's fullscreen always returns to Live TV with that channel still playing, a player that opens and closes with no animation around the picture, a message that names the wait when a one-connection provider is closing the last stream, a player with one row of controls that each say what is playing (sound and subtitles, speed, picture size, player) and open their choices, with the question before leaving a movie drawn on the picture instead of in a pop-up, a one-line stream summary that shows for 5 seconds when playback starts, holding Left or Right to skip faster the longer it is held, a smoother player, a player with number keys for channels, and quiet interface sounds.
