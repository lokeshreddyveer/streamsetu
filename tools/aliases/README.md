# Offline alias index

An offline, read-only list of names: titles and alternative titles of films and series in about 30 languages and scripts (Latin transliterations included), each with the number the metadata service uses for that film or series. The matcher looks a cleaned library name up in it **by name only** (exact key, then consonant skeleton, then a skeleton one edit away) and then fetches the details by that number. No network is used to read it, nothing about the library leaves the device, and no year, language or popularity is read.

The names come from a public open knowledge base released under CC0 (credit line in Settings, Credits, and in legal/licenses.md).

## File format (`aliases.tsv.gz`)

UTF-8 text, one line per name: `key TAB kind TAB id TAB rank LF`.

- `key`: the normalised name (rules below). Lines are sorted by `key` in byte order, and within one key by `rank`, best first.
- `kind`: `m` film, `t` series.
- `id`: the metadata service's number for that kind.
- `rank`: how well known the item is (number of language editions of its article); only used to choose between items that share a key.
- The file may be plain text or gzip (header without name or time, so rebuilds are byte-identical). Readers: Swift `AliasIndex`, Kotlin `AliasIndex`; shared fixtures: `artwork/fixtures/alias-index-mini.tsv(.gz)` and `alias-cases.json`.

Key rules (`AliasKey.make`, `key_of` in the script; checked by the `keys` list of `alias-cases.json` on all three): compatibility-compose, lower case, `&` becomes `and`, `+` becomes `plus`, apostrophes are removed, combining accents are removed from Latin text only (code points below U+0370, so Devanagari, Telugu, Tamil... keep their signs), every character that is not a letter, digit or combining mark separates words, a leading `the`/`a`/`an` is dropped when more words follow.

## Building

```
python3 -I tools/aliases/build_aliases.py --cache DIR --out artwork/aliases/aliases.tsv.gz --movies 24000 --tv 9000 --fetch
```

1. Items with a film number or a series number, in bands of descending article counts, until `--movies` / `--tv` items are collected.
2. Their labels and aliases in the persona languages, 250 items per query.
3. Keys are computed, duplicates dropped, lines sorted, file written.

Every answer is cached under `DIR`; a stopped run continues, and without `--fetch` the file is rebuilt offline from the cache. Requests go one at a time, 15 s apart, honour `Retry-After`, and use the user agent `StreamSetu-index-builder/1.0`. Running the full size takes a few hours; run it from a development machine, never from the app.

## Size and coverage

Measured numbers are in the measurement report of the matching work (lines, bytes, MB in memory for 66k and 200k libraries). Trade-off: every extra 1,000 items adds roughly 0.05 MB compressed; items are taken best known first, so the first thousands carry most of what a library contains.

## Memory

The text is held once as a byte array plus 4 bytes per line. The phonetic structures (sorted skeleton hashes, 12 bytes per Latin line, and one-edit buckets) are built on first use, from the Latin lines only. Nothing grows with the size of the library.

## Notes from research

- The query service allows 60 s per query and a per-client processing budget, answers 429 with `Retry-After`; so the builder asks in sitelink-count bands (small, bounded answers) and 250-item label batches, one request at a time, caching every answer. A full-size index (hundreds of thousands of items) is better built from the public truthy or JSON dump, streamed through a claim filter, than from the query service.
- Sorted lines with binary search were chosen over front-coded blocks or a finite-state transducer: gzip already removes most of the shared prefixes and a plain byte array needs no library on either platform. Front-coded buckets (a bucket head stored whole, the rest as shared-prefix length plus suffix) are the next step if the index grows past about 20 MB of text.
- The phonetic tier is a consonant skeleton (the Soundex family, tuned for Latin spellings of Indic names) plus one edit; Editex-style letter groups and per-script Indic Soundex codes are possible refinements.
