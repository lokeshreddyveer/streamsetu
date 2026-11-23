#!/usr/bin/env python3
"""Per-service manual checklist and compatibility-report template, generated from the registry data.

Reads macos/Sources/REDDY/Services/Streaming/Domain/ProviderCatalog.swift (the only place the services are defined) and writes
  <out>/service-checklist.md        the owner's step-by-step checklist, one section per listed service
  <out>/compatibility-report.md     one fill-in block per service (record, capabilities, ten checks with date/build/note)
  --json PATH (optional)            the data fixture used by ServiceChecklistTests (ids, states and check keys only)

The documents name the services, so they are written OUTSIDE the repository: --out is an argument, the default is a folder in the system
temp directory (override with STREAMSETU_REPORT_DIR), and a path inside the repository is refused. Nothing here signs in, reads a page or
records a result: every outcome starts as notChecked and is filled in by hand. Standard library only.

  python3 Scripts/gen-service-checklist.py [--out DIR] [--json macos/Tests/REDDYTests/Resources/service-checklist.json] [--check]
"""
import argparse, json, os, re, sys, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CATALOG = REPO / "macos/Sources/REDDY/Services/Streaming/Domain/ProviderCatalog.swift"

# The ten checks of CompatibilityResult.Check, in order, then the extra steps this document adds.
BASE_CHECKS = ["siteLoads", "signInPageRenders", "signInCompletes", "catalog", "video", "audio", "fullscreen",
               "sessionPersistsAfterRestart", "switchingStopsAudio", "errorScreenRetryAndReturn"]
EXTRA_ALWAYS = ["returningPreservesState"]
EXTRA_BLOCKED = ["blockedLinkNotice"]          # external links blocked with a native notice, no browser action anywhere
EXTRA_BROWSER = ["defaultBrowserActionUnchanged"]   # services that keep the confirm-then-open browser action

STEPS = {
    "siteLoads": "Open the service from the Services menu. Its home page loads inside StreamSetu, with no browser toolbar.",
    "signInPageRenders": "Open the sign-in page from the service. It renders fully (no blank page, no blocked-content message).",
    "signInCompletes": "Sign in with your own account, typing the credentials yourself. Sign-in completes and returns to the service.",
    "catalog": "After signing in, browse. The catalog (rows, posters, titles) loads and scrolls.",
    "video": "Start a title you may watch. Video plays and the picture is correct (not black, not a protection error).",
    "audio": "Audio is heard and the volume controls work.",
    "fullscreen": "Enter and leave full screen from the service's own control. Window and StreamSetu's bar come back correctly; Escape leaves full screen.",
    "sessionPersistsAfterRestart": "Quit StreamSetu fully and reopen it. Open the service: still signed in.",
    "switchingStopsAudio": "While something plays, switch to another service or to StreamSetu. The audio stops at once and does not resume by itself.",
    "errorScreenRetryAndReturn": "Turn the network off and open the service. A native error screen appears; Retry works after the network is back and Return to StreamSetu goes home.",
    "returningPreservesState": "Go away to another destination and come back. The page is where you left it; playback is not auto-resumed.",
    "blockedLinkNotice": "Click a link that leaves the service. Nothing opens in another app; a native notice says the link was blocked. There is no browser button anywhere for this service.",
    "defaultBrowserActionUnchanged": "The existing Open in Default Browser actions and the off-site link confirmation behave exactly as before.",
}
DISABLED_STEP = "Select the service. A native Integration Unavailable screen names it and offers only Return to StreamSetu; Return works."
PRESENTATION = {"available": "embedded", "unverified": "embedded", "disabled": "integrationUnavailable", "registered": "hidden"}


def balanced(text, start):
    """Text of the parenthesised argument list that opens at text[start] == '('."""
    depth, i, in_str = 0, start, False
    while i < len(text):
        c = text[i]
        if in_str:
            if c == "\\": i += 1
            elif c == '"': in_str = False
        elif c == '"': in_str = True
        elif c == "(": depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0: return text[start + 1:i]
        i += 1
    raise ValueError("unbalanced parentheses in the catalog")


def arg(body, name, default=None):
    m = re.search(r"\b%s:\s*(\"(?:[^\"\\]|\\.)*\"|\.\w+)" % name, body)
    if not m: return default
    v = m.group(1)
    return v[1:-1] if v.startswith('"') else v[1:]


