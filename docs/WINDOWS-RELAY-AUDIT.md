# Windows stream relay: audit

Written 3 November 2026. **Windows is not released** (the README says "Coming soon"); nothing described here ships, and no Windows code was changed. This is the record of what was found and the bar the relay has to meet before Windows can come back.

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

Every finding is confirmed by reading the code above; none was run, because there is nothing built to run.

1. **Open relay with no secret.** There is no token, so anything that can reach the port can use the app as a fetcher: `GET /p?u=http://192.168.1.1/admin` returns the router's page. Loopback is not private from the user's own browser or from other programs on the computer, and the port is found by scanning 127.0.0.1.
2. **CORS `*` lets any web page read the answers.** `Access-Control-Allow-Origin: *` is added to every response, so a script on any site the person visits can read what the relay fetched, including internal services. The in-app browser tabs (`browser_open`) are such pages and run on the same machine.
3. **No `Host` or `Origin` check**, so a name that is made to point at 127.0.0.1 (DNS rebinding) is accepted like any other.
4. **No limit on what it may reach.** Only the scheme is checked. Loopback services (other programs listening locally), the home network, link-local addresses (`169.254.x.x`, cloud metadata) are all fetchable. The HTTP client follows redirects, so an address that passes the scheme check can send the fetch anywhere.
5. **No limits on use.** A thread is started per request, with no cap on connections, no per-session lifetime, and streams are unbounded: any caller can use the computer as a free bandwidth relay or exhaust it with open connections.
6. **`fetch_text` has the same reach** (any `http(s)` address, redirects followed, up to 200 MB read into memory). It can only be called from the app's own pages, which lowers the risk, but it needs the same target rules.

## The bar, if Windows comes back

Nothing below is built. It is the list of what must exist, with tests, before a Windows build is released.

1. **Per-session secret.** A random token of at least 128 bits from the operating system's generator, made when the app starts and never written to disk. Every request must carry it, compared in constant time. Media elements cannot set headers, so it goes in the path (`/s/<token>/p?u=`), and the playlist rewriting puts the same prefix on every address it rewrites. The page learns it only through the existing `proxy_base` command, so pages opened as tabs never see it.
2. **`Host` and `Origin` validated.** `Host` must be exactly `127.0.0.1:<port>`. When an `Origin` is present it must be one of the app's own origins; anything else gets 403. CORS answers name that one origin; the wildcard goes away.
3. **A target policy.** Resolve the name before connecting. Refuse loopback, link-local, multicast, unspecified and private ranges, except for hosts the person has put in a playlist or connection (a provider on the home network is legitimate and must keep working). Refuse addresses with a login embedded in them. Follow redirects by hand, a few at most, applying the same policy to every hop.
4. **Limits.** A cap on simultaneous connections, an idle timeout, and the token's lifetime ending with the app. The existing 4 MB limit on playlists stays.
5. **`fetch_text` follows the same target policy** and a smaller size limit.
6. **Tests that fail first.** A request with no token, a wrong token, a foreign `Origin`, a wrong `Host`, a loopback or LAN target not in the allowlist, a redirect to such a target, and the connection cap must each be refused, and the playlist rewriting must keep the token prefix. The existing tests (stream passes through, playlist rewritten, `file://` refused) must still pass.
7. **Release gate.** The Windows build is not offered until those tests are part of the release checks (`Scripts/verify-release-artifacts.sh`).

## Status, 7 November 2026

Items 1 to 4 and 6 of the bar are built and tested in `windows/core` (`policy.rs`, `proxy.rs`: 18 Rust tests; each rule has a test that fails without it). The Tauri shell in `windows/src-tauri` was not updated to the new relay and does not compile against it, because the Windows app is being rebuilt as a native app (WinUI 3 with libmpv), which plays streams directly and needs no relay. The address rules in `policy.rs` still apply to anything the native app fetches.

## Decision

Windows stays out of scope for now: no relay change, no Windows release. If it returns, start from the list above.
