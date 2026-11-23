#!/usr/bin/env python3
"""Source hygiene scans (mirror of the Swift/Kotlin scan tests).
  A. Provider names (TMDB, The Movie Database, fanart.tv, TheTVDB, TVmaze) inside STRING LITERALS of user-interface files appear only in the allowed
     places: Settings, About, credits/attribution, legal and privacy text, the artwork/metadata source pages and the assistant knowledge (Atlas).
     No exception: no provider name appears on a content screen.
  A2. No provider name in prose of any markdown file (README, docs, release notes, web content) except legal/** (privacy policy and credits) and the generated
     docs/assistant-coverage.md. Inline code spans and fenced code blocks (identifiers, file names, commands) are not prose.
  B. No key, token, secret, password or Authorization value is passed to a logging call (print, NSLog, os_log, Logger, Log.x, println, console.x ...).
Test, generated and benchmark files are not scanned. Run alone or through run_all.py."""
import re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import common

NAME = "provider-names-logging"
SRC_RX = r"^(macos/Sources|ios/(StreamSetu|Shared|StreamSetuWidgets)|android/[^/]+/src/main/kotlin|windows/(native|core|src|src-tauri))/.*\.(swift|kt|cs|ts|tsx|rs)$"
UI_RX = re.compile(r"(/Features/|/DesignSystem/|ios/StreamSetu/(Screens|Settings|Components|Views)|ios/Shared/.*(View|Screen)|/ui/|windows/src/)")
EXCLUDE_RX = re.compile(r"/(Tests?|test|androidTest|UITests|node_modules|dist|Generated|bin|obj)/|Tests?/|Benchmark")
MD_RX = r"^(?!legal/|web/content/legal/|docs/assistant-coverage\.md$)(?!.*(node_modules|/\.build/|/build/)).*\.md$"
MD_NAMES = re.compile(r"\b(TMDB|TheMovieDB|The Movie Database|fanart(\.tv)?|TheTVDB|TVDB|TVmaze|iptv-org|OpenSubtitles|Trakt|Real-Debrid|AllDebrid|Premiumize|Control D|Starlite|Wikipedia|Wikimedia)\b", re.I)
FENCE = re.compile(r"^\s*(```|~~~)")
INPUTS = [SRC_RX, MD_RX]
# files (path regex) where a provider name may appear in user-visible text
ALLOWED = re.compile(r"(?i)(settings|about|credit|attribution|legal|privacy|/atlas/|artwork(settings|matching)|hubsources|hubsettings|serviceCredits|whatsnew|onboarding)")
NAMES = re.compile(r"TMDB|The Movie Database|fanart\.tv|TheTVDB|TVmaze", re.I)
# the TMDB notice text its terms require is a credit wherever it is shown
CREDIT_TEXT = re.compile(r"not endorsed or certified", re.I)
# source-level findings handed to their owners; reported as warnings until fixed (then remove the entry: a stale entry warns too)
KNOWN_SOURCE_FINDINGS = {}
STRING = re.compile(r'"(?:[^"\\\n]|\\.)*"')
LOG_CALL = re.compile(r"\b(print|debugPrint|NSLog|os_log|dump|println|eprintln|Timber\.\w+|[Ll]og(?:ger)?\.\w+|logger\.\w+|Log\.[a-z]|console\.(?:log|warn|error|debug|info)|tracing::\w+!|log::\w+!|println!|eprintln!|Console\.Write(?:Line)?|Debug\.Write(?:Line)?|Trace\.Write(?:Line)?)\s*\(")
SENSITIVE = re.compile(r"(?i)\b(api[_-]?key|apikey|access[_-]?token|auth[_-]?token|bearer|token|secret|password|passwd|authorization|credential\w*)\b")
SAFE = re.compile(r"(?i)redact|mask|isEmpty|isNullOrEmpty|\.count\b|\.length\b|\.size\b|isSet|hasToken|hasKey|present|configured|<redacted>|\*\*\*|isBlank|!= nil|== nil|isNotEmpty|\?\s*\"|Boolean|tokenCount|tokens\b|\.isPresent")


