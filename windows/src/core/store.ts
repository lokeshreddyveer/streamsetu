import type { Playlist } from "./types";

const KEY = "streamsetu.playlists";
const FAV = "streamsetu.favorites";
const PROGRESS = "streamsetu.progress";

function read<T>(key: string, fallback: T): T { try { const v = localStorage.getItem(key); return v ? (JSON.parse(v) as T) : fallback; } catch { return fallback; } }
function write(key: string, value: unknown) { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* storage full or blocked: the app still works for this session */ } }

export const playlists = {
  all: (): Playlist[] => read<Playlist[]>(KEY, []),
  save(list: Playlist[]) { write(KEY, list); },
  add(p: Playlist) { const l = playlists.all().filter((x) => x.id !== p.id); l.push(p); write(KEY, l); },
  remove(id: string) { write(KEY, playlists.all().filter((x) => x.id !== id)); },
};

export const favorites = {
  all: (): string[] => read<string[]>(FAV, []),
  has: (id: string) => favorites.all().includes(id),
  toggle(id: string): boolean { const l = favorites.all(); const i = l.indexOf(id); if (i >= 0) l.splice(i, 1); else l.unshift(id); write(FAV, l); return i < 0; },
};

export interface Progress { position: number; duration: number; at: number }
export const progress = {
  all: () => read<Record<string, Progress>>(PROGRESS, {}),
  get: (id: string): Progress | undefined => progress.all()[id],
  /** Remembered while watching; a film within the last 30 seconds, or 95% through, counts as finished and is forgotten. */
  save(id: string, position: number, duration: number) {
    const all = progress.all();
    if (duration > 0 && (duration - position < 30 || position / duration > 0.95)) delete all[id]; else if (position > 10) all[id] = { position, duration, at: Date.now() };
    const keep = Object.entries(all).sort((a, b) => b[1].at - a[1].at).slice(0, 300);
    write(PROGRESS, Object.fromEntries(keep));
  },
  /** Titles left part-way, most recent first. */
  recent: (): [string, Progress][] => Object.entries(progress.all()).sort((a, b) => b[1].at - a[1].at),
};
