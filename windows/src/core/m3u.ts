import type { Item, Kind, Library } from "./types";

/** `key="value"` pairs of an #EXTINF line. Values may hold commas, so they are read before the title. */
function attributes(line: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of line.matchAll(/([A-Za-z0-9_-]+)="([^"]*)"/g)) out[m[1].toLowerCase()] = m[2];
  return out;
}

/** The title after the last comma that is not inside quotes. */
function titleOf(line: string): string {
  let inQuote = false, cut = -1;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === '"') inQuote = !inQuote;
    else if (c === "," && !inQuote) cut = i;
  }
  return (cut >= 0 ? line.slice(cut + 1) : "").trim();
}

const EPISODE = /^(.*?)[\s._-]+S(\d{1,2})[\s._-]*E(\d{1,3})\b/i;

/** What kind of thing an entry is: Xtream-style paths say so, otherwise a group name or the numbering does. */
export function classify(url: string, group: string, title: string): Kind {
  const path = url.toLowerCase();
  if (/\/series\//.test(path)) return "series";
  if (/\/movie\//.test(path)) return "movie";
  if (/\/live\//.test(path)) return "live";
  const g = group.toLowerCase();
  if (/\b(series|serial|tv shows?|shows)\b/.test(g) || EPISODE.test(title)) return "series";
  if (/\b(movies?|films?|vod|cinema)\b/.test(g) || /\.(mp4|mkv|avi|mov|m4v)(\?|$)/.test(path)) return "movie";
  return "live";
}

/** Reads an M3U or M3U8 playlist. Entries that are not playable (no address) are dropped, and repeated addresses stay once. */
export function parseM3U(text: string): Item[] {
  const items: Item[] = [];
  const seen = new Set<string>();
  let pending: { title: string; attrs: Record<string, string> } | null = null;
  let n = 0;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith("#EXTINF")) { pending = { title: titleOf(line), attrs: attributes(line) }; continue; }
    if (line.startsWith("#")) continue;
    if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(line) || !pending) { pending = null; continue; }
    if (seen.has(line)) { pending = null; continue; }
    seen.add(line);
    const a = pending.attrs;
    const title = pending.title || a["tvg-name"] || line;
    const group = a["group-title"] ?? "";
    const kind = classify(line, group, title);
    const item: Item = { id: `m3u:${n++}`, kind, title, group: group || (kind === "live" ? "Channels" : kind === "movie" ? "Movies" : "Series"), url: line };
    if (a["tvg-logo"]) item.logo = a["tvg-logo"];
    if (a["tvg-id"]) item.epgId = a["tvg-id"];
    const ep = kind === "series" ? EPISODE.exec(title) : null;
    if (ep) { item.title = ep[1].trim(); item.season = Number(ep[2]); item.episode = Number(ep[3]); }
    const ext = /\.([a-z0-9]{2,4})(\?|$)/i.exec(line);
    if (ext) item.ext = ext[1].toLowerCase();
    items.push(item);
    pending = null;
  }
  return items;
}

/** Splits parsed entries into the three lists. Episodes of one show become a single series entry that remembers its episodes. */
export function toLibrary(items: Item[]): Library & { episodes: Map<string, Item[]> } {
  const library = { live: [] as Item[], movies: [] as Item[], series: [] as Item[], episodes: new Map<string, Item[]>() };
  for (const it of items) {
    if (it.kind === "live") library.live.push(it);
    else if (it.kind === "movie") library.movies.push(it);
    else {
      const key = it.title.toLowerCase();
      const list = library.episodes.get(key);
      if (list) list.push(it);
      else {
        library.episodes.set(key, [it]);
        library.series.push({ id: `show:${key}`, kind: "series", title: it.title, group: it.group, logo: it.logo, seriesId: key });
      }
    }
  }
  for (const list of library.episodes.values()) list.sort((a, b) => (a.season ?? 0) - (b.season ?? 0) || (a.episode ?? 0) - (b.episode ?? 0));
  return library;
}
