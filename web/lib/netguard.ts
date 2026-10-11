import { lookup } from "node:dns/promises";
import net from "node:net";

export function isPrivate(ip: string): boolean {
  if (net.isIPv6(ip)) {
    const l = ip.toLowerCase();
    return l === "::1" || l.startsWith("fc") || l.startsWith("fd") || l.startsWith("fe80") || l.startsWith("::ffff:");
  }
  const [a, b] = ip.split(".").map(Number);
  return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127);
}

/** Parses a user-supplied URL and rejects non-http(s) schemes and private/loopback hosts (SSRF guard). */
export async function checkPublicUrl(raw: string | null): Promise<{ url: URL } | { error: string }> {
  if (!raw) return { error: "Missing url" };
  let url: URL;
  try { url = new URL(raw); } catch { return { error: "Invalid url" }; }
  if (url.protocol !== "http:" && url.protocol !== "https:") return { error: "Unsupported protocol" };
  try {
    const addrs = await lookup(url.hostname, { all: true });
    if (addrs.some((a) => isPrivate(a.address))) return { error: "Address not allowed" };
  } catch { return { error: "Host not found" }; }
  return { url };
}

/** fetch() that follows up to 4 redirects, re-validating every hop against the public-host rule. */
export async function fetchPublic(raw: string, init: RequestInit): Promise<Response> {
  let target = raw;
  for (let hop = 0; hop < 5; hop++) {
    const checked = await checkPublicUrl(target);
    if ("error" in checked) throw new Error(checked.error);
    const res = await fetch(checked.url, { ...init, redirect: "manual" });
    if (res.status >= 300 && res.status < 400 && res.headers.get("location")) {
      res.body?.cancel();
      target = new URL(res.headers.get("location")!, checked.url).toString();
      continue;
    }
    return res;
  }
  throw new Error("Too many redirects");
}