def parse_catalog(text):
    """Services in catalog order with the fields the checklist needs."""
    order = re.search(r"static let all: \[ProviderDefinition\] = \[([^\]]*)\]", text)
    if not order: raise ValueError("catalog order not found")
    names = [n.strip() for n in order.group(1).split(",") if n.strip()]
    out = []
    for n in names:
        m = re.search(r"static let %s = (unverified|ProviderDefinition)\(" % re.escape(n), text)
        if not m: raise ValueError("no definition for " + n)
        body = balanced(text, m.end() - 1)
        if m.group(1) == "unverified":
            d = dict(id=arg(body, "id"), name=arg(body, "name"), availability="unverified", external="blockWithNotice",
                     terms=arg(body, "terms"), auth=arg(body, "auth", "manualVerificationRequired"), mode=arg(body, "mode", "signInInApp"),
                     loading="enabledForTesting", playback="manualVerificationRequired", region=arg(body, "region"))
        else:
            caps = re.findall(r"record\(\.(\w+)", body)
            d = dict(id=arg(body, "id"), name=arg(body, "displayName"), availability=arg(body, "availability"), external=arg(body, "externalLinks"),
                     terms=arg(body, "termsNote"), auth=caps[1] if len(caps) > 1 else "manualVerificationRequired", mode=arg(body, "authentication", "signInInApp"),
                     loading=caps[0] if caps else "enabledForTesting", playback=caps[2] if len(caps) > 2 else "manualVerificationRequired", region=arg(body, "regionNote"))
        d["distribution"] = "unresolved"
        out.append(d)
    return out


def checks_for(s):
    if s["availability"] == "registered": return []
    if s["availability"] == "disabled": return ["errorScreenRetryAndReturn"]
    c = BASE_CHECKS + EXTRA_ALWAYS
    c += EXTRA_BLOCKED if s["external"] == "blockWithNotice" else EXTRA_BROWSER
    return c


def fixture(services):
    rows = []
    for s in services:
        rows.append({"id": s["id"], "availability": s["availability"], "externalLinks": s["external"], "presentation": PRESENTATION[s["availability"]],
                     "checks": checks_for(s), "defaultOutcomes": ({"signInCompletes": "notApplicable"} if s["mode"] == "signedOutOnly" else {})})
    return {"checkKeys": BASE_CHECKS, "services": rows}


def checklist_md(services):
    L = ["# Streaming services: manual checklist", "",
         "Generated from the registry. Do every step yourself on your own Mac with your own account; nothing here is automated. Mark each step passed, failed or not applicable, with the date and the build (Debug or Release).", ""]
    for s in services:
        keys = checks_for(s)
        if not keys: continue
        L += ["## %s (`%s`)" % (s["name"], s["id"]), "", "State: %s. Browser actions: %s." % (s["availability"], "confirm then open (unchanged)" if s["external"] == "confirmThenOpen" else "none, links are blocked with a notice"), ""]
        if s["availability"] == "disabled": L += ["- [ ] %s" % DISABLED_STEP, ""]; continue
        for k in keys:
            note = " (not applicable by design: this service is used signed out)" if k == "signInCompletes" and s["mode"] == "signedOutOnly" else ""
            L.append("- [ ] **%s.** %s%s" % (k, STEPS[k], note))
        L.append("")
    return "\n".join(L)


def report_md(services):
    L = ["# Streaming services: compatibility report", "",
         "One block per service. Capability records come from the registry; outcomes are entered by hand (notChecked, passed, failed, notApplicable). A failed result never changes another service.", ""]
    for s in services:
        L += ["## %s (`%s`)" % (s["name"], s["id"]), "",
              "- availability: %s" % s["availability"], "- distributionAuthorization: %s (a recorded status only; nothing depends on it)" % s["distribution"],
              "- termsNote: %s" % (s["terms"] or "none"), "- externalLinks: %s" % s["external"], "- presentation: %s" % PRESENTATION[s["availability"]],
              "- websiteLoading: %s" % s["loading"], "- authentication: %s (%s)" % (s["auth"], s["mode"]), "- protectedPlayback: %s" % s["playback"], "- distribution: unverified",
              "- build: ", "- checked on: ", ""]
        for k in checks_for(s):
            default = "notApplicable" if (k == "signInCompletes" and s["mode"] == "signedOutOnly") else "notChecked"
            L.append("  - %s: %s | date: | note:" % (k, default))
        L.append("")
    return "\n".join(L)


def default_out():
    return Path(os.environ.get("STREAMSETU_REPORT_DIR") or Path(tempfile.gettempdir()) / "streamsetu-service-checklist")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", type=Path, help="folder for the generated documents (outside the repository)")
    ap.add_argument("--json", type=Path, help="also write the data fixture here")
    ap.add_argument("--check", action="store_true", help="only verify that --json matches the registry; write nothing")
    a = ap.parse_args(argv)
    services = parse_catalog(CATALOG.read_text(encoding="utf-8"))
    fx = json.dumps(fixture(services), indent=2, sort_keys=True) + "\n"
    if a.check:
        if not a.json or not a.json.exists() or a.json.read_text(encoding="utf-8") != fx:
            print("service-checklist fixture is out of date; regenerate with --json"); return 1
        print("fixture matches the registry (%d services)" % len(services)); return 0
    if a.json:
        a.json.write_text(fx, encoding="utf-8"); print("wrote", a.json)
    out = (a.out or default_out()).expanduser().resolve()
    if REPO in (out, *out.parents):
        print("refusing to write the generated documents inside the repository: %s" % out, file=sys.stderr); return 2
    out.mkdir(parents=True, exist_ok=True)
    (out / "service-checklist.md").write_text(checklist_md(services), encoding="utf-8")
    (out / "compatibility-report.md").write_text(report_md(services), encoding="utf-8")
    print("wrote documents to", out); return 0


if __name__ == "__main__":
    sys.exit(main())
