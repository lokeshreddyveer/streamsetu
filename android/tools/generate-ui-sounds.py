#!/usr/bin/env python3
"""
Generates the interface tones in app/src/main/res/raw (ui_*.wav). Original synthesis, no samples from anywhere: soft glassy ticks for moving, bell-like tones for choosing,
rising pairs for going forward and falling pairs for going back, a sparkle for favorites, a solid click for locks, and a rounded low pair (never a buzz) for errors.
Every tone is built from a few sine partials with a quick attack and an exponential decay, a little pitch settle, and a very light room tail; levels are kept low (peaks around -3 to -5 dBFS) because
the app plays them at a small fraction of this level, and every file starts and ends at zero so nothing clicks.

    python3 tools/generate-ui-sounds.py            (run from the android folder)
"""
import math, random, struct, wave, os

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app", "src", "main", "res", "raw")

def n(seconds): return int(seconds * SR)

PITCH = 1.0
SUFFIX = ""

def tone(freq, dur, amp=1.0, attack=0.004, tau=0.08, partials=((1.0, 1.0, 1.0),), settle=0.0, settle_tau=0.03, shimmer=0.0):
    """A struck tone. partials = (frequency ratio, amplitude, decay scale). settle = a small drop from a slightly higher start (a pluck's pitch settling)."""
    freq *= PITCH
    out = [0.0] * n(dur)
    for ratio, a, ts in partials:
        phase = 0.0
        for i in range(len(out)):
            t = i / SR
            f = freq * ratio * (1.0 + settle * math.exp(-t / settle_tau))
            phase += 2 * math.pi * f / SR
            env = (1 - math.exp(-t / (attack / 3 + 1e-9))) * math.exp(-t / (tau * ts))
            s = math.sin(phase)
            if shimmer: s += shimmer * math.sin(phase * 2.01 + 0.7) * math.exp(-t / (tau * 0.5))
            out[i] += a * env * s
    return out

def noise_burst(dur, amp=1.0, tau=0.01, lowpass=0.5, seed=1):
    r = random.Random(seed); y = 0.0; out = []
    for i in range(n(dur)):
        y += lowpass * (r.uniform(-1, 1) - y)
        out.append(amp * y * math.exp(-i / SR / tau))
    return out

def whoosh(dur, up=True, amp=0.5, seed=3):
    """Filtered noise whose brightness sweeps: a soft air movement for a panel opening or closing."""
    r = random.Random(seed); y = 0.0; out = []
    total = n(dur)
    for i in range(total):
        p = i / total
        k = (0.04 + 0.30 * (p if up else 1 - p))
        y += k * (r.uniform(-1, 1) - y)
        env = math.sin(math.pi * p) ** 2
        out.append(amp * y * env)
    return out

def place(base, part, at):
    start = n(at)
    if start + len(part) > len(base): base.extend([0.0] * (start + len(part) - len(base)))
    for i, v in enumerate(part): base[start + i] += v
    return base

def room(x, wet=0.14):
    """A very short room tail: four comb filters and two all-passes, mixed in softly."""
    def comb(sig, delay_ms, fb):
        d = n(delay_ms / 1000); buf = [0.0] * d; out = []; idx = 0
        for v in sig:
            y = buf[idx]; out.append(y); buf[idx] = v + y * fb; idx = (idx + 1) % d
        return out
    def allpass(sig, delay_ms, g=0.5):
        d = n(delay_ms / 1000); buf = [0.0] * d; out = []; idx = 0
        for v in sig:
            b = buf[idx]; y = -g * v + b; buf[idx] = v + g * y; out.append(y); idx = (idx + 1) % d
        return out
    tail_len = len(x) + n(0.12)
    padded = x + [0.0] * (tail_len - len(x))
    wetsig = [0.0] * tail_len
    for dm, fb in ((29.7, 0.55), (37.1, 0.52), (41.1, 0.5), (43.7, 0.48)):
        c = comb(padded, dm, fb)
        for i in range(tail_len): wetsig[i] += c[i] * 0.25
    wetsig = allpass(allpass(wetsig, 5.0), 1.7)
    return [padded[i] * (1 - wet * 0.3) + wetsig[i] * wet for i in range(tail_len)]

