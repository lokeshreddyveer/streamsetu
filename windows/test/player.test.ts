import { describe, expect, it, vi } from "vitest";

// The player libraries need a browser; the choice of how to play does not.
vi.mock("hls.js", () => ({ default: class {} }));
vi.mock("mpegts.js", () => ({ default: {} }));
const { wayToPlay } = await import("../src/core/player");

describe("how an address is played", () => {
  it("chooses by file type, ignoring the query", () => {
    expect(wayToPlay("http://h/live/u/p/1.m3u8?token=a.ts", true)).toBe("hls");
    expect(wayToPlay("http://h/live/u/p/1.ts", true)).toBe("ts");
    expect(wayToPlay("http://h/movie/u/p/1.mkv", false)).toBe("native");
    expect(wayToPlay("http://h/movie/u/p/1.avi", false)).toBe("external");
  });
  it("guesses live streams are HLS and films are native when the address says nothing", () => {
    expect(wayToPlay("http://h/stream/1", true)).toBe("hls");
    expect(wayToPlay("http://h/stream/1", false)).toBe("native");
  });
});
