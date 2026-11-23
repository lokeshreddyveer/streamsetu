[← Back to the README](../README.md)

# App Store privacy answers (iPhone and iPad)

For whoever fills in App Store Connect. The app has no account, no analytics, no advertising and no tracking, and the App Store build sends no problem reports. The owner decided to declare the metadata lookups (decision final). The tables below list what leaves the device. Most rows apply only when the person turns a feature on or adds their own key or account; the metadata rows (the details service, the artwork service, the schedule service) are on by default. Please confirm each answer against the current app before submitting; the manifest in `ios/StreamSetu/PrivacyInfo.xcprivacy` is written to match.

## What leaves the device, and when

| Service | What is sent | When |
|---|---|---|
| The details service | A title and year (never a title in a locked or hidden folder, or with a copy in one); a person's name when asking about them | By default, with the key built into the app (or the person's own key); off when the person turns artwork matching and trending off in Settings. Declared, see below |
| The artwork service, the schedule service | Only a numeric id (the details service, the episode-data service or IMDb) or a country code, plus an access key in a header; never a title, history, list, folder name or profile; the image hosts see the IP address | The artwork service and the schedule service on by default; each can be turned off in Settings. Never for locked, hidden or kids-restricted titles |
| The episode-data service | Same: numeric ids and a key only | ON by default with the app's project key (sends titles, years and ids only; the episode-data service sees the IP address); a per-source switch in Settings turns it off; works with the person's own key; credited in Settings only |
| The subtitle service | The title, year and language searched for; the person's own account name and password to download | Only when the person asks for subtitles and has entered their own key and account |
| The watch-history service | What was watched, and the sign-in | Only after the person signs in to the watch-history service and turns it on |
| Linked accounts services | The link being unrestricted, with the person's own account token | Only when the person adds that account |
| AI providers (Apple Intelligence on the device, or Google Gemini, Groq, NVIDIA, OpenRouter, Anthropic Claude, OpenAI, Ollama the person chooses) | The question typed and the library facts needed to answer it | Only with a provider and key the person picks; the Setu assistant button is ON in the iPhone and iPad build (hidden in kids mode); it sends nothing until a provider and key are chosen, and Apple Intelligence runs on the device |
| The encyclopedia service, Apple iTunes search, YouTube | A title or show name looked up for an answer, podcast search, or a trailer page | Only when the person uses that feature |
| public channel database | Whole public files downloaded; nothing about the person or library is sent (the host sees the IP address) | On by default; off in Settings, Guide sources |
| Cloudflare, Google, Quad9, AdGuard (App DNS) | Host names the app connects to, over encrypted DNS | Only when the person turns on App DNS (off by default) |
| GitHub (update check, add-on list) | Nothing but the app version; not in the iPhone or iPad build (Mac download and Android only) | Automatic in the Mac download; switchable on Android |
| The person's own playlist provider | The login the person typed, and the stream requests | Always, as that is what the app is for |

Nothing is sent to the developer. No identifier is used to link any of this to the person.

## Final answer (owner decision: declare it)

The details service matching and trending stay ON by default; the data is declared, not hidden. The old answer "Data Not Collected" must NOT be used. The services also see the device IP address, as any web service does; no identifier is sent.

**Declared data:** Other User Content (the titles and years looked up for artwork and details), purpose App Functionality, **not linked to the user**, **not used for tracking**. Nothing is collected by the developer; the data goes to the third parties named above. Manifests: `ios/StreamSetu/PrivacyInfo.xcprivacy` and `macos/Configuration/PrivacyInfo.xcprivacy` declare exactly this (`NSPrivacyTracking` false, no tracking domains). The Mac manifest also declares the opt-in problem-report types (DeviceID, Other Diagnostic Data, linked, App Functionality); the iPhone and iPad build sends no reports. Gates: `macos/Scripts/verify-release.sh` and the `theIPhoneManifestDeclaresTheTitleLookups` test assert the declared set.

### What to select in App Store Connect (the owner applies this by hand)

App Store Connect > the app > App Privacy > Get Started / Edit.
1. "Do you or your third-party partners collect data from this app?" Choose **Yes, we collect data from this app**.
2. On the data-types list, tick only **User Content > Other User Content**. Leave everything else (Contact Info, Health, Financial, Location, Sensitive Info, Contacts, Browsing History, Search History, Identifiers, Purchases, Usage Data, Diagnostics, Other Data) unticked. Search History is not used: no search the person types is sent, only titles from their own playlist.
3. Press Next, then for Other User Content answer:
   - Purposes: tick **App Functionality** only (not Analytics, Product Personalization, Third-Party Advertising, Developer's Advertising or Other).
   - "Is Other User Content linked to the user's identity?" **No**.
   - "Do you or your third-party partners use Other User Content for tracking purposes?" **No**.
4. Publish the answers. Do this before submitting a build whose manifest has the declaration, and check the generated nutrition label reads: Data Not Linked to You: Other User Content.
5. The privacy policy URL must stay the page with the synced text (`legal/privacy.md`).

Optional services (the watch-history service, the subtitle service, linked-account, AI providers; the account token goes only to the service the person chose, never to the developer, so no new App Store data category is needed for it, nor for the channel database, DNS or GitHub rows) send data only when the person adds their own account or key; they are the person's own choice and are covered by the policy, not added to the label unless a reviewer asks.

### Google Play Data safety (for a possible future Play release)

- Does the app collect or share required user data types? **Yes**.
- Data type: **App activity > Other user-generated content** is the closest fit (titles and years); if Play offers "Search history" it is not used.
- Collected: No (the developer receives nothing). **Shared: Yes**, with third parties (the details service, the artwork service, the schedule service; the episode-data service when on), purpose **App functionality**.
- "Is this data processed ephemerally?" No (the services may log requests).
- "Is data collection required or optional?" Choose **Optional**: the person can switch every provider off in Settings (Artwork and details), after which nothing is sent and the app still works. Honest note: it is on by default, so it is not off until the person acts; do not describe it as "required", because the app works without it.
- Security: data is encrypted in transit (https only); users can request deletion: not applicable, nothing is held by the developer.
- Link the same privacy policy URL. Do not claim "no data shared".

### What's New / nutrition note text

What's New (short): "Artwork and details now come from more sources (the details service, the artwork service, the schedule service, the episode-data service). Only a title and year or a public id is sent, never your history, lists or folder names, and you can turn each source off in Settings."

Privacy note (for the App Store description or review notes): "StreamSetu has no account, analytics or advertising. To show posters and details it sends a title and year (or a public id) to the details service, the artwork service and the schedule service, which also see your IP address as any web service does. This is declared as Other User Content, not linked to you and not used for tracking. Each source can be turned off in Settings, and titles in locked, hidden or kids folders are never sent."

Change the answers (and the manifests, together) also if the app starts sending anything to the developer, adds analytics or advertising, or sends data to a service the person did not add.
