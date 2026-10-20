import type { Episode, Item, Playlist } from "./types";

/** Adds http:// when missing and drops the trailing slash and any path such as /c/ or /player_api.php that people paste by mistake. */
export function normalizeHost(address: string): string {
  let a = address.trim();
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(a)) a = "http://" + a;
  try {
    const u = new URL(a);
    return `${u.protocol}//${u.host}`;
  } catch { return a.replace(/\/+$/, ""); }
}

export function apiUrl(address: string, user: string, pass: string, action?: string, extra: Record<string, string> = {}): string {
  const q = new URLSearchParams({ username: user, password: pass });
  if (action) q.set("action", action);
  for (const [k, v] of Object.entries(extra)) q.set(k, v);
  return `${normalizeHost(address)}/player_api.php?${q}`;
}

export type StreamKind = "live" | "movie" | "series";

export function streamUrl(address: string, user: string, pass: string, kind: StreamKind, id: string, ext?: string): string {
  const e = ext ? ext.replace(/^\./, "") : kind === "live" ? "m3u8" : "mp4";
  return `${normalizeHost(address)}/${kind}/${encodeURIComponent(user)}/${encodeURIComponent(pass)}/${encodeURIComponent(id)}.${e}`;
}

type Raw = Record<string, unknown>;
const str = (v: unknown): string | undefined => (v === null || v === undefined || v === "" ? undefined : String(v));
const num = (v: unknown): number | undefined => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : undefined; };
/** Panels return `false`, `{}` or `null` for an empty section, and sometimes key a list by id. */
export function asList(v: unknown): Raw[] {
  if (Array.isArray(v)) return v as Raw[];
  if (v && typeof v === "object") return Object.values(v as Raw).filter((x): x is Raw => !!x && typeof x === "object");
  return [];
}

export interface Account { active: boolean; status: string; expires?: Date; maxConnections?: number }

export function parseAccount(json: unknown): Account {
  const info = (json as { user_info?: Raw } | null)?.user_info;
  if (!info) throw new Error("The server did not accept the login.");
  if (String(info.auth) === "0") throw new Error("The server refused the login. Check the user name and password.");
  const status = str(info.status) ?? "Active";
  const exp = Number(info.exp_date);
  return { active: status.toLowerCase() === "active", status, expires: Number.isFinite(exp) && exp > 0 ? new Date(exp * 1000) : undefined, maxConnections: num(info.max_connections) };
}

function categories(v: unknown): Map<string, string> {
  const m = new Map<string, string>();
  for (const c of asList(v)) { const id = str(c.category_id); if (id) m.set(id, str(c.category_name) ?? `Category ${id}`); }
  return m;
}

export function parseLive(p: Pick<Playlist, "address">, user: string, pass: string, streams: unknown, cats: unknown): Item[] {
  const names = categories(cats);
  const out: Item[] = [];
  for (const s of asList(streams)) {
    const id = str(s.stream_id); const name = str(s.name);
    if (!id || !name || /^[#=*-]{3,}/.test(name.trim())) continue;          // divider rows some providers add
    out.push({ id: `live:${id}`, kind: "live", title: name, group: names.get(str(s.category_id) ?? "") ?? "Channels", logo: str(s.stream_icon), epgId: str(s.epg_channel_id),
      url: streamUrl(p.address, user, pass, "live", id, "m3u8") });
  }
  return out;
}

export function parseMovies(p: Pick<Playlist, "address">, user: string, pass: string, streams: unknown, cats: unknown): Item[] {
  const names = categories(cats);
  const out: Item[] = [];
  for (const s of asList(streams)) {
    const id = str(s.stream_id); const name = str(s.name);
    if (!id || !name) continue;
    const ext = str(s.container_extension) ?? "mp4";
    out.push({ id: `movie:${id}`, kind: "movie", title: name, group: names.get(str(s.category_id) ?? "") ?? "Movies", logo: str(s.stream_icon), rating: num(s.rating_5based ?? s.rating),
      year: num(String(s.year ?? s.releasedate ?? "").slice(0, 4)), ext, url: streamUrl(p.address, user, pass, "movie", id, ext) });
  }
  return out;
}

export function parseSeriesList(streams: unknown, cats: unknown): Item[] {
  const names = categories(cats);
  const out: Item[] = [];
  for (const s of asList(streams)) {
    const id = str(s.series_id); const name = str(s.name);
    if (!id || !name) continue;
    out.push({ id: `series:${id}`, kind: "series", title: name, group: names.get(str(s.category_id) ?? "") ?? "Series", logo: str(s.cover), rating: num(s.rating_5based ?? s.rating),
      year: num(String(s.year ?? s.releaseDate ?? "").slice(0, 4)), plot: str(s.plot), seriesId: id });
  }
  return out;
}

/** The episodes of one series, season by season, as `get_series_info` returns them. */
export function parseEpisodes(p: Pick<Playlist, "address">, user: string, pass: string, info: unknown): Episode[] {
  const eps = (info as { episodes?: unknown } | null)?.episodes;
  const out: Episode[] = [];
  const bySeason: [string, unknown][] = Array.isArray(eps) ? eps.map((l, i) => [String(i + 1), l]) : eps && typeof eps === "object" ? Object.entries(eps as Raw) : [];
  for (const [season, list] of bySeason) {
    for (const e of asList(list)) {
      const id = str(e.id); if (!id) continue;
      const ext = str(e.container_extension) ?? "mp4";
      out.push({ id: `episode:${id}`, title: str(e.title) ?? `Episode ${str(e.episode_num) ?? ""}`.trim(), season: num(e.season) ?? (num(season) ?? 1), episode: num(e.episode_num) ?? 0, ext,
        url: streamUrl(p.address, user, pass, "series", id, ext) });
    }
  }
  return out.sort((a, b) => a.season - b.season || a.episode - b.episode);
}
