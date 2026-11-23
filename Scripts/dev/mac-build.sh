#!/bin/bash
# mac-build.sh - Build the Mac app (universal, libmpv bundled) into macos/dist/StreamSetu.app.
# Usage: Scripts/dev/mac-build.sh [version] [build] [--force] [--dry-run] [--timings]
#   version  default: the last git tag (leading v removed); digits and dots only
#   build    default: the build number of the last identical build, else the date (YYYYMMDDHHMM)
#   --force  build even when sources, keys and version are unchanged since the last build
# Calls macos/Scripts/build-release.sh (REDDY_BUNDLE_MPV=1), then checks Info.plist reports the version and build asked for.
# Incremental: SwiftPM reuses macos/.build; an unchanged tree (content hash) skips the build altogether.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
VERSION=""; BUILD=""; FORCE=0; pos=0
while [ $# -gt 0 ]; do
  common_flag "$1" && { shift; continue; }
  case "$1" in
    --force) FORCE=1;;
    -*) usage_error "unknown option: $1";;
    *) pos=$((pos + 1)); case $pos in 1) VERSION=$1;; 2) BUILD=$1;; *) usage_error "too many arguments";; esac;;
  esac; shift
done
if [ -z "$VERSION" ]; then VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"; VERSION="${VERSION:-1.0.0}"; fi
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || usage_error "version '$VERSION' must look like 2026.11.21 or 1.2.3"
[ -z "$BUILD" ] || [[ "$BUILD" =~ ^[0-9]+$ ]] || usage_error "build '$BUILD' must be digits only"
APP="$ROOT/macos/dist/StreamSetu.app"
need swift "Install Xcode 27.2 and run: sudo xcode-select -s /Applications/Xcode.app"
acquire_lock mac-build
FP="$(fp_paths macos motion legal Scripts/gen-builtin-key.py):$(keys_fp)"
read -r SFP SVER SBUILD <<<"$(stamp_get mac-build)" || true
if [ "$FORCE" = 0 ] && [ "${SFP:-}" = "$FP" ] && [ "${SVER:-}" = "$VERSION" ] && { [ -z "$BUILD" ] || [ "$BUILD" = "${SBUILD:-}" ]; } && [ -d "$APP" ]; then
  ok "up to date: $VERSION (${SBUILD:-?}) built from identical sources; use --force to rebuild"; exit 0
fi
[ -n "$BUILD" ] || { [ "${SFP:-}" = "$FP" ] && [ -n "${SBUILD:-}" ] && BUILD="$SBUILD" || BUILD="$(date +%Y%m%d%H%M)"; }
log "version $VERSION build $BUILD"
run_step "build (universal, bundled mpv)" env REDDY_BUNDLE_MPV=1 "$ROOT/macos/Scripts/build-release.sh" "$VERSION" "$BUILD"
if [ "$DRY_RUN" = 1 ]; then log "  [dry-run] would verify Info.plist version $VERSION build $BUILD"; exit 0; fi
got_v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
got_b="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ "$got_v" = "$VERSION" ] && [ "$got_b" = "$BUILD" ] || die $EX_FAIL "built app reports $got_v ($got_b), expected $VERSION ($BUILD)"
stamp_set mac-build "$FP $VERSION $BUILD"
ok "built $APP  version $got_v ($got_b)"
