// Local-only persistence (IndexedDB): channel cache, watch history and EPG. Nothing leaves the browser.
import type { Channel } from "./m3u";

export type Programme = { s: number; e: number; t: string };
export type EpgMap = Record<string, Programme[]>;

const DB_NAME = "reddy";
let dbp: Promise<IDBDatabase> | null = null;

function open(): Promise<IDBDatabase> {
  if (!dbp) {
    dbp = new Promise((resolve, reject) => {
      const r = indexedDB.open(DB_NAME, 1);
      r.onupgradeneeded = () => {
        const db = r.result;
        for (const n of ["channels", "epg", "meta"]) db.createObjectStore(n);
        db.createObjectStore("history", { keyPath: "url" });
      };
      r.onsuccess = () => resolve(r.result);
      r.onerror = () => reject(r.error);
    });
  }
  return dbp;
}

async function tx<T>(store: string, mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T> | void): Promise<T | undefined> {
  try {
    const db = await open();
    return await new Promise((resolve, reject) => {
      const t = db.transaction(store, mode);
      const req = fn(t.objectStore(store));
      t.oncomplete = () => resolve(req ? (req.result as T) : undefined);
      t.onerror = () => reject(t.error);
    });
  } catch { return undefined; } // storage unavailable (private mode etc.) – app still works uncached
}

export const getChannels = (pl: string) => tx<Channel[]>("channels", "readonly", (s) => s.get(pl));
export const putChannels = (pl: string, c: Channel[]) => tx("channels", "readwrite", (s) => { s.put(c, pl); });

export const getEpg = (pl: string) => tx<EpgMap>("epg", "readonly", (s) => s.get(pl));
export const putEpg = (pl: string, m: EpgMap) => tx("epg", "readwrite", (s) => { s.put(m, pl); });
export const getEpgTime = async (pl: string) => (await tx<number>("meta", "readonly", (s) => s.get("epg:" + pl))) ?? 0;
export const putEpgTime = (pl: string, t: number) => tx("meta", "readwrite", (s) => { s.put(t, "epg:" + pl); });

export const deletePlaylistData = async (pl: string) => {
  await tx("channels", "readwrite", (s) => { s.delete(pl); });
  await tx("epg", "readwrite", (s) => { s.delete(pl); });
  await tx("meta", "readwrite", (s) => { s.delete("epg:" + pl); });
};

type HistoryRow = Channel & { at: number };
export async function getHistory(): Promise<Channel[]> {
  const rows = (await tx<HistoryRow[]>("history", "readonly", (s) => s.getAll())) ?? [];
  return rows.sort((a, b) => b.at - a.at).slice(0, 50);
}
export async function recordPlay(c: Channel) {
  await tx("history", "readwrite", (s) => { s.put({ ...c, at: Date.now() }); });
  const rows = (await tx<HistoryRow[]>("history", "readonly", (s) => s.getAll())) ?? [];
  const stale = rows.sort((a, b) => b.at - a.at).slice(100);
  if (stale.length) await tx("history", "readwrite", (s) => { stale.forEach((r) => s.delete(r.url)); });
}
export const clearHistory = () => tx("history", "readwrite", (s) => { s.clear(); });
