[← Back to the README](../README.md)

# Known limits

- On the Fire TV, a big folder loads 600 titles at first and the next 600 as you scroll near the end, so a library of tens of thousands is all reachable. The header shows both numbers (for example "600 of 2,958 series"). Turning on a Filter loads the whole folder at once.
- Stalker portals: live TV only; no movies, series or guide from a portal yet.
- A Chromecast fetches the stream itself, so only plain web streams (HLS, MP4) cast well, and a connection that needs special headers cannot be cast.
- The "Continue watching" row on the home screen works on Android TV and Google TV, not on a Fire TV, which has its own home screen.
- Hindi and Telugu cover the main screens and the most common words; long explanations in Settings are still English. The wording was written without a native-speaker review, so corrections are welcome.
- On the Mac, real Siri phrases need an app built with Xcode (App Intents); the Mac build is not, so Shortcuts reaches it through "Open URL" with `streamsetu://` links.
- Audio delay and subtitle delay need the mpv player. Matching the TV's frame rate is on Fire TV and Android TV only, and only on TVs that can switch their refresh rate.
- Stalker portals are not offered in the iPhone and iPad builds distributed through TestFlight and the App Store.
- Recording a live channel is on the Mac, Android phone and Fire TV, not on iPhone and iPad. Downloads are not on Fire TV.
- Catch-up needs a provider that offers an archive, and some providers read the start time in their own time zone (there is a setting for it).
- Setu is on the Mac, iPhone and iPad. Android and Fire TV have commands and an Ask AI row in the search box, but not the chat, the instant name answers or the problem diagnosis yet.
- Apple Intelligence's on-device model is weak at who was in which film; for actors, use another model or add a TMDB key.
- Trakt and debrid have been tested against recorded replies, not with real accounts.
- Mac copies older than 2.3.1 cannot update themselves (the old update feed was removed when everything moved into this repository). Download 2.3.1 once from the Releases page; it updates itself from then on.
