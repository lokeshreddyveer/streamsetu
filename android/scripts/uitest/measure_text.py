#!/usr/bin/env python3
"""
Measures the text size of whatever app is on the TV, from a real screenshot and the accessibility tree (standard library only; uses macOS `sips` to read the PNG).

For each text on screen it finds the ink (pixels unlike the background) inside the text's own box, and from the height of capital letters and digits works out the font size:
Roboto's capital height is 0.711 em, so  size_px = cap_height_px / 0.711  and, at the TV's 320 dpi (1 sp = 2 px at 1080p),  size_sp = size_px / 2.
Only texts without descenders or lower-case ascenders are used for the estimate (all capitals and digits, or a single digit), because lower-case letters change the ink height;
the line height of a one-line TextView (size x 1.171 for Roboto) is printed beside it as a cross-check.

  measure_text.py [--serial 192.168.1.68:5555] [--out DIR] [--tag name]
"""
import argparse, os, re, struct, subprocess, sys, xml.etree.ElementTree as ET

ADB = os.environ.get("ADB", os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"))


def adb(serial, *args, binary=False):
    r = subprocess.run([ADB, "-s", serial, *args], capture_output=True, timeout=90)
    return r.stdout if binary else r.stdout.decode("utf8", "replace")


def read_bmp(path):
    d = open(path, "rb").read()
    off = struct.unpack("<I", d[10:14])[0]; w, h = struct.unpack("<ii", d[18:26]); bpp = struct.unpack("<H", d[28:30])[0]
    bytespp = bpp // 8; row = (w * bytespp + 3) // 4 * 4; top_down = h < 0; h = abs(h)
    def px(x, y):
        yy = y if top_down else h - 1 - y; o = off + yy * row + x * bytespp
        return d[o + 2], d[o + 1], d[o]
    return w, h, px


def ink_box(px, box, W, H):
    l, t, r, b = max(box[0], 0), max(box[1], 0), min(box[2], W), min(box[3], H)
    if r - l < 4 or b - t < 4: return None
    from collections import Counter
    samples = [px(x, y) for y in range(t, b, max(1, (b - t) // 12)) for x in range(l, r, max(1, (r - l) // 24))]
    bg = Counter(samples).most_common(1)[0][0]
    dist = lambda p: abs(p[0] - bg[0]) + abs(p[1] - bg[1]) + abs(p[2] - bg[2])
    rows = [y for y in range(t, b) if sum(1 for x in range(l, r, 1) if dist(px(x, y)) > 150) >= 2]
    if not rows: return None
    cols = [x for x in range(l, r) if any(dist(px(x, y)) > 150 for y in range(rows[0], rows[-1] + 1, 2))]
    return rows[0], rows[-1], (cols[0] if cols else l), (cols[-1] if cols else r)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--serial", default="192.168.1.68:5555"); ap.add_argument("--out", default=os.environ.get("TMPDIR", "/tmp")); ap.add_argument("--tag", default="screen")
    a = ap.parse_args()
    png = os.path.join(a.out, a.tag + ".png"); bmp = os.path.join(a.out, a.tag + ".bmp")
    open(png, "wb").write(adb(a.serial, "exec-out", "screencap", "-p", binary=True))
    xml = adb(a.serial, "exec-out", "uiautomator dump /dev/tty"); i, j = xml.find("<?xml"), xml.rfind("</hierarchy>")
    root = ET.fromstring(xml[i:j + 12])
    subprocess.run(["sips", "-s", "format", "bmp", png, "--out", bmp], capture_output=True)
    W, H, px = read_bmp(bmp)
    seen = set(); print(f"{a.tag}: {W}x{H}   (1 sp = 2 px at 1080p)\n{'text':34} {'box h':>5} {'cap/ink px':>10} {'size sp (cap)':>13} {'size sp (line)':>14}")
    for n in root.iter("node"):
        t = (n.get("text") or "").strip()
        if not t or t in seen: continue
        b = [int(v) for v in re.findall(r"\d+", n.get("bounds"))]
        if len(b) != 4 or b[3] > H or b[2] > W: continue
        seen.add(t)
        capsish = re.fullmatch(r"[A-Z0-9 :|\-—+./&]+", t) is not None and not re.search(r"[JQ]", t)
        ink = ink_box(px, b, W, H)
        if not ink: continue
        ink_h = ink[1] - ink[0] + 1
        cap_sp = f"{ink_h / 0.711 / 2:5.1f}" if capsish else "    -"
        line_sp = f"{(b[3] - b[1]) / 1.171 / 2:5.1f}"
        print(f"{t[:34]:34} {b[3] - b[1]:5} {ink_h:10} {cap_sp:>13} {line_sp:>14}")


if __name__ == "__main__":
    main()
