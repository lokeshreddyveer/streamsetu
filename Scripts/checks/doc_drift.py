#!/usr/bin/env python3
"""Doc/code drift.
  versions   README download table = appcast (Mac) = android/dist (when present) = iOS generate-project.py VERSION = Xcode MARKETING_VERSION
             = Windows .csproj; one release tag for every file; the notes file for the iOS build and the release tag exist.
  test APK   docs/RELEASING.md: 'last release is X, code N' equals the current Android release; the test build is the next minor with -test and code N+1
             and its command line repeats the same name and code.
  schema     Apple: highest SchemaVNN = last Migration(version:) = highest vNN in macos/Docs/DATABASE.md;
             Android: Room version = highest android/core-database/schemas/**/N.json; docs/METADATA-HUB.md no longer calls a built version 'reserved'.
  coverage   docs/assistant-coverage.md totals add up to its tables; and it was regenerated after the atlas last changed (hash stamp: the generator is a
             slow Swift test, so the stamp stores the atlas input hash seen with the document hash; a changed atlas with an unchanged document fails).
  release docs  every file a release doc names exists."""
import hashlib, re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import common

NAME = "doc-code-drift"
ATLAS_RX = r"^macos/Sources/REDDY/(Atlas/|Services/AssistantCoverage\.swift|Services/AssistantKnowledge\.swift)"
RELEASE_DOCS = ["docs/RELEASING.md", "docs/RELEASE-SECURITY.md", "macos/Docs/RELEASE.md"]
INPUTS = [r"^README\.md$", r"^appcast\.xml$", r"^ios/Scripts/generate-project\.py$", r"^ios/StreamSetu\.xcodeproj/project\.pbxproj$",
          r"^windows/native/[^/]+/[^/]+\.csproj$", r"^docs/(RELEASING|RELEASE-SECURITY|METADATA-HUB|assistant-coverage)\.md$", r"^docs/releases/",
          r"^macos/Docs/(RELEASE|DATABASE)\.md$", r"^macos/Sources/REDDY/Data/Database/", r"^android/core-database/(schemas|src/main)/", ATLAS_RX,
          r"^android/dist/", r"^Scripts/", r"^android/[^/]+\.(sh|txt|properties)$", r"^android/(scripts|tools)/", r"^macos/(Scripts|Tools|Distribution)/", r"^ios/Scripts/"]
STAMP_KEY = "assistant-coverage"
# files a release doc tells the person to create (they exist only while an override or a signing step is in use)
ON_DEMAND = {"Scripts/risk-acceptances.json", "Scripts/risk-acceptances.json.sig", "Scripts/allowed_signers"}


def ver(t): return tuple(int(x) for x in t.split("."))