def finish(x, peak_db=-10.0, fade_in=0.002, fade_out=0.03):
    # remove any offset, fade the ends to zero, and set the peak
    mean = sum(x) / len(x); x = [v - mean for v in x]
    fi, fo = n(fade_in), n(fade_out)
    for i in range(min(fi, len(x))): x[i] *= i / fi
    for i in range(min(fo, len(x))): x[len(x) - 1 - i] *= i / fo
    peak = max(abs(v) for v in x) or 1.0
    g = (10 ** (peak_db / 20)) / peak
    return [v * g for v in x]

def save(name, x):
    name += SUFFIX
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32767)) for v in x))
    print(f"{name}.wav  {len(x)/SR*1000:.0f} ms  {os.path.getsize(path)} bytes")

# musical material: a major pentatonic, so any two tones heard together or in turn are consonant
C5, D5, E5, G5, A5 = 523.25, 587.33, 659.25, 783.99, 880.0
C6, D6, E6, G6, A6 = 1046.5, 1174.7, 1318.5, 1568.0, 1760.0
BELL = ((1.0, 1.0, 1.0), (2.76, 0.28, 0.45), (5.4, 0.08, 0.25))      # a small bell: inharmonic upper partials
GLASS = ((1.0, 1.0, 1.0), (2.0, 0.22, 0.6), (3.0, 0.07, 0.35))        # a clean glassy tick

def build():
    # --- moving the remote: short, dry, soft; the sidebar's is a little lower and warmer
    focus = tone(E6, 0.07, tau=0.014, attack=0.0015, partials=GLASS)
    place(focus, tone(165, 0.03, amp=0.35, tau=0.008), 0)
    save("ui_focus", finish(focus, -5, fade_out=0.012))
    side = tone(A5, 0.085, tau=0.02, attack=0.002, partials=GLASS)
    place(side, tone(130, 0.04, amp=0.4, tau=0.01), 0)
    save("ui_sidebar", finish(side, -5, fade_out=0.015))

    # --- choosing: a bright little bell with a soft click at the front
    sel = tone(A5, 0.16, tau=0.04, partials=BELL, settle=0.012)
    place(sel, noise_burst(0.006, amp=0.25, tau=0.002, lowpass=0.7), 0)
    save("ui_select", room(finish(sel, -3), 0.12))

    fwd = tone(E5, 0.1, tau=0.03, partials=BELL)
    place(fwd, tone(B5 := 987.77, 0.18, tau=0.045, partials=BELL), 0.05)
    save("ui_forward", room(finish(fwd, -3), 0.12))
    back = tone(B5, 0.1, amp=0.9, tau=0.03, partials=BELL)
    place(back, tone(E5, 0.16, amp=0.9, tau=0.04, partials=BELL), 0.05)
    save("ui_back", room(finish(back, -3), 0.1))

    # --- panels
    op = whoosh(0.13, up=True, amp=0.4); place(op, tone(D6, 0.14, amp=0.8, tau=0.04, partials=BELL), 0.06)
    save("ui_menu_open", room(finish(op, -3), 0.1))
    cl = whoosh(0.1, up=False, amp=0.35); place(cl, tone(G5, 0.14, amp=0.6, tau=0.035, partials=GLASS), 0.0)
    save("ui_menu_close", room(finish(cl, -5), 0.08))

    # --- favorites, watch later: small rewards
    fa = tone(C6, 0.28, tau=0.07, partials=BELL, shimmer=0.15)
    place(fa, tone(E6, 0.28, tau=0.07, partials=BELL, shimmer=0.15), 0.065)
    place(fa, tone(G6, 0.5, tau=0.11, partials=BELL, shimmer=0.2), 0.13)
    save("ui_fav_add", room(finish(fa, -3), 0.16))
    fr = tone(G5, 0.16, tau=0.04, partials=BELL); place(fr, tone(E5, 0.28, tau=0.06, partials=BELL), 0.06)
    save("ui_fav_remove", room(finish(fr, -5), 0.1))
    la = tone(G5, 0.2, tau=0.055, partials=BELL); place(la, tone(D6, 0.36, tau=0.09, partials=BELL), 0.08)
    save("ui_later_add", room(finish(la, -3), 0.12))
    lr = tone(D6, 0.14, tau=0.035, partials=BELL); place(lr, tone(G5, 0.24, tau=0.05, partials=BELL), 0.055)
    save("ui_later_remove", room(finish(lr, -5), 0.08))

    # --- folders
    re = tone(D6, 0.06, tau=0.012, attack=0.001, partials=GLASS); place(re, tone(A5, 0.08, tau=0.016, partials=GLASS), 0.045)
    save("ui_reorder", finish(re, -5, fade_out=0.015))
    mf = tone(C5, 0.12, tau=0.03, partials=BELL); place(mf, tone(G5, 0.14, tau=0.035, partials=BELL), 0.05); place(mf, tone(C6, 0.3, tau=0.07, partials=BELL), 0.1)
    save("ui_move_first", room(finish(mf, -3), 0.12))
    lock = tone(196, 0.12, tau=0.03, partials=((1, 1, 1), (2, 0.3, 0.5))); place(lock, noise_burst(0.01, amp=0.5, tau=0.003, lowpass=0.6), 0)
    place(lock, tone(2349, 0.09, amp=0.5, tau=0.018, partials=((1, 1, 1), (2.76, 0.3, 0.4))), 0.035)
    save("ui_lock", room(finish(lock, -3), 0.08))
    ul = tone(2093, 0.08, amp=0.5, tau=0.015, partials=((1, 1, 1), (2.76, 0.3, 0.4))); place(ul, tone(247, 0.14, tau=0.035, partials=((1, 1, 1), (2, 0.3, 0.5))), 0.03)
    place(ul, noise_burst(0.008, amp=0.35, tau=0.003, lowpass=0.6), 0.03)
    save("ui_unlock", room(finish(ul, -3), 0.08))

    # --- outcomes
    su = tone(C6, 0.2, tau=0.05, partials=BELL, shimmer=0.12)
    place(su, tone(E6, 0.2, tau=0.05, partials=BELL, shimmer=0.12), 0.09)
    place(su, tone(G6, 0.2, tau=0.05, partials=BELL, shimmer=0.12), 0.18)
    place(su, tone(C6 * 2, 0.45, amp=0.8, tau=0.1, partials=BELL, shimmer=0.2), 0.27)
    save("ui_success", room(finish(su, -3), 0.2))
    er = tone(233, 0.14, tau=0.04, partials=((1, 1, 1), (2, 0.25, 0.5), (3, 0.08, 0.3)), settle=-0.02)
    place(er, tone(196, 0.2, tau=0.055, partials=((1, 1, 1), (2, 0.25, 0.5), (3, 0.08, 0.3)), settle=-0.02), 0.13)
    save("ui_error", room(finish(er, -3), 0.1))

    # --- starting playback: a gentle rising swell into a soft chord
    pl = whoosh(0.18, up=True, amp=0.3); place(pl, tone(C5, 0.3, amp=0.7, tau=0.08, partials=BELL), 0.1)
    place(pl, tone(G5, 0.3, amp=0.6, tau=0.08, partials=BELL), 0.12); place(pl, tone(C6, 0.35, amp=0.5, tau=0.09, partials=BELL), 0.14)
    save("ui_play", room(finish(pl, -4), 0.16))

