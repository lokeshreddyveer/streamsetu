#!/usr/bin/env python3
"""Writes the fixture playlist for the Mac UI tests: live channels in three groups and movies in two, all pointing at one short local video."""
import sys
out, media = sys.argv[1], sys.argv[2]
lines = ["#EXTM3U"]
for g, names in {"News": ["Alpha News", "Beta News"], "Sports": ["Gamma Sports", "Delta Sports"], "Kids": ["Epsilon Kids"]}.items():
    for i, n in enumerate(names):
        lines += [f'#EXTINF:-1 tvg-id="{n.replace(" ", "")}" tvg-name="{n}" group-title="{g}",{n}', f"{media}?live={n.replace(' ', '')}"]
for g, names in {"Action Movies": ["The Test Pattern (2019)", "Colour Bars (2021)", "Moving Bars (2020)"], "Drama Movies": ["Quiet Signal (2018)", "Long Take (2022)"]}.items():
    for n in names:
        n_id = sum(map(ord, n))
        lines += [f'#EXTINF:-1 tvg-name="{n}" group-title="{g}",{n}', media.rsplit("/", 1)[0] + f"/movie/test.mp4?id={n_id}"]
open(out, "w").write("\n".join(lines) + "\n")
