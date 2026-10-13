# StreamSetu on iPhone and iPad: 10-minute check before each TestFlight build

There is no iPhone simulator on this Mac, so the player is checked by building and by hand. Run this on the phone with the build installed.
Tick each line. Write down anything that fails with the title, the time and a screenshot.

## 1. Opens (1 min)
- [ ] App opens in under 5 seconds, Home shows rows, no spinner stuck.
- [ ] First launch only: the "Automatic problem reports" notice appears once and has OK and Turn Off.

## 2. A movie, both ways up (3 min)
Play any MP4 movie. Check in portrait, then turn to landscape.
- [ ] Controls: close arrow, title, AirPlay and **⋯** are all visible at the top, nothing cut off at either edge.
- [ ] Back 10, play/pause and forward 30 sit in the middle of the screen, both across and up and down.
- [ ] The seek bar and the three times (position, "Ends", remaining) fit inside the screen.
- [ ] The chips row (picture, format, audio, subtitles, speed, player) sits above the bottom edge and every chip responds to one tap.
- [ ] Tap the audio chip: a small menu with only audio languages. Tap subtitles: Off, languages, "Add subtitle file…". No full-screen options.
- [ ] Double-tap right three times: "+10 s", "+20 s", "+30 s", and no slider or buttons appear.
- [ ] Swipe along the picture: a time preview shows, and letting go jumps there.
- [ ] Swipe up and down on the left (brightness) and right (volume). Hold the picture for 2×.
- [ ] Let the controls hide: one small faint line stays at the bottom edge.

## 3. ⋯ More menu (1 min)
- [ ] Options, Fit/Fill, Picture in Picture, Sleep Timer, Lock Controls, Stop all present.
- [ ] Lock Controls: only a tap shows "Unlock controls".
- [ ] Options sheet: sound sync steps, subtitle timing and size, speed, picture shape and zoom, stream details.

## 4. Live TV (2 min)
- [ ] Live TV opens as tiles; the toolbar button switches to the list and back.
- [ ] Play a channel. Swipe in the middle to change channel; the banner shows number, name, now playing.
- [ ] Channels opens a side panel with search and a folder menu. Guide shows now and next.
- [ ] ⋯ has Favourite, Last Channel, Channel Number, Multi-View.

## 5. Failures and network (2 min)
- [ ] Play a title the provider refuses: after about 3 tries a plain message appears, with Try Again and Send My Log.
- [ ] Switch on Airplane Mode while playing: "No internet connection". Switch it off: playback resumes by itself.

## 6. After (1 min)
- [ ] Watch a movie for over a minute, close it: it appears under Continue Watching on Home.
- [ ] Settings → Send Feedback → Send My Log Now says "Sent. Thank you."
- [ ] Settings → Playback → Player: choosing MPV shows the explanation first.

## Known limits
- Save Frame, A–B repeat, frame step and volume boost only appear when the player is MPV.
- On the player's controls, fonts are fixed sizes; Dynamic Type applies to the Options sheet.
