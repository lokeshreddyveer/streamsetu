# Security & privacy

- **Credentials** are stored only in the macOS Keychain (`KeychainManager`, generic password items). The database
  holds a reference and a redacted display address. A test dumps every table and asserts no secret appears.
- **Redaction:** `CredentialRedactor` strips `username=`, `password=`, `token=`, `user:pass@` and `/live/user/pass/`
  patterns from logs, errors, diagnostics and toasts.
- **URL validation** (`SourceURLValidator`): only http/https sources; length limits; local files are size-checked and
  copied into the app's own folder. Playlist entries must use a playable scheme (http, https, rtsp, rtmp).
- **Untrusted input:** download size limits (playlist 200 MB, JSON 150 MB, guide 500 MB, image 12 MB); M3U line limit;
  XML external entities disabled; images validated with ImageIO and capped in pixel count; no remote path ever reaches
  the file system.
- **Network:** App Transport Security allows arbitrary loads because IPTV providers commonly use plain http, but the services StreamSetu itself talks to
  (its problem-report server, TMDB, OpenSubtitles, Trakt, GitHub, Wikipedia and the AI providers) are listed as exception domains that require HTTPS. Saving a login for a plain-http
  server that is not on the local network asks first. A redirect to another host, port or scheme repeats the request without the logins we sent (RedirectPolicy).
- **No accounts, no analytics.** There is no tracking. A problem report (a masked playback log, versions, device model and a random install number) is sent only if the person says yes;
  the privacy manifest declares exactly that, and docs/DIAGNOSTICS-PRIVACY.md lists the fields.
- **Hardened Runtime** with minimal entitlements; a sandbox entitlements file is provided for a sandboxed build.
- **MPEG-TS bridge** listens on loopback only.
- **Known trade-off:** M3U playlists whose per-channel URLs embed credentials keep those URLs in the local database
  (they are the stream references). Xtream sources do not: URLs are built at playback time from the Keychain.

## Credentials and keys

Playlist logins and the optional TMDB API key are stored in `LocalCredentialStore`: AES-GCM with a key derived (HKDF) from a random stored key and this Mac's hardware identifier, so a copied vault is unreadable elsewhere. Backups never contain passwords, full playlist addresses or the TMDB key. The TMDB key is sent only to api.themoviedb.org, and errors never include request addresses.
