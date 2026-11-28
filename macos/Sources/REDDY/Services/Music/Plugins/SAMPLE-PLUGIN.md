# StreamSetu music plugins (API version 1)

A plugin adds a music source (search and browse, audio, lyrics or scrobbling) without a new app release. It is a small JavaScript file plus a manifest. It runs in a sandbox inside the app, and it can only do what its manifest asks for and the person approved.

**Format.** This is StreamSetu's own plugin format: plugins written for other apps cannot be loaded as they are. The methods follow a metadata / audio / lyrics / scrobble split, so a plugin written for another app has to be rewritten in JavaScript against this document.

## Package

A plugin is one of:

- a folder with `plugin.json` and the entry script (`main.js`);
- a `.sbplugin` file, which is a zip containing `plugin.json` and `main.js` at its root (stored or deflated, no encryption, no zip64);
- a `.sbplugin` file that is a plain JSON bundle: `{"manifest": { ...plugin.json... }, "files": {"main.js": "<base64 of the script>"}}`.

Limits: whole package 5 MB, `plugin.json` 64 KB, script 4 MB. Any other file in the package is ignored and never written to disk. An archive that contains an unsafe path anywhere (absolute, `..`, backslash, drive letter) is rejected as a whole. Installing never enables a plugin; the person turns it on in Settings.

## plugin.json

```json
{
  "id": "example-source",
  "name": "Example Source",
  "version": "1.0.0",
  "author": "Your Name",
  "summary": "Search and play tracks from the Example service.",
  "apiVersion": 1,
  "entry": "main.js",
  "homepage": "https://example.com/plugin",
  "capabilities": ["metadata", "audio", "lyrics"],
  "permissions": [
    { "name": "network", "hosts": ["api.example.com", "*.cdn.example.com"] },
    "storage",
    "crypto",
    "signIn"
  ]
}
```

- `id`: 2 to 48 characters, lowercase letters, digits and hyphens. It must not equal a built-in source id.
- `apiVersion`: must be 1.
- `capabilities`: any of `metadata`, `audio`, `lyrics`, `scrobble`. Each becomes a provider in the app. The first one keeps the plugin id; the others are `<id>.audio`, `<id>.lyrics`, `<id>.scrobble`.
- `permissions`: `network` needs a host list (exact names or `*.domain` for subdomains; no IP addresses, no `localhost`; at most 16). `storage` gives the key-value store and Keychain secrets. `crypto` gives hashing helpers. `signIn` marks the plugin as needing an account and enables `login` / `logout` / `isLoggedIn`.

Settings shows the permissions and hosts before the plugin is enabled. The app also uses the host list as the privacy note on the plugin.

## main.js

Assign a global called `plugin` with `var plugin = {...}` or `globalThis.plugin = {...}`. Every method may be `async`. A method the plugin does not define is reported as "not supported" and is not an error. Arguments and results are JSON.

### Throwing errors

`throw new Error("...")`. If the message starts with `notSignedIn`, `notFound` or `rateLimited` the app treats it as that kind of error; anything else is shown as a plugin error (first 300 characters).

### Shared JSON shapes

Field names are exactly the Codable keys of the app models. Optional fields may be left out. Items missing `id` or `title`/`name` are dropped. Every URL (`url`, `externalURL`, thumbnails, streams) must be `https`; other addresses are discarded. The `providerID` you send back is ignored and replaced by the app.

```
Thumbnail   { url, width?, height? }            (a plain string url is also accepted)
ArtistRef   { id, name, thumbnails?, externalURL? }
AlbumRef    { id, title, artists?, thumbnails?, releaseDate?, totalTracks?, albumType?, externalURL? }
Track       { id, title, durationMs, artists: [ArtistRef], album?: AlbumRef, trackNumber?, discNumber?, thumbnails?,
              explicit?, popularity?, isrc?, externalURL?, directStreams?: [Stream] }
Artist      { id, name, thumbnails?, genres?: [string], followers?, bio?, externalURL? }
Album       { id, title, artists?, thumbnails?, releaseDate?, totalTracks?, albumType?, label?, externalURL? }
Playlist    { id, name, summary?, owner?, thumbnails?, trackCount?, isPublic?, externalURL? }
User        { id, username, displayName?, thumbnails?, externalURL? }
Genre       { id, name, thumbnails? }
BrowseItem  one of Track / Album / Artist / Playlist plus "type": "track" | "album" | "artist" | "playlist"
Section     { id, title, items: [BrowseItem] }
Stream      { url, codec, container, proto?: "progressive"|"hls"|"dash", bitrate?, sampleRate?, headers?: {name: value},
              expiresAt?: <unix seconds> }
AudioSource { id, title, artist?, album?, durationMs?, thumbnails?, externalURL?, confidence: 0..1, streams?: [Stream] }
Lyrics      { synced?: [{ timeMs, text }], plain?, sourceName? }
```

