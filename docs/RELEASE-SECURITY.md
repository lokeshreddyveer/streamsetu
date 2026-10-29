# Release security gate

Every release script runs `Scripts/audit-dependencies.py --strict` and stops on anything but a clean result. There is no environment variable or flag that skips it.

| Product | Script | Scope | Kept with the release |
|---|---|---|---|
| iPhone / iPad | `ios/Scripts/testflight.sh` | Swift packages, website | `…/StreamSetuRenew/testflight/reports/dependencies-<build>.json` |
| Mac | `macos/Scripts/release-signed.sh`, `release-dmg.sh` | Swift packages, website, **bundled media libraries** | `macos/dist/security/dependencies-<version>.json` and `sbom-<version>.cdx.json` |
| Android | `android/release.sh` | Swift-free: Gradle dependencies are checked by lint | n/a |

Three outcomes are kept apart: clean (exit 0), vulnerable (1), unknown (2: offline, a lookup failed, or something could not be identified). Unknown stops a release like vulnerable does.

## The Mac's bundled libraries (about 45 dylibs)

They have no package manifest, so each one is identified from the file itself (install name, version, SHA-256) and checked against `macos/release/libmpv-components.json`, which records its upstream project, the **exact upstream git revision** it was built from, and the date its security advisories were last read. A library stops a strict run when:

- it is not in that file, or the file or version differs from what was reviewed;
- no exact upstream revision is recorded (it cannot be looked up);
- its advisories were not reviewed in the last 30 days.

A recorded revision is looked up in OSV by commit. The SBOM (CycloneDX) lists every library with version, hash, upstream project and revision.

**Current state:** the revisions and review dates are not yet recorded, so the Mac release gate fails until someone reads them from the build the dylibs came from (see `macos/Scripts/fetch-libmpv.sh`) and fills them in. They must not be guessed.

## Overriding a finding

Only through a signed, expiring risk acceptance:

1. Add an entry to `Scripts/risk-acceptances.json`: `id` (the OSV id, or `mac:<file>.dylib` for a library finding), `owner`, `reason` (at least 20 characters), `accepted_on`, `expires` (at most 90 days later).
2. Sign the file: `ssh-keygen -Y sign -f <key> -n streamsetu-risk Scripts/risk-acceptances.json` (writes `Scripts/risk-acceptances.json.sig`).
3. List the public key in `Scripts/allowed_signers`.

An unsigned file, a signature that does not verify, an incomplete entry, a longer period, or an expired entry is ignored, and the audit says so. Accepted findings are listed in the report.
