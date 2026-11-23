[← Back to the README](../README.md)

# Known limits

Only what changes what you can do. Everything else StreamSetu does is in [FEATURES.md](FEATURES.md).

## Features that are not on every app

- **Stalker portals** give live TV only (no movies, series or guide), and are left out of the iPhone and iPad App Store build.
- **Recording** a live channel is on the Mac, Android phone and Fire TV, not on iPhone and iPad. **Downloads** are not on Fire TV.
- **The Setu assistant** (the chat bubble) is on the Mac, iPhone and iPad (a sparkles button at the bottom right; hidden in kids mode). Android and Fire TV have commands and an Ask AI row in search, not the chat yet.
- **Setu on iPhone and iPad** was looked at on the iOS 27 simulators only (button above the tab bar, sheet, keyboard, largest text size, Show me pointing at a real control, VoiceOver labels), not yet on a physical iPhone or iPad. Not yet seen running: kids mode hiding the button (covered by a unit rule only), Reduce Motion in Show me, and a real VoiceOver session.
- **Setu in Spotlight and Siri**: on iPhone and iPad, Spotlight finds StreamSetu's screens and settings (not locks, kids or hidden-folder settings, and nothing while a kids profile is in use), and "Ask StreamSetu" in Siri or Shortcuts answers a question on the device. Siri needs a spoken or typed question each time; it cannot take the question inside the phrase. On the Mac, Spotlight finds the same screens and settings, but there are no Shortcuts or Siri actions: the downloaded Mac app is not built by Xcode, which is what normally produces the App Intents list (the tool can be run by hand on the build, but nothing proves macOS then registers actions for a notarised download, so it is not shipped).
- **Problem reports** are sent only by the Mac app (off until you turn them on). The iPhone and iPad App Store build sends none.
- **Audio and subtitle delay** need the mpv player. **Frame-rate matching** is on Fire TV and Android TV only, and only on TVs that can switch their refresh rate.
- **Chromecast** fetches the stream itself, so only plain web streams (HLS, MP4) cast well, and a connection that needs special headers cannot be cast.
- **Catch-up** needs a provider that offers an archive; some providers use their own time zone for it (there is a setting).
- **Hindi and Telugu** cover the main screens and common words; long Settings explanations are still English, and the wording has not had a native-speaker review.
- **Cast, weekly trending and the details service artwork** use the details service, with the built-in key or your own free key; with artwork matching and trending switched off, the cast row shows names only and Top This Week uses what is watched on your own device.
- **Windows** is a zip and is not signed, so SmartScreen may warn the first time. It tells you when a new zip is available and offers a checked download, but does not install it. The Setu chat is not there.
- **The watch-history service and linked-account** have been tested against recorded replies, not with real accounts.

## Fire TV and Android TV

- On a **Fire TV Stick 4K** (1.7 GB of memory) lists can drop frames when you scroll fast, and a 4K film that only mpv can play can stutter (measured: about 14 frames a second dropped on one 4K HEVC film). Both are being worked on.
- A big folder loads 600 titles first and the next 600 as you scroll, so a library of tens of thousands is all reachable. Turning on a Filter loads the whole folder at once.
- **Screen walk (developer check)**: `ios/Scripts/check-atlas-walk.sh` opens the screens the Atlas declares on an iPhone and an iPad simulator and reports drift. It cannot reach screens that need a playing stream, a title or a lock, and it lists those as not walkable. There is no Mac version: the Mac app is a SwiftPM executable with no Xcode UI-test target, so a Mac walk would need a small Xcode wrapper that launches the built app by path, a debug hook in the Mac app, and Accessibility permission for the test runner on the owner's Mac.
