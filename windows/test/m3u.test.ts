import { describe, expect, it } from "vitest";
import { classify, parseM3U, toLibrary } from "../src/core/m3u";

const sample = `#EXTM3U
#EXTINF:-1 tvg-id="bbc1.uk" tvg-logo="http://x/bbc.png" group-title="News, UK",BBC One HD
http://host/live/u/p/1.ts
#EXTINF:-1 group-title="Movies",Heat (1995)
http://host/movie/u/p/10.mkv
#EXTINF:-1 group-title="Series",The Show S01E02
http://host/series/u/p/21.mp4
#EXTINF:-1 group-title="Series",The Show S01E01
http://host/series/u/p/20.mp4
#EXTVLCOPT:http-user-agent=x
#EXTINF:-1,Broken entry
not-a-url
#EXTINF:-1 group-title="News, UK",BBC One HD
http://host/live/u/p/1.ts
`;

describe("M3U", () => {
  it("reads titles with commas in the group, logos and guide ids", () => {
    const items = parseM3U(sample);
    const bbc = items.find((i) => i.title === "BBC One HD")!;
    expect(bbc.kind).toBe("live"); expect(bbc.group).toBe("News, UK"); expect(bbc.logo).toBe("http://x/bbc.png"); expect(bbc.epgId).toBe("bbc1.uk");
  });

  it("drops entries with no address and repeated addresses", () => {
    const items = parseM3U(sample);
    expect(items.some((i) => i.title === "Broken entry")).toBe(false);
    expect(items.filter((i) => i.title === "BBC One HD")).toHaveLength(1);
  });

  it("sorts entries into live, movies and series and groups episodes under one show in order", () => {
    const lib = toLibrary(parseM3U(sample));
    expect(lib.live).toHaveLength(1); expect(lib.movies).toHaveLength(1); expect(lib.series).toHaveLength(1);
    const eps = lib.episodes.get("the show")!;
    expect(eps.map((e) => e.episode)).toEqual([1, 2]); expect(eps[0].season).toBe(1);
  });

  it("classifies by path first, then by group and file name", () => {
    expect(classify("http://h/movie/u/p/1.mp4", "", "x")).toBe("movie");
    expect(classify("http://h/a.mp4", "", "x")).toBe("movie");
    expect(classify("http://h/a.ts", "Sports", "Match")).toBe("live");
    expect(classify("http://h/a.ts", "TV Shows", "x")).toBe("series");
  });

  it("handles Windows line endings and an empty file", () => {
    expect(parseM3U(sample.replace(/\n/g, "\r\n")).length).toBe(parseM3U(sample).length);
    expect(parseM3U("")).toEqual([]);
  });
});
