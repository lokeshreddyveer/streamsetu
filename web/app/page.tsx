"use client";
import { useCallback, useEffect, useMemo, useState } from "react";
import Player from "@/components/Player";
import { Channel, parseM3U, xtreamEpgUrl, xtreamUrl } from "@/lib/m3u";
import { fetchXtreamChannels, parseXtream, xtreamGuideUrl } from "@/lib/xtream";
import { gunzipIfNeeded, parseXmltv } from "@/lib/epg";
import * as db from "@/lib/store";
import type { EpgMap } from "@/lib/store";

type Playlist = { id: string; name: string; source: string; text?: string; epgUrl?: string };
type Section = { kind: "all" } | { kind: "recent" } | { kind: "fav" } | { kind: "group"; name: string };

const PAGE = 300;

function load<T>(key: string, fallback: T): T {
  try { const v = localStorage.getItem(key); return v ? (JSON.parse(v) as T) : fallback; } catch { return fallback; }
}
function save(key: string, v: unknown) {
  try { localStorage.setItem(key, JSON.stringify(v)); } catch {}
}

export default function Home() {
  const [ready, setReady] = useState(false);
  const [playlists, setPlaylists] = useState<Playlist[]>([]);
  const [active, setActive] = useState<string | null>(null);
  const [channels, setChannels] = useState<Channel[]>([]);
  const [favs, setFavs] = useState<string[]>([]);
  const [section, setSection] = useState<Section>({ kind: "all" });
  const [q, setQ] = useState("");
  const [current, setCurrentRaw] = useState<Channel | null>(null);
  const [recent, setRecent] = useState<Channel[]>([]);
  const [epg, setEpg] = useState<EpgMap>({});
  const [tick, setTick] = useState(0);
  const [limit, setLimit] = useState(PAGE);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);

  useEffect(() => {
    const p = load<Playlist[]>("reddy.playlists", []);
    setPlaylists(p);
    setFavs(load<string[]>("reddy.favs", []));
    const a = load<string | null>("reddy.active", null);
    setActive(a && p.some((x) => x.id === a) ? a : p[0]?.id ?? null);
    db.getHistory().then((h) => { setRecent(h); if (h.length) setSection({ kind: "recent" }); });
    setReady(true);
  }, []);

  useEffect(() => { const i = setInterval(() => setTick((t) => t + 1), 60000); return () => clearInterval(i); }, []);

  const setCurrent = useCallback((c: Channel | null) => {
    setCurrentRaw(c);
    if (c) {
      db.recordPlay(c);
      setRecent((r) => [c, ...r.filter((x) => x.id !== c.id)].slice(0, 50));
    }
  }, []);

  useEffect(() => {
    if (!ready) return;
    save("reddy.playlists", playlists.map(({ text, ...rest }) => rest)); // pasted file text is kept in memory only
  }, [playlists, ready]);
  useEffect(() => { if (ready) save("reddy.favs", favs); }, [favs, ready]);
  useEffect(() => { if (ready) save("reddy.active", active); }, [active, ready]);

  const activePl = playlists.find((p) => p.id === active);

  const refreshEpg = useCallback(async (p: Playlist, headerEpg?: string) => {
    const cached = await db.getEpg(p.id);
    if (cached) setEpg(cached);
    const src = p.epgUrl || xtreamEpgUrl(p.source) || headerEpg;
    if (!src || !/^https?:\/\//i.test(src)) return;
    if (Date.now() - (await db.getEpgTime(p.id)) < 6 * 3600_000) return;
    try {
      const res = await fetch(`/api/playlist?kind=epg&url=${encodeURIComponent(src)}`);
      if (!res.ok) return;
      const map = parseXmltv(await gunzipIfNeeded(await res.arrayBuffer()));
      if (!Object.keys(map).length) return;
      await db.putEpg(p.id, map);
      await db.putEpgTime(p.id, Date.now());
      setEpg(map);
    } catch { /* the guide is optional */ }
  }, []);

  const fetchChannels = useCallback(async (p: Playlist | undefined) => {
    setChannels([]); setError(null); setCurrentRaw(null); setEpg({});
    if (!p) return;
    setBusy(true);
    // 1. cached list shows instantly
    const cached = await db.getChannels(p.id);
    if (cached?.length) { setChannels(cached); setBusy(false); }
    // 2. refresh from the source
    let headerEpg: string | undefined;
    const viaProxy = async (url: string) => {
      const res = await fetch(`/api/playlist?url=${encodeURIComponent(url)}`);
      if (!res.ok) throw new Error(await res.text());
      return res.text();
    };
    const loadM3U = async () => {
      let text = p.text;
      if (text === undefined) {
        if (!/^https?:\/\//i.test(p.source)) throw new Error("Local file playlists must be re-imported after reloading the page.");
        text = await viaProxy(p.source);
      }
      const parsed = parseM3U(text);
      if (!parsed.channels.length) throw new Error("No channels found in this playlist.");
      headerEpg = parsed.epg;
      return parsed.channels;
    };
    try {
      const xa = parseXtream(p.source);
      let list: Channel[];
      if (xa) {
        // Xtream: JSON API first (works when get.php is disabled), then the M3U route.
        try { list = await fetchXtreamChannels(xa, viaProxy); headerEpg = xtreamGuideUrl(xa); }
        catch (apiErr) { try { list = await loadM3U(); } catch { throw apiErr; } }
      } else {
        list = await loadM3U();
      }
      setChannels(list);
      db.putChannels(p.id, list);
    } catch (e) { if (!cached?.length) setError((e as Error).message); }
    finally { setBusy(false); }
    refreshEpg(p, headerEpg);
  }, [refreshEpg]);

  useEffect(() => { if (ready) fetchChannels(activePl); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [active, ready]);
  useEffect(() => setLimit(PAGE), [section, q, active]);

  const groups = useMemo(() => Array.from(new Set(channels.map((c) => c.group))).sort(), [channels]);
  const visible = useMemo(() => {
    const f = new Set(favs);
    const needle = q.trim().toLowerCase();
    const base = section.kind === "recent" ? recent : channels;
    return base.filter((c) =>
      (section.kind === "all" || section.kind === "recent" || (section.kind === "fav" ? f.has(c.id) : c.group === section.name)) &&
      (!needle || c.name.toLowerCase().includes(needle)));
  }, [channels, recent, favs, section, q]);

  const nowNext = (c: Channel | null) => {
    void tick;
    const list = c?.tvgId ? epg[c.tvgId] : undefined;
    if (!list) return [];
    const now = Date.now();
    return list.filter((p) => p.e > now).slice(0, 2).filter((p, i) => i === 0 ? p.s <= now + 6 * 3600_000 : true);
  };
  const clock = (t: number) => new Date(t).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

  const toggleFav = (id: string) => setFavs((f) => (f.includes(id) ? f.filter((x) => x !== id) : [...f, id]));
  const isOn = (s: Section) => JSON.stringify(s) === JSON.stringify(section);

  function addPlaylist(name: string, source: string, text?: string) {
    const p: Playlist = { id: crypto.randomUUID(), name: name || `Playlist ${playlists.length + 1}`, source, text };
    setPlaylists((l) => [...l, p]);
    setActive(p.id);
    if (text !== undefined) fetchChannels(p);
    setAdding(false);
  }

  return (
    <div className="app">
      <nav className="col">
        <button className={`item ${isOn({ kind: "all" }) ? "on" : ""}`} onClick={() => setSection({ kind: "all" })}>📺 <span className="t">All Channels</span></button>
        <button className={`item ${isOn({ kind: "recent" }) ? "on" : ""}`} onClick={() => setSection({ kind: "recent" })}>🕘 <span className="t">Recently Watched</span>
          {recent.length > 0 && <span className="star" title="Clear history" onClick={(e) => { e.stopPropagation(); db.clearHistory(); setRecent([]); if (section.kind === "recent") setSection({ kind: "all" }); }}>✕</span>}
        </button>
        <button className={`item ${isOn({ kind: "fav" }) ? "on" : ""}`} onClick={() => setSection({ kind: "fav" })}>⭐ <span className="t">Favorites</span></button>
        {groups.length > 0 && <h4>Groups</h4>}
        {groups.map((g) => (
          <button key={g} className={`item ${isOn({ kind: "group", name: g }) ? "on" : ""}`} onClick={() => setSection({ kind: "group", name: g })}>
            <span className="t">{g}</span>
          </button>
        ))}
        <h4>Playlists</h4>
        {playlists.map((p) => (
          <div key={p.id} className={`item ${p.id === active ? "on" : ""}`} onClick={() => setActive(p.id)}>
            <span className="t">{p.name}</span>
            <button className="star" title="Remove" onClick={(e) => {
              e.stopPropagation();
              const rest = playlists.filter((x) => x.id !== p.id);
              setPlaylists(rest);
              db.deletePlaylistData(p.id);
              if (p.id === active) setActive(rest[0]?.id ?? null);
            }}>✕</button>
          </div>
        ))}
        <div style={{ padding: 14 }}><button className="btn" onClick={() => setAdding(true)}>+ Add playlist</button></div>
      </nav>

      <section className="col list">
        <div className="search"><input placeholder={`Search ${visible.length} channels`} value={q} onChange={(e) => setQ(e.target.value)} /></div>
        {busy && <div className="empty">Loading playlist…</div>}
        {error && <div className="empty">{error}</div>}
        {visible.slice(0, limit).map((c) => (
          <div key={c.id} className={`item ${current?.id === c.id ? "on" : ""}`} onClick={() => setCurrent(c)}>
            {c.logo ? /* eslint-disable-next-line @next/next/no-img-element */ <img className="logo" src={c.logo} alt="" loading="lazy" referrerPolicy="no-referrer" onError={(e) => (e.currentTarget.style.visibility = "hidden")} /> : <span className="logo" />}
            <span className="t">{c.name}<small>{nowNext(c)[0]?.t ?? c.group}</small></span>
            <button className={`star ${favs.includes(c.id) ? "on" : ""}`} onClick={(e) => { e.stopPropagation(); toggleFav(c.id); }}>{favs.includes(c.id) ? "★" : "☆"}</button>
          </div>
        ))}
        {visible.length > limit && <div style={{ padding: 14 }}><button className="btn" onClick={() => setLimit((l) => l + PAGE)}>Show more ({visible.length - limit})</button></div>}
      </section>

      <main className="stage">
        {current ? (
          <>
            <Player url={current.url} />
            <div className="now">
              <strong>{current.name}</strong> <span className="note">· {current.group}</span>
              {nowNext(current)[0] && <div>Now: {nowNext(current)[0].t} <span className="note">· until {clock(nowNext(current)[0].e)}</span></div>}
              {nowNext(current)[1] && <div className="note">Next: {nowNext(current)[1].t} · {clock(nowNext(current)[1].s)}</div>}
            </div>
          </>
        ) : (
          <div className="empty">
            <h2>{playlists.length ? "Select a channel" : "Welcome to Reddy Stream"}</h2>
            {!playlists.length && (<><p>Add your own M3U playlist or Xtream login to start watching.</p><button className="btn primary" onClick={() => setAdding(true)}>Add playlist</button></>)}
          </div>
        )}
      </main>

      {adding && <AddModal onClose={() => setAdding(false)} onAdd={addPlaylist} />}
    </div>
  );
}

function AddModal({ onClose, onAdd }: { onClose: () => void; onAdd: (name: string, source: string, text?: string) => void }) {
  const [kind, setKind] = useState<"url" | "file" | "xtream">("url");
  const [name, setName] = useState("");
  const [url, setUrl] = useState("");
  const [file, setFile] = useState<{ name: string; text: string } | null>(null);
  const [server, setServer] = useState("");
  const [user, setUser] = useState("");
  const [pass, setPass] = useState("");

  const ok = kind === "url" ? /^https?:\/\//i.test(url.trim()) : kind === "file" ? !!file : !!(server && user);
  const submit = () => {
    if (!ok) return;
    if (kind === "url") onAdd(name, url.trim());
    else if (kind === "file" && file) onAdd(name || file.name, file.name, file.text);
    else onAdd(name, xtreamUrl(server, user, pass));
  };

  return (
    <div className="modal-bg" onClick={onClose}>
      <form className="modal" onClick={(e) => e.stopPropagation()} onSubmit={(e) => { e.preventDefault(); submit(); }}>
        <h3 style={{ margin: 0 }}>Add playlist</h3>
        <div className="tabs">
          {(["url", "file", "xtream"] as const).map((k) => (
            <button type="button" key={k} className={`btn ${kind === k ? "on" : ""}`} onClick={() => setKind(k)}>{k === "url" ? "M3U URL" : k === "file" ? "M3U File" : "Xtream"}</button>
          ))}
        </div>
        <input placeholder="Name (optional)" value={name} onChange={(e) => setName(e.target.value)} />
        {kind === "url" && <input placeholder="https://example.com/playlist.m3u" value={url} onChange={(e) => setUrl(e.target.value)} />}
        {kind === "file" && <input type="file" accept=".m3u,.m3u8,text/plain" onChange={async (e) => { const f = e.target.files?.[0]; if (f) setFile({ name: f.name, text: await f.text() }); }} />}
        {kind === "xtream" && (<>
          <input placeholder="Server (host:port)" value={server} onChange={(e) => setServer(e.target.value)} />
          <input placeholder="Username" value={user} onChange={(e) => setUser(e.target.value)} autoComplete="off" />
          <input placeholder="Password" type="password" value={pass} onChange={(e) => setPass(e.target.value)} autoComplete="off" />
        </>)}
        <div className="note">Reddy is a player only. Use playlists you are authorized to access. Playlist URLs are fetched through this site&apos;s server.</div>
        <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
          <button type="button" className="btn" onClick={onClose}>Cancel</button>
          <button type="submit" className="btn primary" disabled={!ok}>Add</button>
        </div>
      </form>
    </div>
  );
}
