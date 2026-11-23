#!/usr/bin/env python3
"""Network contract (extends the old iOS-vs-Android host parity check). Standard library only; prints no secrets.
  1. iOS and macOS ATS exception lists are equal; Android network_security_config.xml covers every ATS host
     (github.com, githubusercontent.com, supabase.co and the App DNS hosts are Apple-only by design) and nothing else extra;
  2. every https host named in the Apple, Android and Windows app sources (tests excluded) is on those lists, or is a link that is only opened
     in a browser / a placeholder (DOC_LINKS below);
  3. no http:// literal in app sources (XML namespaces, loopback and example hosts excepted);
  4. each service on the lists is named in the privacy policy (legal/privacy.md); the data services also in credits (legal/licenses.md);
  5. both privacy manifests (iOS, macOS) parse, declare no tracking and no tracking domains, and give a reason for every required-reason API.
Run alone, or through Scripts/checks/run_all.py (same logic)."""
import plistlib, re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent / "checks"))
import common

NAME = "network-contract"
IOS_PLIST, MAC_PLIST = "ios/StreamSetu/Info.plist", "macos/Configuration/Info.plist"
NSC = "android/app/src/main/res/xml/network_security_config.xml"
MANIFESTS = ["ios/StreamSetu/PrivacyInfo.xcprivacy", "macos/Configuration/PrivacyInfo.xcprivacy"]
SRC_RX = r"^(macos/Sources|macos/Tools|ios/(StreamSetu|Shared|StreamSetuWidgets)|android/[^/]+/src/main|windows/(native|core|src|src-tauri))/.*\.(swift|kt|java|cs|ts|tsx|rs|xml|plist)$"
EXCLUDE_RX = re.compile(r"/(Tests?|test|androidTest|UITests|node_modules|dist|bin|obj|Generated)/|Tests?/|\.Tests/|/res/(raw|values)/|strings\.xml$")
INPUTS = [SRC_RX, "^" + re.escape(IOS_PLIST) + "$", "^" + re.escape(MAC_PLIST) + "$", "^" + re.escape(NSC) + "$", r"^legal/(privacy|licenses)\.md$",
          r"^ios/StreamSetu/PrivacyInfo\.xcprivacy$", r"^macos/Configuration/PrivacyInfo\.xcprivacy$"]

APPLE_ONLY = {"primevideo.com", "disneyplus.com", "hulu.com", "hbomax.com", "peacocktv.com", "paramountplus.com", "tv.apple.com", "crunchyroll.com", "jiohotstar.com", "hotstar.com",  # embedded streaming services (Mac only)
              "sponsor.ajay.app", "github.com", "githubusercontent.com", "supabase.co", "cloudflare-dns.com", "controld.com", "dns.adguard-dns.com", "dns.google", "dns.quad9.net"}
# links that are only opened in a browser or are documentation / namespace / placeholder hosts: never fetched by the app
DOC_LINKS = {"www.wikidata.org", "www.netflix.com", "netflix.com", "apps.apple.com", "testflight.apple.com", "www.apple.com", "ffmpeg.org", "mpv.io", "sparkle-project.org", "creativecommons.org",
             "ai.google.dev", "duckduckgo.com", "streamsetu.example", "www.w3.org", "apache.org", "schemas.android.com", "tauri.localhost", "localhost",
             "1.1.1.1", "8.8.8.8", "9.9.9.9"}  # bootstrap addresses of the DNS-over-HTTPS resolvers (App DNS), named by IP on purpose
HTTP_OK = re.compile(r"(^|\.)(w3\.org|apache\.org|schemas\.android\.com|apple\.com|localhost|example|example\.com|local|test|invalid)$|^(127\.|10\.|192\.168\.|169\.254\.|0\.0\.0\.0)|^tauri\.localhost$")
PLACEHOLDER = re.compile(r"(^|\.)(example|example\.com|example\.test|local|test|invalid)$")
# registrable service domain -> name the privacy text must use (case-insensitive)
SERVICE_NAMES = {"primevideo.com": "Prime Video", "disneyplus.com": "Disney+", "hulu.com": "Hulu", "hbomax.com": "HBO Max", "peacocktv.com": "Peacock",
                 "paramountplus.com": "Paramount+", "tv.apple.com": "Apple TV", "crunchyroll.com": "Crunchyroll", "jiohotstar.com": "JioHotstar", "hotstar.com": "JioHotstar", "themoviedb.org": "TMDB", "tmdb.org": "TMDB", "fanart.tv": "fanart.tv", "thetvdb.com": "TheTVDB", "tvmaze.com": "TVmaze",
                 "opensubtitles.com": "OpenSubtitles", "trakt.tv": "Trakt", "wikipedia.org": "Wikipedia", "wikimedia.org": "Wikipedia",
                 "itunes.apple.com": "iTunes", "youtube.com": "YouTube", "sponsor.ajay.app": "SponsorBlock", "googleapis.com": "Google", "groq.com": "Groq", "openai.com": "OpenAI",
                 "anthropic.com": "Anthropic", "openrouter.ai": "OpenRouter", "nvidia.com": "NVIDIA", "ollama.com": "Ollama",
                 "real-debrid.com": "Real-Debrid", "alldebrid.com": "AllDebrid", "premiumize.me": "Premiumize", "github.com": "GitHub",
                 "githubusercontent.com": "GitHub", "supabase.co": "Supabase", "cloudflare-dns.com": "Cloudflare", "controld.com": "Control D",
                 "dns.adguard-dns.com": "AdGuard", "dns.google": "Google", "dns.quad9.net": "Quad9", "iptv-org.github.io": "iptv-org"}
