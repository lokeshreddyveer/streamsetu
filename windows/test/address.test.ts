import { describe, expect, it } from "vitest";
import { resolveAddress, tabLabel } from "../src/core/address";

describe("address bar", () => {
  it("opens addresses and searches for words", () => {
    expect(resolveAddress("https://a.example/x")).toBe("https://a.example/x");
    expect(resolveAddress("example.com")).toBe("https://example.com");
    expect(resolveAddress("example.com/path?x=1")).toBe("https://example.com/path?x=1");
    expect(resolveAddress("localhost:3000")).toBe("https://localhost:3000");
    expect(resolveAddress("192.168.1.1:8080")).toBe("https://192.168.1.1:8080");
    expect(resolveAddress("best telugu movies")).toBe("https://duckduckgo.com/?q=best%20telugu%20movies");
    expect(resolveAddress("   ")).toBe("about:blank");
  });
  it("labels a tab with its site", () => {
    expect(tabLabel("https://www.example.com/a/b")).toBe("example.com");
    expect(tabLabel("not a url")).toBe("not a url");
  });
});
