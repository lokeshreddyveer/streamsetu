#!/usr/bin/env python3
"""Adds one release to the Sparkle update feed, unless the feed already offers that version.

  appcast_add.py FEED VERSION BUILD URL SIGN_ATTRIBUTES NOTES

Prints "added" or "already offered". Running it again for the same version changes nothing: before, every run added another entry (with a signature made for that run),
so a release that was repeated, or one that only added an Android file to a Mac version already offered, left duplicates in the feed.
"""
import email.utils, html, os, sys

path, version, build, url, sign, notes = sys.argv[1:7]
old = open(path).read() if os.path.exists(path) else ""
if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" in old:
    print("already offered"); sys.exit(0)
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
