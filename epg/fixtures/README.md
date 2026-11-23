# Guide hub fixtures

Owner: the StreamSetu maintainer. The Apple and Android test owners keep both ports equal to these files. Shared by Swift and Kotlin (enforced by `Scripts/check-fixtures.py`); the Windows (C#) port is on hold.

Shared by the Apple tests (`macos/Tests/REDDYTests/GuideHubTests`) and the Android tests (`android/data/src/test/kotlin/app/streamsetu/core/data/guidehub`). Everything here is synthetic: invented channel names, ids and hosts under `example.test`. No provider, library or personal data.

| File | What it pins |
|---|---|
| `mapping-cases.json` | Channel-to-guide matching. One `guide` list shared by all cases, then `cases`: a channel and the expected `status` (`mapped`, `suggested`, `unmapped`), `source`, `xmltv`, `method`, `confidence` (or `minConfidence`/`maxConfidence`), or `reason` for unmapped. Applies at confidence 0.60 and up. |
| `iptvorg-cases.json` + `iptvorg-mini/` | Enrichment from the public channel database: id match, name plus country, alternative names, blocked, closed, adult and restricted records, logo choice (current, at least 128 px, https, PNG/WebP first). `blocklist.json` is mandatory: without it nothing is matched (fail closed). |
| `freshness-cases.json` | Guide freshness: `now`, `windowEnd`, `lastSuccess`, refresh interval and programme count give a message key and level (`fresh`, `info`, `warning`, `error`). |
| `timezone-cases.json` | XMLTV time parsing: offsets (`+0100`, `+01:00`, `Z`, none), `auto`/`utc`/`local` modes with an IANA zone, a spring-forward gap (moved forward) and an autumn overlap (first occurrence), invalid input. |
| `xmltv/*.xml`, `gzip.xml.gz` | Decoder inputs: `basic` (icon, category, lang, rating, dropped invalid), `with-offsets`, `episode-num` (xmltv_ns and onscreen), `dtd-xxe` (an external entity must not be read), `huge-names` (text is cut), `all-past` and `channels-only` and `invalid-times` (an "empty guide" must be explained), `not-a-guide`. |

Rules the Kotlin port must match exactly: the name normaliser (lowercase, diacritics folded, `&` is "and", quality words removed, country prefix removed only for known country codes, `+N` kept as a variant that never matches another variant), the order of trust and confidences in `GuideMappingEngine`, and the freshness thresholds in `GuideFreshness`. The Swift sources are in `macos/Sources/REDDY/Services/Guide/`.

`mapping-persona.json` has the same layout as `mapping-cases.json` (`guide`, then `cases` with `channel` and `expect`) and pins the guide-matching fixes found by the persona evaluation (feed words, numbers, id guard). Apple: `PersonaFixesTests`; Android: `GuideHubFixtureTest.personaMappingCases`.
