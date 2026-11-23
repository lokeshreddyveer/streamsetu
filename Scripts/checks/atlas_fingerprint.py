#!/usr/bin/env python3
"""The one implementation of the assistant-coverage fingerprints (nothing else computes them; the Swift generator does not).

docs/assistant-coverage.md starts with exactly two comment lines, written by this script after the generator ran:
    <!-- atlas-inputs-sha256: <64 hex> -->     SHA-256 over every input of the generator (the files ATLAS_RX selects: the atlas declarations,
                                                AtlasCoverageDoc.swift, AssistantCoverage.swift, AssistantKnowledge.swift)
    <!-- coverage-body-sha256: <64 hex> -->    SHA-256 of the document body (every byte after those two lines): catches a hand edit of the body
Inputs hash = SHA-256 of b"atlas-inputs-v1\\0" then, for each selected path in sorted order, len(path) as 8 bytes big-endian + the UTF-8 path +
len(content) as 8 bytes big-endian + the raw file bytes. No mtimes, no absolute paths, no newline conversion (the repo does not normalise).
The Swift test AssistantCoverage/AtlasDeclarationTests stays the regeneration-and-comparison authority for the body; it ignores these two lines.
A person who edits the body AND recomputes the second hash is out of scope.

Regenerate after a change to any input:
    cd macos && ATLAS_DOCS_WRITE=1 swift test --filter AtlasDeclarationTests      (rewrites the body)
    python3 Scripts/checks/atlas_fingerprint.py --write docs/assistant-coverage.md   (rewrites the two header lines)
Other use: --check docs/assistant-coverage.md   (exit 1 and a message when the header is missing, duplicated, malformed or stale)."""
import hashlib, re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import common

ATLAS_RX = r"^macos/Sources/REDDY/(Atlas/|Services/AssistantCoverage\.swift|Services/AssistantKnowledge\.swift)"
DOC = "docs/assistant-coverage.md"
REGEN = ("cd macos && ATLAS_DOCS_WRITE=1 swift test --filter AtlasDeclarationTests, then "
         "python3 Scripts/checks/atlas_fingerprint.py --write docs/assistant-coverage.md")
KEY_IN, KEY_BODY = "atlas-inputs-sha256", "coverage-body-sha256"
_LINE = r"<!-- %s: ([0-9a-f]{64}) -->"


def inputs_hash(ctx):
    """Fingerprint of every generator input visible to ctx (overlay-aware, by content only)."""
    h = hashlib.sha256(b"atlas-inputs-v1\0")
    for f in sorted(ctx.select([ATLAS_RX])):
        p, c = f.encode("utf-8"), ctx.abs(f).read_bytes()
        h.update(len(p).to_bytes(8, "big")); h.update(p); h.update(len(c).to_bytes(8, "big")); h.update(c)
    return h.hexdigest()


def body_hash(body: bytes):
    return hashlib.sha256(b"coverage-body-v1\0" + body).hexdigest()


def split(doc: bytes):
    """-> (errors, inputs_hex, body_hex, body_bytes). Fails closed: exactly two well-formed header lines, first lines of the file, never repeated."""
    errs, lines = [], doc.split(b"\n", 2)
    text = doc.decode("utf-8", "replace")
    n_in, n_body = text.count(KEY_IN), text.count(KEY_BODY)
    if n_in == 0: errs.append("the '%s' line is missing" % KEY_IN)
    if n_body == 0: errs.append("the '%s' line is missing" % KEY_BODY)
    if n_in > 1 or n_body > 1: errs.append("a header line is duplicated (%s x%d, %s x%d)" % (KEY_IN, n_in, KEY_BODY, n_body))
    a = b = None
    if len(lines) == 3:
        m1 = re.fullmatch(_LINE % KEY_IN, lines[0].decode("utf-8", "replace")); m2 = re.fullmatch(_LINE % KEY_BODY, lines[1].decode("utf-8", "replace"))
        a, b = m1 and m1.group(1), m2 and m2.group(1)
    if (n_in == 1 and n_body == 1) and not (a and b):
        errs.append("the two header lines are not the first two lines of the file in the form '<!-- %s: <64 lowercase hex> -->' then '<!-- %s: <64 lowercase hex> -->'" % (KEY_IN, KEY_BODY))
    return errs, a, b, (lines[2] if len(lines) == 3 else b"")


def verify(ctx, doc: bytes):
    """-> list of error strings (empty = the document header matches the inputs and the body)."""
    errs, a, b, body = split(doc)
    if errs: return errs
    if body_hash(body) != b: errs.append("the document body does not match its embedded %s (edited by hand? regenerate: %s)" % (KEY_BODY, REGEN))
    now = inputs_hash(ctx)
    if now != a: errs.append("atlas inputs changed since the document was generated (embedded %s... now %s...): regenerate with %s" % (a[:12], now[:12], REGEN))
    return errs


def render(ctx, doc: bytes):
    """The document with a fresh header (any previous header lines are replaced; the body is untouched)."""
    lines = doc.split(b"\n", 2)
    if len(lines) == 3 and re.fullmatch(_LINE % KEY_IN, lines[0].decode("utf-8", "replace")) and re.fullmatch(_LINE % KEY_BODY, lines[1].decode("utf-8", "replace")):
        doc = lines[2]
    if KEY_IN.encode() in doc or KEY_BODY.encode() in doc: raise ValueError("the body already mentions a fingerprint marker; refusing to write")
    return ("<!-- %s: %s -->\n<!-- %s: %s -->\n" % (KEY_IN, inputs_hash(ctx), KEY_BODY, body_hash(doc))).encode() + doc


def main(argv):
    if len(argv) != 2 or argv[0] not in ("--write", "--check"):
        print(__doc__.split("Regenerate")[0].splitlines()[0] + "\nusage: atlas_fingerprint.py --write|--check docs/assistant-coverage.md"); return 2
    ctx, path = common.Ctx(), Path(argv[1])
    doc = path.read_bytes()
    if argv[0] == "--write":
        new = render(ctx, doc)
        if new != doc: path.write_bytes(new)
        print("%s: header %s" % (path, "written" if new != doc else "already current"))
        return 0
    errs = verify(ctx, doc)
    for e in errs: print("FAIL %s: %s" % (path, e))
    print("PASS" if not errs else "FAIL"); return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
