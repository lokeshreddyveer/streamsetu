# Next release (DRAFT, not released)

Working notes for the release after 2026.11.21. Nothing here is shipped. Rename to the release tag and trim when the versions are chosen. "Checked" means a build or test was run for it; "Not checked" means it is listed from the work done and still needs a hands-on check on a device before it goes in the final notes.

## On every app (Mac, iPhone and iPad, Android phone and tablet, Fire TV and Android TV)
- **Title pages** reworked for movies and series. Not checked.
- **Genre shelves** on Home and Browse, with an **All time / Trending** switch. Not checked.
- **Stars on every tile**, using one shared rating rule so the same title shows the same stars everywhere. Not checked.
- **Better matching of titles to artwork and details** (matcher v2). Not checked.
- **More artwork and details from four sources** behind one layer: the details service, the artwork service, the episode-data service (on by default; or use your own key) and the schedule service. Only ids go to the three new services, never your history, lists or folder names, and locked or hidden folders are never sent. Each can be turned off in Settings. Not checked end to end.
- **The details service works out of the box** with a key built into the app (you can still add your own), and can be turned off in Settings. This replaces the 2026.11.21 wording that said a key of your own was needed.
- **Privacy Policy and credits updated** for the artwork service, the episode-data service, the schedule service, the details service, Sparkle and libmpv. Checked: legal text is in sync across the apps and website.
- **Privacy declaration.** The App Store privacy answer and the privacy manifests now declare the titles and years sent to the artwork and details services as Other User Content (App Functionality, not linked to you, not used for tracking). These services also see your IP address. Nothing changes in what is sent; each source can be turned off in Settings. Not shipped yet.
- **Search fixes.** Not checked.
- **Speed work** (faster screens and loading). Not measured on a device yet.

## Mac
- **Streaming services inside the app:** a Services menu (can be pinned to the top bar) opens a provider's own site in the app, with a way to clear each service's data. Mac only. **Not verified:** unit tests cover the logic, but the services themselves still need the owner to try them on his Mac. Release is on hold.
- **Services panel and top bar:** each service now shows its own icon in a themed panel; Settings has a card per service with Clear Data. Verified by the owner by hand on his Mac for all services except the one on hold. Release is on hold.
- **Optional page options for one service (off by default):** skipping its video ads and community-marked sponsor segments, asked first with the risks explained, shown once on first open and any time in Settings. Checked by tests; hands-on check by the owner still pending.
- **A further service is on hold:** its code is in place but hidden; it is not part of this release.
- **Diagnostics for service load failures** and smoother scrolling. Checked by tests (scroll speed not measured on a device).
- **Top bar and search fixes** for the service buttons and navigation. Tests pass; hands-on check still needed.

## Verified by tests, still needs a hands-on check
- Verified by tests: Mac full suite (2021, run twice), iPhone and iPad suite (33, 1 skipped), Android (1361, plus lint and R8), strict Atlas check, shared check scripts (5/5), secret scan, host-parity check.
- Still needs the owner's hands: streaming services on the Mac, title pages, genre shelves, matching quality on a real library, and the Setu assistant on iPhone and iPad.

## iPhone and iPad
- **The Setu assistant is on** (chat button at the bottom right, hidden in kids mode). It was off in the App Store build before. Not checked on a device.
- **Setu upgrade:** better answers about the app. Not checked.

- Mac: Setu upgrade as above. Not checked.

## Android phone and tablet, Fire TV and Android TV
- **Stricter secure connections:** the metadata, subtitle, the watch-history service, the encyclopedia service and AI services are https only, matching iPhone and iPad. Checked: host lists match (Scripts/check-host-parity.py).

## Live TV
- No Live TV changes listed yet. Add them here only if they were done.

## Before this ships
- Apply the App Store privacy answers by hand in App Store Connect (steps in docs/APP-STORE-PRIVACY.md) before submitting.
- Commit the pending changes (the release script needs a clean tree), choose versions, write the final notes, run Scripts/test-release-gates.sh.
