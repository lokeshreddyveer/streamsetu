#!/usr/bin/env python3
"""Adds one file of a release to the Sparkle update feed, unless the feed already offers that file.

  appcast_add.py FEED VERSION BUILD URL SIGN_ATTRIBUTES NOTES ARCH

ARCH is `arm64` (the Apple silicon file) or `x86_64` (the Intel file). There is no universal file. The Apple silicon item carries
`<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>` (Sparkle 2.9 and later): an Intel Mac cannot take it, so it is offered the Intel item; an Apple silicon Mac can take
both, and takes the one with the higher build, which is the Apple silicon one (see macos/Scripts/release-signed.sh: Apple silicon is build+1).

Prints "added" or "already offered". Running it again for the same version and file changes nothing: before, every run added another entry (with a signature made for that run).
"""
import email.utils, html, os, re, sys

path, version, build, url, sign, notes, arch = sys.argv[1:8]
if arch not in ("arm64", "x86_64"):
    sys.exit(f"✘ architecture {arch!r} is not arm64 or x86_64")
old = open(path).read() if os.path.exists(path) else ""
items = re.findall(r"(?s)    <item>.*?</item>\n", old)

def is_arm(item): return "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>" in item
def of_version(item): return f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" in item

if any(of_version(i) and is_arm(i) == (arch == "arm64") for i in items):
    print("already offered"); sys.exit(0)
# Sparkle picks the entry with the highest build number, so a new entry must be higher than every build of an OLDER version already offered
# (the other file of this same version may be offered already, at the other build).
# A build of 2151 next to 314 once made every 2.16.0 install offer, and fail to install, an older 2.15.1.
if not build.isdigit():
    sys.exit(f"✘ build {build!r} is not a whole number")
older = [int(b) for i in items if not of_version(i) for b in re.findall(r"<sparkle:version>(\d+)</sparkle:version>", i)]
if older and int(build) <= max(older):
    sys.exit(f"✘ build {build} is not higher than {max(older)}, the highest build the feed already offers for an older version")
requirement = "      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>\n" if arch == "arm64" else ""
label = "Apple silicon" if arch == "arm64" else "Intel"
item = f"""    <item>
      <title>StreamSetu {version} ({label})</title>
      <pubDate>{email.utils.formatdate(localtime=False)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
{requirement}      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{html.escape(notes)}]]></description>
      <enclosure url="{url}" type="application/octet-stream" {sign}/>
    </item>
"""
head = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>StreamSetu</title>
"""
open(path, "w").write(head + item + "".join(items) + "  </channel>\n</rss>\n")
print("added")