# data services that must also be credited in legal/licenses.md
CREDITED = {"SponsorBlock": "CC BY-NC-SA 4.0", "TMDB": "not endorsed or certified", "fanart.tv": "fanart.tv", "TheTVDB": "TheTVDB", "TVmaze": "CC BY-SA"}


def covers(domains, host): return any(host == d or host.endswith("." + d) for d in domains)


def ats_hosts(text):
    try: doc = plistlib.loads(text.encode("utf-8"))
    except Exception: return None
    return set(doc.get("NSAppTransportSecurity", {}).get("NSExceptionDomains", {}))


def run(ctx):
    R = common.Result(); err = R.err
    ios, mac = ats_hosts(ctx.read(IOS_PLIST)), ats_hosts(ctx.read(MAC_PLIST))
    if ios is None or mac is None: err("iOS/macOS Info.plist: cannot parse"); return R
    droid = set(re.findall(r">\s*([a-z0-9.-]+\.[a-z]+)\s*</domain>", ctx.read(NSC)))
    if not droid: err("%s: no https-only domains found" % NSC); return R
    if ios != mac: err("ATS lists differ: iOS only %s, macOS only %s" % (sorted(ios - mac), sorted(mac - ios)))
    ats = ios | mac
    for h in sorted(h for h in ats - APPLE_ONLY if not covers(droid, h)): err("host in the ATS lists but not in network_security_config.xml: %s" % h)
    for h in sorted(h for h in droid if not covers(ats, h)): err("host in network_security_config.xml but not in the ATS lists: %s" % h)
    listed = ats | droid
    # 2 + 3: source scan
    https, http = {}, {}
    for f in ctx.select([SRC_RX]):
        if EXCLUDE_RX.search(f): continue
        t = ctx.read(f)
        if "://" not in t: continue
        for m in re.finditer(r"\b(https?)://([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}|localhost|\d{1,3}(?:\.\d{1,3}){3})", t):
            (https if m.group(1) == "https" else http).setdefault(m.group(2).lower(), set()).add(f)
    for h, fs in sorted(https.items()):
        if PLACEHOLDER.search(h) or h in DOC_LINKS or covers(listed, h): continue
        err("https host %s (%s) is not on the ATS / network_security_config lists; add it there or to DOC_LINKS if it is only a link" % (h, sorted(fs)[0]))
    for h, fs in sorted(http.items()):
        if HTTP_OK.search(h): continue
        err("http:// literal for %s in %s" % (h, sorted(fs)[0]))
    # 4: privacy text and credits
    priv, lic = ctx.read("legal/privacy.md").lower(), ctx.read("legal/licenses.md").lower()
    if not priv: err("legal/privacy.md missing")
    seen = set()
    for h in sorted(listed):
        key = next((k for k in SERVICE_NAMES if h == k or h.endswith("." + k)), None)
        if key is None: err("host %s has no entry in SERVICE_NAMES (Scripts/check-host-parity.py): name the service the privacy text must mention" % h); continue
        name = SERVICE_NAMES[key]
        if name in seen: continue
        seen.add(name)
        if name.lower() not in priv:
            err("legal/privacy.md does not name %s (%s)" % (name, h))
    for name, phrase in CREDITED.items():
        if phrase.lower() not in lic and name.lower() not in lic: err("legal/licenses.md: no credit for %s" % name)
    # 5: privacy manifests
    for m in MANIFESTS:
        try: d = plistlib.loads(ctx.read(m).encode("utf-8"))
        except Exception: err("%s: cannot parse" % m); continue
        if d.get("NSPrivacyTracking") is not False: err("%s: NSPrivacyTracking must be false" % m)
        if d.get("NSPrivacyTrackingDomains"): err("%s: tracking domains must be empty" % m)
        for c in d.get("NSPrivacyCollectedDataTypes", []):
            if c.get("NSPrivacyCollectedDataTypeTracking") is not False: err("%s: collected data type %s is marked as tracking" % (m, c.get("NSPrivacyCollectedDataType")))
        for a in d.get("NSPrivacyAccessedAPITypes", []):
            if not a.get("NSPrivacyAccessedAPITypeReasons"): err("%s: required-reason API %s has no reason" % (m, a.get("NSPrivacyAccessedAPIType")))
    R.note = "%d lists hosts, %d https hosts in sources, %d http literals checked" % (len(listed), len(https), len(http))
    return R


if __name__ == "__main__":
    common.main(sys.modules[__name__])
