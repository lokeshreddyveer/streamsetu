export type Channel = { id: string; name: string; url: string; group: string; logo?: string; tvgId?: string };

const ATTR = /([\w-]+)="([^"]*)"/g;

export function parseM3U(text: string): { channels: Channel[]; epg?: string } {
  const out: Channel[] = [];
  let epg: string | undefined;
  let pending: { name: string; group: string; logo?: string; tvgId?: string } | null = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith("#EXTM3U")) {
      const a: Record<string, string> = {};
      for (const m of line.matchAll(ATTR)) a[m[1]] = m[2];
      epg = (a["url-tvg"] || a["x-tvg-url"] || "").split(",")[0] || undefined;
    } else if (line.startsWith("#EXTINF")) {
      const attrs: Record<string, string> = {};
      for (const m of line.matchAll(ATTR)) attrs[m[1]] = m[2];
      const name = line.slice(line.indexOf(",") + 1).trim() || attrs["tvg-name"] || "Unnamed";
      pending = { name, group: attrs["group-title"] || "Ungrouped", logo: attrs["tvg-logo"] || undefined, tvgId: attrs["tvg-id"] || undefined };
    } else if (line && !line.startsWith("#") && pending) {
      out.push({ id: line, url: line, ...pending });
      pending = null;
    }
  }
  return { channels: out, epg };
}

/** For Xtream get.php playlists, the matching xmltv.php guide URL. */
export function xtreamEpgUrl(source: string): string | undefined {
  try {
    const u = new URL(source);
    if (!u.pathname.endsWith("/get.php")) return undefined;
    const g = new URL(u.origin + u.pathname.replace(/get\.php$/, "xmltv.php"));
    for (const k of ["username", "password"]) { const v = u.searchParams.get(k); if (v) g.searchParams.set(k, v); }
    return g.toString();
  } catch { return undefined; }
}

export function xtreamUrl(server: string, user: string, pass: string): string {
  let base = server.trim();
  if (!base.includes("://")) base = "http://" + base;
  base = base.replace(/\/+$/, "");
  return `${base}/get.php?username=${encodeURIComponent(user)}&password=${encodeURIComponent(pass)}&type=m3u_plus&output=ts`;
}
