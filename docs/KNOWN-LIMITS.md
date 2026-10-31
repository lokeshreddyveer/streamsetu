[← Back to the README](../README.md)

# Known limits

Only what changes what you can do. Everything else StreamSetu does is in [FEATURES.md](FEATURES.md).

## Features that are not on every app

- **Stalker portals** give live TV only (no movies, series or guide), and are left out of the iPhone and iPad App Store build.
- **Recording** a live channel is on the Mac, Android phone and Fire TV, not on iPhone and iPad. **Downloads** are not on Fire TV.
- **The Setu assistant** is on the Mac, iPhone and iPad. Android and Fire TV have commands and an Ask AI row in search, not the chat yet.
- **Problem reports** are sent only by the Mac app (off until you turn them on). The iPhone and iPad App Store build sends none.
- **Audio and subtitle delay** need the mpv player. **Frame-rate matching** is on Fire TV and Android TV only, and only on TVs that can switch their refresh rate.
- **Chromecast** fetches the stream itself, so only plain web streams (HLS, MP4) cast well, and a connection that needs special headers cannot be cast.
- **Catch-up** needs a provider that offers an archive; some providers use their own time zone for it (there is a setting).
- **Hindi and Telugu** cover the main screens and common words; long Settings explanations are still English, and the wording has not had a native-speaker review.
- **Trakt and debrid** have been tested against recorded replies, not with real accounts.

## Fire TV and Android TV

- On a **Fire TV Stick 4K** (1.7 GB of memory) lists can drop frames when you scroll fast, and a 4K film that only mpv can play can stutter (measured: about 14 frames a second dropped on one 4K HEVC film). Both are being worked on.
- A big folder loads 600 titles first and the next 600 as you scroll, so a library of tens of thousands is all reachable. Turning on a Filter loads the whole folder at once.