def run(ctx, state=None):
    R = common.Result(); err = R.err
    readme = ctx.read("README.md")
    row = lambda label: next((l for l in readme.split("\n") if l.startswith("| **%s**" % label)), "")
    tags = set()
    def artifact(label, rx):
        m = re.search(rx, row(label))
        if not m: err("README.md: download row for %s does not name its file" % label); return None
        tags.add(m.group(1)); return m.group(2)
    mac = artifact("Mac", r"releases/download/([\d.]+)/StreamSetu-([\d.]+)\.dmg")
    tv = artifact("Fire TV and Android TV", r"releases/download/([\d.]+)/streamsetu-tv-([\d.]+)\.apk")
    phone = artifact("Android phone and tablet", r"releases/download/([\d.]+)/StreamSetu-Android-([\d.]+)\.apk")
    win = artifact("Windows", r"releases/download/([\d.]+)/StreamSetu-Windows-([\d.]+)\.zip")
    m = re.search(r"version ([\d.]+) \(build (\d+)\)", row("iPhone and iPad")); ios_v, ios_b = (m.group(1), m.group(2)) if m else (None, None)
    if not m: err("README.md: iPhone row has no 'version X (build N)'")
    if len(tags) > 1: err("README.md: download rows come from different release tags: %s" % sorted(tags))
    if tv and phone and tv != phone: err("README.md: TV apk %s and phone apk %s differ" % (tv, phone))
    tag = next(iter(tags), None)
    if tag and not ctx.exists("docs/releases/%s.md" % tag): err("README.md: release tag %s has no docs/releases/%s.md" % (tag, tag))
    # Mac vs appcast
    top = re.search(r"<item>.*?<sparkle:shortVersionString>([\d.]+)</sparkle:shortVersionString>", ctx.read("appcast.xml"), re.S)
    if mac and top and top.group(1) != mac: err("appcast.xml newest item is %s but README says Mac %s" % (top.group(1), mac))
    # Android vs dist
    dist = sorted({f.split("/")[2] for f in ctx.files if re.match(r"android/dist/\d", f)}, key=ver)
    if not dist:  # dist is git-ignored: look at the disk when present
        d = ctx.root / "android/dist"
        dist = sorted((x.name for x in d.iterdir() if re.fullmatch(r"\d+\.\d+\.\d+", x.name)), key=ver) if d.is_dir() else []
    if dist and phone and dist[-1] != phone: err("android/dist newest is %s but README says Android %s" % (dist[-1], phone))
    # iOS
    gp = re.search(r'(?m)^VERSION = "([\d.]+)"', ctx.read("ios/Scripts/generate-project.py"))
    mv = set(re.findall(r"MARKETING_VERSION = ([\d.]+);", ctx.read("ios/StreamSetu.xcodeproj/project.pbxproj")))
    if gp and ios_v and gp.group(1) != ios_v: err("ios/Scripts/generate-project.py VERSION %s but README says iPhone %s" % (gp.group(1), ios_v))
    if mv and ios_v and mv != {ios_v}: err("Xcode MARKETING_VERSION %s but README says iPhone %s" % (sorted(mv), ios_v))
    if ios_v and ios_b and not ctx.exists("docs/releases/ios-%s-build-%s.md" % (ios_v, ios_b)):
        err("README.md: iPhone %s build %s has no docs/releases/ios-%s-build-%s.md" % (ios_v, ios_b, ios_v, ios_b))
    # Windows
    cs = re.search(r"<Version>([\d.]+)</Version>", ctx.read("windows/native/StreamSetu.App/StreamSetu.App.csproj"))
    if cs and win and cs.group(1) != win: err("StreamSetu.App.csproj Version %s but README says Windows %s" % (cs.group(1), win))
    for f in ("windows/package.json", "windows/src-tauri/tauri.conf.json"):
        m = re.search(r'"version":\s*"([\d.]+)"', ctx.read(f))
        if m and win and m.group(1) != win: R.warn("%s version %s differs from the native Windows app %s (old web shell?)" % (f, m.group(1), win))
    # test APK vs RELEASING.md
    rel = ctx.read("docs/RELEASING.md")
    m = re.search(r"for example `([\d.]+)-test` with code `(\d+)` \(the last release is ([\d.]+), code (\d+)\)", rel)
    if not m: err("docs/RELEASING.md: test-build sentence not found (expected 'for example `X-test` with code `N` (the last release is V, code C)')")
    else:
        tname, tcode, last, lcode = m.group(1), int(m.group(2)), m.group(3), int(m.group(4))
        if phone and last != phone: err("docs/RELEASING.md says the last release is %s but README says Android %s" % (last, phone))
        a, b, c = ver(last)
        if ver(tname) != (a, b + 1, 0): err("docs/RELEASING.md: test version %s should be the next minor after %s (%d.%d.0)" % (tname, last, a, b + 1))
        if tcode != lcode + 1: err("docs/RELEASING.md: test code %d should be last code %d + 1" % (tcode, lcode))
        if lcode != a * 10000 + b * 10 + c and lcode != b * 10 + c: R.warn("docs/RELEASING.md: last code %d does not follow the minor*10 pattern for %s" % (lcode, last))
        cmd = re.search(r"-PappVersionName=(\S+) -PappVersionCode=(\d+)", rel)
        if not cmd or cmd.group(1) != tname + "-test" or int(cmd.group(2)) != tcode: err("docs/RELEASING.md: the example gradle command does not repeat %s-test / %d" % (tname, tcode))
    # schema versions
    sch = [int(x) for f in ctx.files for x in re.findall(r"^macos/Sources/REDDY/Data/Database/Schema/SchemaV(\d+)\.swift$", f)]
    sch += [int(x) for f in ctx.select([r"^macos/Sources/REDDY/Data/Database/Schema/"]) for x in re.findall(r"enum SchemaV(\d+)\b", ctx.read(f))]
    mig = [int(x) for x in re.findall(r"Migration\(version:\s*(\d+)", ctx.read("macos/Sources/REDDY/Data/Database/DatabaseMigrator.swift"))]
    dbdoc = [int(x) for x in re.findall(r"(?m)^- \*\*v(\d+)\*\*", ctx.read("macos/Docs/DATABASE.md"))]
    if not (sch and mig and dbdoc): err("Apple schema versions: could not read SchemaVNN / Migration / DATABASE.md")
    elif not max(sch) == max(mig) == max(dbdoc): err("Apple schema: highest SchemaV%d, last migration %d, DATABASE.md highest v%d" % (max(sch), max(mig), max(dbdoc)))
    room = re.search(r"version\s*=\s*(\d+)", ctx.read("android/core-database/src/main/kotlin/app/streamsetu/core/data/db/AppDatabase.kt"))
    schemas = [int(x) for f in ctx.files for x in re.findall(r"^android/core-database/schemas/.*/(\d+)\.json$", f)]
    if not room or not schemas: err("Android Room version / schemas folder not readable")
    else:
        if int(room.group(1)) != max(schemas): err("Android Room version %s but newest exported schema is %d.json" % (room.group(1), max(schemas)))
        for n in re.findall(r"[Vv]ersion (\d+)[^.\n]*reserved", ctx.read("docs/METADATA-HUB.md")):
            if int(n) <= int(room.group(1)): err("docs/METADATA-HUB.md calls Android database version %s 'reserved' but Room is already at %s" % (n, room.group(1)))
    # coverage doc
    cov = ctx.read("docs/assistant-coverage.md")
    tot = {m.group(1).strip(): int(m.group(2)) for m in re.finditer(r"(?m)^\| ([^|]+?) \| (\d+) \|", cov.split("\n## Screens")[0])}
    sections = dict((s.split("\n")[0].strip(), s) for s in re.split(r"\n## ", cov)[2:])
    tsum = 0
    for kind, n in tot.items():
        tsum += n
        sec = sections.get(kind)
        if sec is None: continue
        first = sec.split("\n\n")
        table = next((b for b in first if b.startswith("|")), "")
        rows = [l for l in table.split("\n") if l.startswith("| ") and not l.startswith("| Id") and not re.match(r"\|[-| ]+\|$", l)]
        if len(rows) != n: err("docs/assistant-coverage.md: totals say %d %s but the table lists %d" % (n, kind, len(rows)))
    allm = re.search(r"\| \*\*All\*\* \| \*\*(\d+)\*\*", cov)
    if not allm or int(allm.group(1)) != tsum: err("docs/assistant-coverage.md: 'All' total %s is not the sum of its rows (%d)" % (allm and allm.group(1), tsum))
    h = hashlib.sha1()
    for f in ctx.select([ATLAS_RX]): h.update(f.encode()); h.update(ctx.digest(f).encode())
    atlas_h, doc_h = h.hexdigest(), ctx.digest("docs/assistant-coverage.md")
    if state is not None:
        old = state.get(STAMP_KEY)
        if old and old["atlas"] != atlas_h and old["doc"] == doc_h:
            err("docs/assistant-coverage.md was not regenerated after the atlas changed (ATLAS_DOCS_WRITE=1 swift test --filter AssistantCoverage in macos/)")
        else: state[STAMP_KEY] = {"atlas": atlas_h, "doc": doc_h}
    else: R.warn("coverage staleness not checked standalone (needs the stamp kept by run_all.py)")
    # release docs name only existing files
    names = {Path(f).name for f in ctx.files}
    skip = re.compile(r"[<>*$~{}()\[\]|=\s]|^https?:|^\.\.?/|^/|^-|(^|/)(dist|build|\.build|Generated|keys)(/|$)|\.(app|dmg|apk|zip|pkg|xcarchive|ipa|exe)$|(^|/)(local|keystore|gradle)\.properties$|^StreamSetu")
    for d in RELEASE_DOCS:
        if not ctx.exists(d): err("%s: missing" % d); continue
        base = d.rsplit("/", 1)[0]
        for tok in sorted(set(re.findall(r"`([^`\n]+)`", ctx.read(d)))):
            tok = tok.strip().rstrip(".,:;")
            if tok in ON_DEMAND or skip.search(tok) or not re.search(r"\.(sh|py|md|kts|swift|json|plist|yml|yaml|txt|xml|entitlements|toml|properties|cs)$", tok): continue
            ok = any(ctx.exists(p) for p in (tok, base + "/" + tok, "android/" + tok, "macos/" + tok, "ios/" + tok)) or ("/" not in tok and tok in names)
            if not ok: err("%s names `%s`, which does not exist" % (d, tok))
    R.note = "Mac %s, Android %s, iPhone %s (%s), Windows %s; Apple schema v%s, Room %s" % (mac, phone, ios_v, ios_b, win, max(sch) if sch else "?", room.group(1) if room else "?")
    return R


if __name__ == "__main__":
    common.main(sys.modules[__name__])
