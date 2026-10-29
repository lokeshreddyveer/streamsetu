# Privacy Policy

Last updated: {{UPDATED}}

StreamSetu is a player. It does not collect, sell or share your personal information, and the people who make it receive nothing from your use of it except a playback report when a stream fails, and only if you choose to share it: nothing is sent automatically unless you turn that on, and you can also send one by hand (described below). There are no analytics, no advertising identifiers, no automatic crash reporting and no account.

## What stays on your device

- The playlists and Xtream accounts you add, and the channels, movies, series and guide they contain.
- Your favourites, lists, watch history, resume positions and settings.
- Your playlist logins, kept in the system Keychain (or, on a Mac build without Keychain access, an encrypted file on your Mac).
- A short playback log: which server a stream came from (its name only), which player handled it, timings and errors. It never holds logins or full stream addresses and is trimmed automatically. It leaves your device when a stream fails for good (an automatic report, only if you said yes when the app first asked or turned it on in Settings → Send Feedback), when you press Send My Log Now, or when you send feedback with diagnostics. You can clear it in Send Feedback.
- Backups you create yourself. They are files you choose where to keep.

## Who your device talks to

StreamSetu connects only to the places below, and only for the reason given.

- **Your playlist provider.** To read your playlist, your guide and to play streams. What the provider sees (your address, what you watch) is governed by that provider. StreamSetu has no control over it.
- **StreamSetu's log service (off until you turn it on).** If you say yes when the app first asks, or turn it on in Settings, then when a stream fails for good the recent playback log is sent; it is also sent when you press Send My Log Now, even with the setting off. The playback log is sent to a server run by the developer, hosted by Supabase in London (United Kingdom). It contains which player was used, timings and error codes, your app version, system version and device model, and a random report number made on your device that groups one device's reports (it is not linked to any account). Server names in the log are replaced with server-1, server-2 and so on. It never contains your logins, passwords, playlist names, titles or stream addresses. It is used only to fix playback problems, is not shared with anyone else, and is deleted after 30 days. You can see exactly what would be sent, including the report number, under See exactly what is sent in Send Feedback. To have a report deleted sooner, email {{CONTACT_EMAIL}} with that number.
- **Apple iCloud (optional, off by default).** If you turn on iCloud sync, your library data and settings, and a record of when you watched what (the figures behind Statistics), are stored in your own private iCloud account, and logins can travel through iCloud Keychain. We cannot see them. You can turn sync off at any time and delete the data from Settings > Apple Account > iCloud.
- **The Movie Database (optional).** If you add your own TMDB key, StreamSetu sends a title and year to TMDB to fetch artwork, details and trailers.
- **OpenSubtitles (optional).** If you add your own OpenSubtitles key, account name and password and ask for subtitles in the player, StreamSetu sends the title, its year and a language code to opensubtitles.com to find subtitles, and your account name and password to sign in so a file can be downloaded. They are kept in the Keychain (on Android, in encrypted storage) and are sent nowhere else.
- **Trakt (optional).** If you connect your own Trakt app, StreamSetu sends when you start and stop watching a title (its name, year and how far you got) to trakt.tv, under your Trakt account, and reads your Trakt watchlist when you import it. Nothing is sent while you watch privately.
- **An online AI for the assistant (optional, off until you add a key).** If you add a key for Google Gemini, Groq, NVIDIA, OpenRouter, Anthropic Claude, OpenAI or Ollama Cloud and use the assistant, StreamSetu sends that provider your messages and the conversation so far. While "let the assistant see the screen" is on, it also sends the name of the screen you are on, the title you have open, your search text, what is playing (never while you watch privately) and a few library counts, and whatever the assistant asks to look up on your device (library titles, guide entries, playback figures). Apple Intelligence runs on the device and sends nothing; an Ollama address on your own network stays on it. What the provider does with it is governed by that provider.
- **Wikipedia.** When the assistant looks up a film, series or person, the topic is sent to Wikipedia.
- **Apple's iTunes catalogue.** When you open a movie or series page, the title and year may be sent to Apple's public iTunes Search service to find an official trailer clip.
- **YouTube.** If you tap Watch Trailer and the trailer is a YouTube video, the video is shown by YouTube's own player, which can set its own cookies and is covered by Google's privacy policy.
- **Apple.** The App Store, TestFlight and iCloud are Apple services under Apple's privacy policy.

- **A DNS provider, only if you turn on App DNS (Settings, Network).** It is off by default. When on, StreamSetu looks up the names of the servers it connects to through the DNS provider you pick (Cloudflare, Google, Quad9, AdGuard, Control D or one of your own), over an encrypted connection and inside StreamSetu only. That provider can see those host names, and may be able to tell which IPTV or CDN service you use from them. It does not receive your playlist passwords, stream addresses beyond the host name, or your viewing history.

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

Questions: {{CONTACT_EMAIL}}
