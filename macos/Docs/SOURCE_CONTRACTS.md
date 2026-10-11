# Source contracts

Every source implements `SourceProvider`: `validate()` → capabilities, `categories(kind)`, batched
`channels()/movies()/series()` streams, on-demand `movieDetail` / `seriesDetail`, `epgLocation()` and
`streamURL(kind:ref:)`. A provider that does not offer movies reports `movies = false`; an empty movie list from a
provider that does is a different, reported condition.

## Ingestion pipeline

validate → authenticate → download to a temp file (size-limited, cancellable, retried with backoff) → parse →
validate each record → normalize → assign stable ids → de-duplicate → commit in one transaction → update the search
index → rebuild guide mappings → publish to the UI.

## M3U / M3U8

Parsed incrementally from disk in 256 KB chunks. Handles BOM, CRLF/LF, quoted attributes (including commas),
missing metadata, oversize lines (skipped, counted), relative URLs (resolved against the playlist address) and
non-playable schemes (rejected; only http, https, rtsp, rtmp). Content decides the format: a file with
`#EXT-X-TARGETDURATION` and no catalog attributes is a single HLS stream, not a channel list. `/movie/` URLs become
movies; `/series/` URLs are skipped (a flat list cannot express seasons). Decorative separator rows
(`####### Group #######`) are dropped.

## Xtream-compatible

Uses `player_api.php` (works when `get.php` is disabled): `get_live_categories`, `get_live_streams`,
`get_vod_categories`, `get_vod_streams`, `get_vod_info`, `get_series_categories`, `get_series`, `get_series_info`,
and `xmltv.php` for the guide. Decoding is lenient (ids may be strings or numbers; empty sections may be `false`,
`{}` or `null`; episodes may be a dictionary or an array). Stream URLs are `/live/<u>/<p>/<id>.<ts|m3u8>`,
`/movie/…/<id>.<ext>`, `/series/…/<id>.<ext>`, built at playback time from Keychain credentials.

## XMLTV

Downloaded (conditional on ETag/Last-Modified), decompressed in a streaming fashion if gzip, parsed with
`XMLParser(stream:)` with external entities disabled, kept only inside the retention window. Times are stored in UTC.
Channel matching order: user mapping → exact EPG id → provider id → unique-name match. Ambiguous names are left
unmatched; the UI says “Program information unavailable” rather than guessing.