def code_view(call):
    """the call text with string-literal text removed except interpolated parts: Swift \\(..), Kotlin ${..} / $name, C# {..}"""
    out, i, n, instr = [], 0, len(call), False
    while i < n:
        c = call[i]
        if not instr:
            if c == '"': instr = True
            else: out.append(c)
        else:
            if c == "\\" and i + 1 < n and call[i + 1] == "(":
                depth, j = 1, i + 2
                while j < n and depth:
                    depth += (call[j] == "(") - (call[j] == ")"); j += 1
                out.append(" " + call[i + 2:j - 1] + " "); i = j; continue
            if c == "\\": i += 2; continue
            if c == "$" and i + 1 < n and call[i + 1] == "{":
                j = call.find("}", i); j = n if j < 0 else j
                out.append(" " + call[i + 2:j] + " "); i = j + 1; continue
            if c == "$" and i + 1 < n and (call[i + 1].isalpha() or call[i + 1] == "_"):
                j = i + 1
                while j < n and (call[j].isalnum() or call[j] == "_"): j += 1
                out.append(" " + call[i + 1:j] + " "); i = j; continue
            if c == '"': instr = False
        i += 1
    return "".join(out)


def call_text(lines, i, start):
    text, depth, k = "", 0, i
    seg = lines[i][start:]
    while True:
        for ch in seg:
            depth += (ch == "(") - (ch == ")")
        text += seg + "\n"
        if depth <= 0 or k - i >= 3 or k + 1 >= len(lines): return text
        k += 1; seg = lines[k]


def run(ctx):
    R = common.Result(); err = R.err
    files = [f for f in ctx.select([SRC_RX]) if not EXCLUDE_RX.search(f)]
    mds = 0
    for f in ctx.select([MD_RX]):
        mds += 1; fence = False
        for ln, line in enumerate(ctx.read(f).split("\n"), 1):
            if FENCE.match(line): fence = not fence; continue
            if fence: continue   # code blocks hold identifiers and commands, not prose
            prose = "".join(p for i, p in enumerate(line.split("`")) if i % 2 == 0)
            m = MD_NAMES.search(prose)
            if m: err("%s:%d provider name %s in a markdown file (credits live in legal/ and Settings only)" % (f, ln, m.group(0))); break
    hits = logs = 0; seen_known = set()
    for f in files:
        t = ctx.read(f)
        if NAMES.search(t) and UI_RX.search(f) and not ALLOWED.search(f):
            for ln, line in enumerate(t.split("\n"), 1):
                if line.lstrip().startswith(("//", "*", "/*")): continue
                for s in STRING.findall(line):
                    m = NAMES.search(s)
                    if not m or " " not in s or CREDIT_TEXT.search(s): continue   # identifiers ("trendingTMDB") are not display text
                    known = next((v for (kf, kt), v in KNOWN_SOURCE_FINDINGS.items() if kf == f and kt in s), None)
                    if known: seen_known.add(f); R.warn("%s:%d %s (owner to fix)" % (f, ln, known)); break
                    hits += 1; err("%s:%d provider name %s in a user-interface string outside Settings/About/credits" % (f, ln, m.group(0))); break
        if not LOG_CALL.search(t) or not SENSITIVE.search(t): continue
        lines = t.split("\n")
        for i, line in enumerate(lines):
            m = LOG_CALL.search(line)
            if not m or line.lstrip().startswith(("//", "*", "/*")): continue
            view = code_view(call_text(lines, i, m.start()))
            s = SENSITIVE.search(view)
            if s and not SAFE.search(view):
                logs += 1; err("%s:%d sensitive value (%s) near a logging call" % (f, i + 1, s.group(0).lower()))
    for (kf, kt), v in KNOWN_SOURCE_FINDINGS.items():
        if kf not in seen_known and kf in ctx.fileset: R.warn("stale KNOWN_SOURCE_FINDINGS entry (fixed?): %s" % kf)
    R.note = "%d files scanned, %d markdown files" % (len(files), mds)
    return R


if __name__ == "__main__":
    common.main(sys.modules[__name__])
