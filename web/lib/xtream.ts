import type { Channel } from "./m3u";

export type XtreamAccount = { base: string; user: string; pass: string };

/** Recognises the `get.php?username=…&password=…` URL the Add Playlist form builds. */
export function parseXtream(source: string): XtreamAccount | null {
  try {
    const u = new URL(source);
    if (!u.pathname.endsWith("/get.php")) return null;
    const user = u.searchParams.get("username"), pass = u.searchParams.get("password");
    return user && pass ? { base: u.origin, user, pass } : null;
  } catch { return null; }
}

const str = (v: unknown): string | undefined => (v === null || v === undefined || v === "" ? undefined : String(v));

/**
 * Loads live channels through player_api.php, which works on panels that have disabled get.php.
 * `fetchText` is injected so requests can go through the server-side proxy (CORS).
 */
export async function fetchXtreamChannels(a: XtreamAccount, fetchText: (url: string) => Promise<string>): Promise<Channel[]> {
  const q = `username=${encodeURIComponent(a.user)}&password=${encodeURIComponent(a.pass)}`;
  const api = (action: string) => `${a.base}/player_api.php?${q}&action=${action}`;
  const [cats, streams] = await Promise.all([fetchText(api("get_live_categories")), fetchText(api("get_live_streams"))]);
  let list: unknown;
  try { list = JSON.parse(streams); } catch { list = null; }
  if (!Array.isArray(list)) throw new Error("The server did not return a channel list. The account may be expired or the login incorrect.");
  const names = new Map<string, string>();
  try {
    const c = JSON.parse(cats);
    if (Array.isArray(c)) for (const x of c) { const id = str(x.category_id); if (id && typeof x.category_name === "string") names.set(id, x.category_name); }
  } catch { /* categories are optional */ }
  const u = encodeURIComponent(a.user), p = encodeURIComponent(a.pass);
  const seen = new Set<string>();
  const out: Channel[] = [];
  for (const d of list as Record<string, unknown>[]) {
    const id = str(d.stream_id), name = typeof d.name === "string" ? d.name.trim() : "";
    if (!id || !name) continue;
    const url = `${a.base}/live/${u}/${p}/${id}.ts`;
    if (seen.has(url)) continue;
    seen.add(url);
    out.push({ id: url, url, name, group: (str(d.category_id) && names.get(str(d.category_id)!)) || "Ungrouped", logo: str(d.stream_icon), tvgId: str(d.epg_channel_id) });
  }
  return out;
}

export function xtreamGuideUrl(a: XtreamAccount): string {
  return `${a.base}/xmltv.php?username=${encodeURIComponent(a.user)}&password=${encodeURIComponent(a.pass)}`;
}
