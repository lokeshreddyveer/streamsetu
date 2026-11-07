# Windows stream relay: audit

Written 3 November 2026, about the stream relay of the first Windows attempt (a web view with a local relay in `windows/core` and `windows/src-tauri`). The Windows app is now native (`windows/native`) and plays streams directly in libmpv, so it has no relay. This is kept as the record of that design and of the rules the new app follows for everything it downloads.

Read: `windows/core/src/proxy.rs`, `windows/core/src/rewrite.rs`, `windows/src-tauri/src/lib.rs`, `windows/src-tauri/tauri.conf.json`, `windows/src-tauri/capabilities/default.json`.

## What the relay is

A small web server inside the Windows app, on `127.0.0.1` and a random port. The player page asks it for a stream (`/p?u=<address>`); it fetches the address from the provider and sends the answer back with CORS headers added, because IPTV servers do not send the headers a web page needs. HLS playlists are rewritten so every segment and key address comes back through it.

## What is sound

- It listens on loopback only.
- It fetches only `http://` and `https://` addresses (never `file://`).
- It forwards only the `Range` header, never cookies or logins from the page.
- The app's own pages have a Content-Security-Policy and are the only ones granted capabilities (`windows: ["main"], webviews: ["ui"]`); web pages opened as tabs get no access to the app's commands.
- Playlist logins are kept in the operating system's secret store, not in files.

## Findings

Every finding is from reading the code above.

1. **Open relay with no secret.** There is no token, so anything that can reach the port can use the app as a fetcher: `GET /p?u=http://192.168.1.1/admin` returns the router's page. Loopback is not private from the user's own browser or from other programs on the computer, and the port is found by scanning 127.0.0.1.
2. **CORS `*` lets any web page read the answers.** `Access-Control-Allow-Origin: *` is added to every response, so a script on any site the person visits can read what the relay fetched, including internal services. The in-app browser tabs (`browser_open`) are such pages and run on the same machine.
3. **No `Host` or `Origin` check**, so a name that is made to point at 127.0.0.1 (DNS rebinding) is accepted like any other.
4. **No limit on what it may reach.** Only the scheme is checked. Loopback services (other programs listening locally), the home network, link-local addresses (`169.254.x.x`, cloud metadata) are all fetchable. The HTTP client follows redirects, so an address that passes the scheme check can send the fetch anywhere.
5. **No limits on use.** A thread is started per request, with no cap on connections, no per-session lifetime, and streams are unbounded: any caller can use the computer as a free bandwidth relay or exhaust it with open connections.
6. **`fetch_text` has the same reach** (any `http(s)` address, redirects followed, up to 200 MB read into memory). It can only be called from the app's own pages, which lowers the risk, but it needs the same target rules.

## The rules the Windows app follows

1. **No open door.** The app has no local server. Anything that is downloaded is fetched by the app itself, for the screen that asked.
2. **A target policy.** The name is resolved first and the connection is made to exactly the addresses that pass. Loopback, link-local, multicast, unspecified and private ranges are refused, except for hosts the person has put in a playlist or connection (a provider on the home network is legitimate and keeps working). Addresses with a login embedded in them are refused. Redirects are followed by hand, a few at most, applying the same policy at every step.
3. **Limits.** Downloads and unpacked files have size limits; a playlist is read up to a fixed size; a guide file that expands without end is cut off.
4. **Outside data is not trusted.** XML is read with DTDs refused; backup files and update files are checked before anything is replaced or run.

## What the native app does instead

There is no local server. Everything the app downloads (playlists, provider answers, pictures, subtitles, updates) goes through one downloader that follows the policy above: web addresses only, never this computer or the local network unless the host is in a saved connection, no logins inside addresses, redirects checked at every step, and size limits. Streams are played by libmpv itself.

## Decision

The relay was dropped in favour of the native app described above.
