import { describe, expect, it } from "vitest";
import { apiUrl, asList, normalizeHost, parseAccount, parseEpisodes, parseLive, parseMovies, streamUrl } from "../src/core/xtream";

const p = { address: "http://panel.example:8080/c/" };

describe("Xtream", () => {
  it("normalises what people paste as the server address", () => {
    expect(normalizeHost("panel.example:8080/c/")).toBe("http://panel.example:8080");
    expect(normalizeHost("https://panel.example/player_api.php")).toBe("https://panel.example");
  });

  it("builds API and stream addresses with the login encoded", () => {
    expect(apiUrl(p.address, "us er", "p&w", "get_live_streams")).toBe("http://panel.example:8080/player_api.php?username=us+er&password=p%26w&action=get_live_streams");
    expect(streamUrl(p.address, "u", "p w", "live", "5")).toBe("http://panel.example:8080/live/u/p%20w/5.m3u8");
    expect(streamUrl(p.address, "u", "p", "movie", "9", ".mkv")).toBe("http://panel.example:8080/movie/u/p/9.mkv");
  });

  it("treats false, null and keyed objects as lists", () => {
    expect(asList(false)).toEqual([]); expect(asList(null)).toEqual([]); expect(asList({ a: { x: 1 }, b: { x: 2 } })).toHaveLength(2);
  });

  it("reads the account: end date, refusal and not-active", () => {
    const a = parseAccount({ user_info: { auth: 1, status: "Active", exp_date: "1893456000", max_connections: "2" } });
    expect(a.active).toBe(true); expect(a.maxConnections).toBe(2); expect(a.expires?.getUTCFullYear()).toBe(2030);
    expect(() => parseAccount({ user_info: { auth: 0 } })).toThrow(/refused/);
    expect(parseAccount({ user_info: { auth: 1, status: "Expired" } }).active).toBe(false);
    expect(() => parseAccount({})).toThrow();
  });

  it("lists channels with their folder and skips divider rows", () => {
    const live = parseLive(p, "u", "p", [{ stream_id: 1, name: "BBC One", category_id: "7", epg_channel_id: "bbc1" }, { stream_id: 2, name: "#### SPORT ####", category_id: "7" }], [{ category_id: "7", category_name: "UK" }]);
    expect(live).toHaveLength(1); expect(live[0].group).toBe("UK"); expect(live[0].url).toBe("http://panel.example:8080/live/u/p/1.m3u8"); expect(live[0].epgId).toBe("bbc1");
  });

  it("lists movies with their file type and year", () => {
    const m = parseMovies(p, "u", "p", { a: { stream_id: 9, name: "Heat", container_extension: "mkv", year: "1995", rating_5based: 4.5 } }, false);
    expect(m[0].ext).toBe("mkv"); expect(m[0].year).toBe(1995); expect(m[0].url).toMatch(/movie\/u\/p\/9\.mkv$/);
  });

  it("lists episodes season by season in order", () => {
    const eps = parseEpisodes(p, "u", "p", { episodes: { "2": [{ id: "30", episode_num: 1, season: 2, title: "Back" }], "1": [{ id: "21", episode_num: 2, title: "Two" }, { id: "20", episode_num: 1, title: "One" }] } });
    expect(eps.map((e) => [e.season, e.episode])).toEqual([[1, 1], [1, 2], [2, 1]]);
    expect(eps[0].url).toBe("http://panel.example:8080/series/u/p/20.mp4");
  });
});
