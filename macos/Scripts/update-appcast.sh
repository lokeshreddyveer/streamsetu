#!/bin/bash
# Adds a release to the update feed (appcast.xml at the root of the StreamSetu repo) so installed copies of the Mac app offer it.
# The DMG is signed with the update key kept in this Mac's Keychain (account "streamsetu"; made by Sparkle's generate_keys).
#
#   Scripts/update-appcast.sh <version> <build> [notes]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: update-appcast.sh <version> <build> [notes]}"; BUILD="${2:?usage: update-appcast.sh <version> <build> [notes]}"; NOTES="${3:-StreamSetu $VERSION}"
REPO="${RELEASES_REPO:-lokeshreddyveer/streamsetu}"
DMG="dist/StreamSetu-$VERSION.dmg"
[ -f "$DMG" ] || { echo "✘ $DMG not found"; exit 1; }
SIGN="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account streamsetu "$DMG")"     # sparkle:edSignature="…" length="…"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
gh repo clone "$REPO" "$WORK/repo" -- --depth 1 --filter=blob:none >/dev/null 2>&1
URL="https://github.com/$REPO/releases/download/mac-v$VERSION/StreamSetu-$VERSION.dmg"
python3 - "$WORK/repo/appcast.xml" "$VERSION" "$BUILD" "$URL" "$SIGN" "$NOTES" <<'PY'
import sys, os, email.utils, html
path, version, build, url, sign, notes = sys.argv[1:7]
item = f"""    <item>
      <title>StreamSetu {version}</title>
      <pubDate>{email.utils.formatdate(localtime=False)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{html.escape(notes)}]]></description>
      <enclosure url="{url}" type="application/octet-stream" {sign}/>
    </item>
"""
head = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>StreamSetu</title>
"""
items = ""
if os.path.exists(path):
    old = open(path).read()
    items = old[old.index("<item>")-4: old.rindex("</channel>")] if "<item>" in old else ""
open(path, "w").write(head + item + items + "  </channel>\n</rss>\n")
PY
cd "$WORK/repo" && git add appcast.xml && git commit -qm "Update feed for StreamSetu $VERSION" && git push -q origin HEAD
echo "✔ update feed now offers $VERSION"