`durationMs` and `timeMs` are milliseconds. `bitrate` is kbps for lossy audio and absent for lossless.

### Pagination

A page argument is `null` (first page) or one of

```
{ kind: "offset", offset, limit }   { kind: "cursor", cursor, limit }
{ kind: "page", page, size }        { kind: "continuation", token }
```

and a paged method returns `{ items: [...], totalCount?, next? }`, where `next` has the same shape, or is `null` or left out for the last page. A bare array is accepted as one last page.

### Methods

Metadata (`metadata` capability):

`searchTracks(query, page)`, `searchArtists(query, page)`, `searchAlbums(query, page)`, `searchPlaylists(query, page)` return pages. `featured()` returns `[Section]`. `genres()` returns `[Genre]`. `browse(genreID, page)` returns a page of Section. `getTrack(id)`, `getAlbum(id)`, `getArtist(id)`, `getPlaylist(id)` return one object. `getUser(id)` returns a User or null. `recommendations(seedTrackIDs, limit)`, `artistTopTracks(id)` return `[Track]`. `relatedArtists(id)` returns `[Artist]`. `albumTracks(id, page)`, `playlistTracks(id, page)` return pages of Track. `artistAlbums(id, page)` returns a page of Album. With `signIn`: `savedTracks(page)`, `savedAlbums(page)`, `savedArtists(page)`, `savedPlaylists(page)`, `setSaved(saved, trackIDs)`, `isSaved(trackIDs)` (array of booleans).

Audio: `sources(track)` returns `[AudioSource]` best first (`track` is the full Track object); `streams(source)` returns `[Stream]` for a source that came back without streams.

Lyrics: `lyrics(track)` returns Lyrics or null.

Scrobble: `scrobble({ timestamp, playedMs, track })` (timestamp in unix seconds) and optionally `nowPlaying(track)`.

Account (`signIn` permission): `login({})`, `logout()`, `isLoggedIn()` returning a boolean. The app has no web view for plugins in API 1, so `login` should read credentials the person stored with the plugin's secret fields in Settings (`host.storage.getSecret(name)`) and verify them.

## Host API (the global `host`, frozen)

Only the parts the manifest permits exist; the app checks every permission again in Swift.

- `host.http.fetch(url, { method, headers, body, responseType })` returns a promise of `{ status, ok, url, headers, text(), json(), base64() }`. Only https, only the standard port, only the listed hosts (a redirect to any other host is refused), methods GET POST PUT PATCH DELETE HEAD, body a string up to 1 MB, reply up to 5 MB, 20 s per request, at most 8 at once. Use `responseType: "base64"` for binary replies. Cookies are not kept.
- `host.storage.get(key)`, `set(key, value)`, `remove(key)`: JSON values in one small file per plugin, 256 KB in total, 256 keys, key up to 128 characters; `set` throws when full. `getSecret(key)`, `setSecret(key, string)`, `removeSecret(key)` keep small strings in the Keychain.
- `host.crypto.md5(text)`, `sha1`, `sha256`, `hmacSha256(key, text)` return lowercase hex. Pass `{ input: "utf8" | "base64" | "hex", output: "hex" | "base64" }` as the last argument to change encodings. `base64Encode(text)`, `base64Decode(b64)` (UTF-8 text), `randomBytes(count)` (1 to 1024, hex).
- `host.system`: `{ platform: "macos" | "ios", appVersion, locale, apiVersion }`.
- `console.log / info / warn / error / debug` go to a per-plugin log of the last 200 lines, kept in memory on the device.