# More sets of the same tones: a different instrument and register for each. The first is the original.
THEMES = {
    "": (1.0, BELL, GLASS),
    "_wood": (0.5, ((1.0, 1.0, 1.0), (3.9, 0.4, 0.25), (9.0, 0.1, 0.12)), ((1.0, 1.0, 1.0), (3.9, 0.25, 0.3))),        # a marimba: warm, short
    "_crystal": (1.5, ((1.0, 1.0, 1.0), (2.0, 0.4, 0.5), (3.0, 0.2, 0.3), (4.2, 0.1, 0.2)), ((1.0, 1.0, 1.0), (2.0, 0.3, 0.5))),  # high and bright
    "_soft": (0.75, ((1.0, 1.0, 1.0), (2.0, 0.08, 0.4)), ((1.0, 1.0, 1.0),)),                                              # nearly pure sine, rounded
    "_arcade": (1.0, ((1.0, 1.0, 1.0), (3.0, 0.33, 0.9), (5.0, 0.2, 0.7), (7.0, 0.14, 0.5)), ((1.0, 1.0, 1.0), (3.0, 0.3, 0.8))),  # square-ish bleeps
}

if __name__ == "__main__":
    for suffix, (pitch, bell, glass) in THEMES.items():
        PITCH, SUFFIX, BELL, GLASS = pitch, suffix, bell, glass
        build()
