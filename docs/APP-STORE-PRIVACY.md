[← Back to the README](../README.md)

# App Store privacy answers (iPhone and iPad)

For whoever fills in App Store Connect. The app has no account, no analytics, no advertising and no tracking, and the App Store build sends no problem reports. Everything below is what the app sends **only when the person turns a feature on or adds their own key or account**. Please confirm each answer against the current app before submitting; the manifest in `ios/StreamSetu/PrivacyInfo.xcprivacy` is written to match.

## What leaves the device, and when

| Service | What is sent | When |
|---|---|---|
| The Movie Database (TMDB) | A title and year (never a title in a locked or hidden folder, or with a copy in one); a person's name when asking about them | Only with the person's own TMDB key |
| OpenSubtitles | The title, year and language searched for; the person's own account name and password to download | Only when the person asks for subtitles and has entered their own key and account |
| Trakt | What was watched, and the sign-in | Only after the person signs in to Trakt and turns it on |
| Real-Debrid, AllDebrid, Premiumize | The link being unrestricted, with the person's own account token | Only when the person adds that account |
| AI providers (Apple Intelligence on the device, or Google Gemini, Groq, NVIDIA, OpenRouter, Anthropic Claude, OpenAI, Ollama the person chooses) | The question typed and the library facts needed to answer it | Only with a provider and key the person picks; the assistant button is switched off in the iPhone and iPad build for now |
| Wikipedia, Apple iTunes search, YouTube | A title or show name looked up for an answer, podcast search, or a trailer page | Only when the person uses that feature |
| The person's own playlist provider | The login the person typed, and the stream requests | Always, as that is what the app is for |

Nothing is sent to the developer. No identifier is used to link any of this to the person.

## Answers in App Store Connect

The answers already given for earlier versions stay as they are: **Data Not Collected**. The calls in the table above are requests the person starts themselves, to services they added with their own key or account, and nothing is sent to the developer. The privacy manifests in the app say the same (`NSPrivacyCollectedDataTypes` is empty), so the manifest and the App Store answer agree.

Change the answers (and the manifests, together) only if the app starts sending anything to the developer, adds analytics or advertising, or sends data to a service the person did not add.
