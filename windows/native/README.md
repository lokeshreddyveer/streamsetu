# StreamSetu for Windows

A native Windows app: WinUI 3 screens and the libmpv player, the same engine as the Mac app. Your playlists and servers, one library, no account.

## Get it

Download `StreamSetu-Windows-0.1.0.zip` from the [Releases](../../../releases) page, unzip it anywhere and run `StreamSetu.exe`. Windows 10 (version 1809) or later, 64-bit. On the first start it opens **Connections**: pick the type, fill it in, press **Test**, then **Save**.

## What is in it

**Connections:** Xtream Codes, M3U link, M3U file, Stalker / Ministra portal, HDHomeRun, TVHeadend, Enigma2, Jellyfin, Emby, Plex, WebDAV, and a folder of video files. Passwords, keys and tokens are kept in Windows Credential Manager. The Test button shows what was found, and an Xtream subscription warns from a week before it ends.

**Watching:** Live TV, Movies and Series (the next unwatched episode is chosen for you), search, TV Guide (XMLTV) with what is on now and next on every channel, Tonight for your favorite channels, Alerts for words you ask about, and catch-up for past programmes on Xtream. Favorites, Continue Watching, Unwatched, New (added in the last 30 days), your own collections, a play queue (Play next, Add to queue), channel logos and posters, a green tick on watched titles, and filters (language, quality, rating, decade, watch status) with sorting.

**Player:** play and pause, seek, go to an exact time, volume to 150%, speed, audio and subtitle tracks, subtitles from a file or from OpenSubtitles (ranked, each with the reason; automatic loading takes only a confident match), subtitle size, colour, background and timing, audio timing, picture settings (brightness, contrast, saturation, gamma), a stats overlay, screenshots, a sleep timer, Skip intro, recap and credits, a mini player that stays above other windows, full screen, and Multi-View with up to four channels at once. A live channel that stops working tries the same channel in your other connections.

**Recording and reminders:** record a programme from the TV Guide (a minute early and two late, saved to Videos\StreamSetu), and Remind me with a Windows notification before it starts. A Recordings screen lists them. StreamSetu has to be open at the time.

**People:** up to four profiles, each with their own favorites, history, collections and folders. A profile can have a PIN; a Kids profile cannot open Settings or Connections and never sees locked folders. Folders can be hidden, renamed, reordered and locked with a PIN.

**Sync on this network:** favorites, resume points and collections stay in step with your Mac, iPhone, iPad and Android devices over Wi-Fi, with no server and no account. A new device is paired once by comparing six digits.

**Settings:** encrypted DNS for StreamSetu's own lookups (Cloudflare, Google, Quad9 or your own server), your OpenSubtitles account, guide addresses, alert words, sync, update checks, and backup and restore.

**Updates:** Settings checks the Releases page. A download is checked against its published SHA-256 before it is kept.

## Privacy and safety

- Everything the app downloads (playlists, provider answers, pictures, subtitles, updates) goes through one downloader: web addresses only, never this computer or your local network unless the host is in a saved connection, no passwords inside addresses, redirects checked at every step, and size limits.
- Playing a new channel while an older one is still loading cannot be overtaken by the older one.
- A data file that cannot be read is set aside, never overwritten. A backup file is checked entry by entry before anything is replaced, and the replaced data is kept.
- PINs are stored only as salted hashes. Five wrong tries lock a profile for a minute.

## Build it yourself

Install the .NET 10 SDK and Visual Studio 2022 or later with the **.NET desktop development** workload. In PowerShell, in this folder:

```powershell
powershell -ExecutionPolicy Bypass -File Scripts\fetch-libmpv.ps1     # once: downloads the player engine
powershell -ExecutionPolicy Bypass -File Scripts\build.ps1            # builds dist\x64\StreamSetu.exe
powershell -ExecutionPolicy Bypass -File Scripts\package.ps1          # builds the installer (needs Inno Setup 6)
```

For Windows on ARM add `-Arch aarch64` to the first and `-Arch arm64` to the others.

## Licence note

The zip includes `libmpv-2.dll`, a build of [mpv](https://mpv.io) (GPL-2.0-or-later; source at https://github.com/mpv-player/mpv).