Not available: files, processes, timers (`setTimeout`), `XMLHttpRequest`, WebSocket, DOM. The host never evaluates code it downloads. A call that takes longer than 20 seconds is abandoned and reported as a timeout. A script stuck in a synchronous infinite loop cannot be interrupted; the call still times out, but disable the plugin to stop it.

## Sample: a metadata and lyrics plugin

`plugin.json` as above with `"capabilities": ["metadata", "lyrics"]` and permissions `network` (`api.example.com`) and `storage`. The service here is imaginary; adapt the URLs and fields.

```js
// main.js
var BASE = "https://api.example.com/v1";

function toTrack(x) {
  return {
    id: String(x.id),
    title: x.title,
    durationMs: Math.round((x.seconds || 0) * 1000),
    artists: [{ id: String(x.artist_id), name: x.artist }],
    album: x.album ? { id: String(x.album_id), title: x.album } : undefined,
    thumbnails: x.cover ? [{ url: x.cover, width: 300, height: 300 }] : [],
    explicit: !!x.explicit
  };
}

async function getJSON(path) {
  var res = await host.http.fetch(BASE + path, { headers: { Accept: "application/json" } });
  if (res.status === 404) { throw new Error("notFound"); }
  if (res.status === 429) { throw new Error("rateLimited"); }
  if (!res.ok) { throw new Error("service answered " + res.status); }
  return res.json();
}

var plugin = {
  async searchTracks(query, page) {
    var offset = page && page.kind === "offset" ? page.offset : 0;
    var limit = page && page.kind === "offset" ? page.limit : 30;
    var data = await getJSON("/search?type=track&q=" + encodeURIComponent(query) + "&offset=" + offset + "&limit=" + limit);
    var next = data.total > offset + limit ? { kind: "offset", offset: offset + limit, limit: limit } : null;
    return { items: data.items.map(toTrack), totalCount: data.total, next: next };
  },

  async getTrack(id) {
    return toTrack(await getJSON("/tracks/" + encodeURIComponent(id)));
  },

  async lyrics(track) {
    var data = await getJSON("/lyrics?title=" + encodeURIComponent(track.title) + "&artist=" + encodeURIComponent(track.artists[0] ? track.artists[0].name : ""));
    if (!data.lines) { return null; }
    return { synced: data.lines.map(function (l) { return { timeMs: l.ms, text: l.text }; }), sourceName: "Example Lyrics" };
  }
};
```

## Sample: an audio plugin

`plugin.json` with `"capabilities": ["audio"]` and the `network` permission for `api.example.com`. `sources` proposes recordings best first with a `confidence` from 0 to 1 (the app also scores them itself); a source may carry `streams`, or the app calls `streams` for it.

```js
// main.js
var BASE = "https://api.example.com/v1";

var plugin = {
  async sources(track) {
    var artist = track.artists && track.artists[0] ? track.artists[0].name : "";
    var res = await host.http.fetch(BASE + "/find?title=" + encodeURIComponent(track.title) + "&artist=" + encodeURIComponent(artist));
    if (!res.ok) { throw new Error(res.status === 429 ? "rateLimited" : "service answered " + res.status); }
    return res.json().matches.map(function (m) {
      return { id: String(m.id), title: m.title, artist: m.artist, durationMs: m.ms, confidence: m.score };
    });
  },

  async streams(source) {
    var res = await host.http.fetch(BASE + "/media/" + encodeURIComponent(source.id));
    if (res.status === 404) { throw new Error("notFound"); }
    return res.json().files.map(function (f) {
      return { url: f.url, codec: f.codec, container: f.container, bitrate: f.kbps, headers: { Referer: "https://example.com/" } };
    });
  }
};
```

## Install, enable, remove

`MusicPluginManager.install(from:)` takes a folder or `.sbplugin`. `install(fromRemote:confirm:)` takes an https address, downloads into memory, validates, and calls `confirm` with the manifest; nothing is written unless it returns true. Installing stores the two files under `installed/<id>/` and leaves the plugin switched off. `setEnabled(true, id:)` is the person's act and registers the providers. `remove(id:)` also deletes the plugin's storage file and Keychain secrets.
