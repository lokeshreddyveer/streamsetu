import { NextRequest } from "next/server";
import { checkPublicUrl, fetchPublic } from "@/lib/netguard";

export const runtime = "nodejs";
const MAX_PLAYLIST = 50 * 1024 * 1024;
const MAX_EPG = 200 * 1024 * 1024;

// Fetches a remote M3U server-side so the browser isn't blocked by CORS.
// Refuses non-http(s) and private/loopback addresses to avoid SSRF.
export async function GET(req: NextRequest) {
  const raw = req.nextUrl.searchParams.get("url");
  const checked = await checkPublicUrl(raw);
  if ("error" in checked) return new Response(checked.error, { status: 400 });
  const url = checked.url;
  const max = req.nextUrl.searchParams.get("kind") === "epg" ? MAX_EPG : MAX_PLAYLIST;
  try {
    const res = await fetchPublic(url.toString(), { headers: { "User-Agent": "Reddy/1.0" }, signal: AbortSignal.timeout(60000) });
    if (!res.ok) return new Response(`Upstream returned ${res.status}`, { status: 502 });
    const len = Number(res.headers.get("content-length") ?? 0);
    if (len > max) return new Response("Playlist too large", { status: 413 });
    const buf = await res.arrayBuffer();
    if (buf.byteLength > max) return new Response("Playlist too large", { status: 413 });
    return new Response(buf, { headers: { "Content-Type": "text/plain; charset=utf-8" } });
  } catch (e) {
    return new Response(`Fetch failed: ${(e as Error).message}`, { status: 502 });
  }
}
