# Testing

```sh
Scripts/run-tests.sh                 # whole suite
Scripts/run-tests.sh <filter>        # e.g. EPG, "Catalog indexing"
```

The suite uses Swift Testing. With Xcode installed, `Scripts/run-tests.sh` simply runs `swift test`. With only the
Command Line Tools, `swift test` does not launch Swift Testing bundles, so the script builds a tiny host
(`Scripts/TestRunner`) that loads the test bundle and prints failures with file and line.

| Area | Folder |
|---|---|
| Parsers (M3U, Xtream decoding) | `SourceParserTests/` |
| Normalization, grouping | `NormalizationTests/` |
| Database, migrations, health | `DatabaseTests/` |
| Indexing, search, user-data preservation | `IndexingTests/` |
| XMLTV, gzip, mapping, now/next | `EPGTests/` |
| MPEG-TS segmenter, state machine, recovery, engine selection | `PlaybackTests/` |
| Keychain separation, redaction, retry, validation | `SecurityTests/` |
| Sync lifecycle, scheduler, failure handling | `SyncTests/` |
| Real provider, end to end (opt-in) | `LiveProviderTests/` |

### Live provider test
Skipped unless `REDDY_TEST_SERVER`, `REDDY_TEST_USER`, `REDDY_TEST_PASS` are set. It syncs live, movies, series and
the guide, searches, fetches details, and reads real stream bytes. Credentials are only read from the environment.

### UI tests
XCUITest requires an Xcode project. Planned scenarios: onboarding adds a source; search focuses on ⌘F and filters as
you type; Space plays/pauses but not while typing; channel switching keeps the player; fullscreen enter/exit.
