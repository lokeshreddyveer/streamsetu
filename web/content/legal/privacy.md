# Privacy Policy

Last updated: 12 October 2026

StreamSetu is a player. It does not collect, sell or share your personal information, and the people who make it receive nothing from your use of it except an automatic playback report when a stream fails, which you can switch off (described below). There are no analytics, no advertising identifiers, no automatic crash reporting and no account.

## What stays on your device

- The playlists and Xtream accounts you add, and the channels, movies, series and guide they contain.
- Your favourites, lists, watch history, resume positions and settings.
- Your playlist logins, kept in the system Keychain (or, on a Mac build without Keychain access, an encrypted file on your Mac).
- A short playback log: which server a stream came from (its name only), which player handled it, timings and errors. It never holds logins or full stream addresses and is trimmed automatically. It leaves your device when a stream fails for good (an automatic report, on by default; the first launch tells you, and you can turn it off in Settings → Send Feedback), when you press Send My Log Now, or when you send feedback with diagnostics. You can clear it in Send Feedback.
- Backups you create yourself. They are files you choose where to keep.

## Who your device talks to

StreamSetu connects only to the places below, and only for the reason given.

- **Your playlist provider.** To read your playlist, your guide and to play streams. What the provider sees (your address, what you watch) is governed by that provider. StreamSetu has no control over it.
- **StreamSetu's log service (on by default, and you can turn it off).** When a stream fails for good, or when you press Send My Log Now, the recent playback log is sent to a server run by the developer, hosted by Supabase in London (United Kingdom). It contains which player was used, timings and error codes, your app version, system version and device model, and a random report number made on your device that groups one device's reports (it is not linked to any account). Server names in the log are replaced with server-1, server-2 and so on. It never contains your logins, passwords, playlist names, titles or stream addresses. It is used only to fix playback problems, is not shared with anyone else, and is deleted after 30 days. You can see exactly what would be sent, including the report number, under See exactly what is sent in Send Feedback. To have a report deleted sooner, email contact@lokeshreddy.dev with that number.
- **Apple iCloud (optional, off by default).** If you turn on iCloud sync, your library data and settings are stored in your own private iCloud account, and logins can travel through iCloud Keychain. We cannot see them. You can turn sync off at any time and delete the data from Settings > Apple Account > iCloud.
- **The Movie Database (optional).** If you add your own TMDB key, StreamSetu sends a title and year to TMDB to fetch artwork, details and trailers.
- **OpenSubtitles (optional).** If you add your own OpenSubtitles key, account name and password and ask for subtitles in the player, StreamSetu sends the title, its year and a language code to opensubtitles.com to find subtitles, and your account name and password to sign in so a file can be downloaded. They are kept in the Keychain (on Android, in encrypted storage) and are sent nowhere else.
- **Apple's iTunes catalogue.** When you open a movie or series page, the title and year may be sent to Apple's public iTunes Search service to find an official trailer clip.
- **YouTube.** If you tap Watch Trailer and the trailer is a YouTube video, the video is shown by YouTube's own player, which can set its own cookies and is covered by Google's privacy policy.
- **Apple.** The App Store, TestFlight and iCloud are Apple services under Apple's privacy policy.

## Security

Credentials are stored in the Keychain (on Android, in encrypted storage). An access token for a media server is sent only to that server, and is removed from a request if a redirect sends it to another one. The phone-assisted setup on a TV sends what you type over your home network without encryption, so use it on your own Wi-Fi only. Connections use TLS with certificate validation, and sensitive addresses and tokens are removed from logs. The optional App Lock uses Face ID, Touch ID or your device passcode.

## Your choices

- Turn Share playback logs automatically off at any time in Settings → Send Feedback.
- Remove a playlist, and its logins and data are removed from the device.
- Delete the app and its data is removed from the device.
- Turn off iCloud sync and delete the iCloud data from your Apple Account settings.

## Children

StreamSetu is a general-purpose player and contains no content of its own. Parental controls let you hide folders behind a PIN.

## Changes

If this policy changes, the new version appears in the app and on the website with a new date.

## Contact

Questions: contact@lokeshreddy.dev
