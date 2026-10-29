# Release security gate

Every release script runs `Scripts/audit-dependencies.py --strict` and stops on anything but a clean result. There is no environment variable or flag that skips it.

| Product | Script | Scope | Kept with the release |
|---|---|---|---|
| iPhone / iPad | `ios/Scripts/testflight.sh` | Swift packages, website | `…/StreamSetuRenew/testflight/reports/dependencies-<build>.json` |
| Mac | `macos/Scripts/release-signed.sh`, `release-dmg.sh` | Swift packages, website, **bundled media libraries** | `macos/dist/security/dependencies-<version>.json` and `sbom-<version>.cdx.json` |
| Android | `android/release.sh` | Swift-free: Gradle dependencies are checked by lint | n/a |

Three outcomes are kept apart: clean (exit 0), vulnerable (1), unknown (2: offline, a lookup failed, or something could not be identified). Unknown stops a release like vulnerable does.

## The Mac's bundled libraries (about 45 dylibs)

They have no package manifest, so each one is identified from the file itself (install name, version, SHA-256) and checked against `macos/release/libmpv-components.json`. A library stops a strict run when it is not in that file, is listed but missing from the bundle, differs from the recorded version or hash.

The exact upstream git revision is **optional**: when recorded it is looked up in OSV by commit; when not, the library is reported as tracked supply-chain debt. The SBOM (CycloneDX) lists every library with version, hash and whatever upstream information is recorded.

**Debt to clear at the next dependency refresh:** pin an upstream tag and artifact checksum in `macos/Scripts/fetch-libmpv.sh` (it currently downloads whatever IINA release is latest, with no pin).

**Provenance check, 2026-10-29:** the IINA release latest on the bundle's file date is v1.5.0 (published 2026-10-03), `https://github.com/iina/iina/releases/download/v1.5.0/IINA.v1.5.0.dmg`, SHA-256 `8fad50479b10e09645053457cec46bd53d054ced2242cfe68f74586735a20dc7`. All 45 library names and reported versions match it, but the files differ byte for byte, so the source is likely, not proven.

**Current state:** names, versions and hashes are recorded for all 45 libraries, so the Mac check passes; the missing upstream revisions are reported as tracked debt.

## Overriding a finding

Only through a signed, expiring risk acceptance:

1. Add an entry to `Scripts/risk-acceptances.json`: `id` (the OSV id, or `mac:<file>.dylib` for a library finding), `owner`, `reason` (at least 20 characters), `accepted_on`, `expires` (at most 90 days later).
2. Sign the file: `ssh-keygen -Y sign -f <key> -n streamsetu-risk Scripts/risk-acceptances.json` (writes `Scripts/risk-acceptances.json.sig`).
3. List the public key in `Scripts/allowed_signers`.

An unsigned file, a signature that does not verify, an incomplete entry, a longer period, or an expired entry is ignored, and the audit says so. Accepted findings are listed in the report.
