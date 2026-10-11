import { NextRequest } from "next/server";
import { checkPublicUrl, fetchPublic } from "@/lib/netguard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// Pipes a live MPEG-TS stream through this server so the browser isn't blocked by CORS / mixed content.
// Same-origin requests only, public hosts only. Stops pulling from upstream as soon as the viewer disconnects.
export async function GET(req: NextRequest) {
  const site = req.headers.get("sec-fetch-site");
  if (site && site !== "same-origin") return new Response("Forbidden", { status: 403 });
  const checked = await checkPublicUrl(req.nextUrl.searchParams.get("url"));
  if ("error" in checked) return new Response(checked.error, { status: 400 });
  try {
    const upstream = await fetchPublic(checked.url.toString(), {
      headers: { "User-Agent": "VLC/3.0.20 LibVLC/3.0.20" },
      signal: req.signal,
    });
    if (!upstream.ok || !upstream.body) return new Response(`Upstream returned ${upstream.status}`, { status: 502 });
    return new Response(upstream.body, {
      headers: { "Content-Type": upstream.headers.get("content-type") ?? "video/mp2t", "Cache-Control": "no-store" },
    });
  } catch (e) {
    return new Response(`Stream failed: ${(e as Error).message}${(e as { cause?: Error }).cause ? " (" + (e as { cause?: Error }).cause!.message + ")" : ""}`, { status: 502 });
  }
}
