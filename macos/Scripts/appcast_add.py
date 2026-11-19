#!/usr/bin/env python3
"""Adds one release to the Sparkle update feed, unless the feed already offers that version.

  appcast_add.py FEED VERSION BUILD URL SIGN_ATTRIBUTES NOTES

Prints "added" or "already offered". Running it again for the same version changes nothing: before, every run added another entry (with a signature made for that run),
so a release that was repeated, or one that only added an Android file to a Mac version already offered, left duplicates in the feed.
"""
import email.utils, html, os, re, sys

path, version, build, url, sign, notes = sys.argv[1:7]
old = open(path).read() if os.path.exists(path) else ""
if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" in old:
    print("already offered"); sys.exit(0)
# Sparkle picks the entry with the highest build number, so a new entry must be higher than every build already offered.
# A build of 2151 next to 314 once made every 2.16.0 install offer, and fail to install, an older 2.15.1.
if not build.isdigit():
    sys.exit(f"✘ build {build!r} is not a whole number")
builds = [int(b) for b in re.findall(r"<sparkle:version>(\d+)</sparkle:version>", old)]
if builds and int(build) <= max(builds):
    sys.exit(f"✘ build {build} is not higher than {max(builds)}, the highest build the feed already offers")
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
items = old[old.index("<item>") - 4: old.rindex("</channel>")] if "<item>" in old else ""
open(path, "w").write(head + item + items + "  </channel>\n</rss>\n")
print("added")
