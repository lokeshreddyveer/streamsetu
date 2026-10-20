import { beforeEach, describe, expect, it } from "vitest";

// A tiny localStorage for the tests (they run without a browser).
const mem = new Map<string, string>();
(globalThis as unknown as { localStorage: Storage }).localStorage = {
  getItem: (k: string) => mem.get(k) ?? null, setItem: (k: string, v: string) => void mem.set(k, v), removeItem: (k: string) => void mem.delete(k),
  clear: () => mem.clear(), key: () => null, get length() { return mem.size; },
} as Storage;

const { favorites, playlists, progress } = await import("../src/core/store");

beforeEach(() => mem.clear());

describe("store", () => {
  it("keeps playlists without a password and removes them", () => {
    playlists.add({ id: "a", name: "A", kind: "xtream", address: "http://h", username: "u", secretRef: "playlist:a" });
    expect(playlists.all()).toHaveLength(1); expect(JSON.stringify(playlists.all())).not.toMatch(/password/i);
    playlists.remove("a"); expect(playlists.all()).toEqual([]);
  });
  it("toggles favourites, newest first", () => {
    expect(favorites.toggle("x")).toBe(true); expect(favorites.toggle("y")).toBe(true);
    expect(favorites.all()).toEqual(["y", "x"]); expect(favorites.toggle("x")).toBe(false); expect(favorites.has("x")).toBe(false);
  });
  it("remembers a place, and forgets a finished title", () => {
    progress.save("m", 600, 7200); expect(progress.get("m")?.position).toBe(600);
    progress.save("m", 7190, 7200); expect(progress.get("m")).toBeUndefined();
    progress.save("n", 5, 7200); expect(progress.get("n")).toBeUndefined();         // the first seconds are not worth remembering
  });
});
