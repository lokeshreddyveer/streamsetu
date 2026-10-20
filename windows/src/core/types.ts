/** A playlist the person added. The password never lives here: it is kept in Windows Credential Manager under `secretRef`. */
export interface Playlist {
  id: string;
  name: string;
  kind: "xtream" | "m3u";
  /** The server address (Xtream) or the playlist link (M3U). */
  address: string;
  username?: string;
  secretRef?: string;
}

export type Kind = "live" | "movie" | "series";

export interface Item {
  id: string;
  kind: Kind;
  title: string;
  group: string;
  logo?: string;
  /** For live and movies, the address to play. Series are opened to list their episodes first. */
  url?: string;
  /** The guide id (tvg-id) of a channel. */
  epgId?: string;
  year?: number;
  rating?: number;
  plot?: string;
  /** Xtream series id, used to load the episodes. */
  seriesId?: string;
  /** Episode numbering, for items that are episodes. */
  season?: number;
  episode?: number;
  ext?: string;
}

export interface Episode { id: string; title: string; season: number; episode: number; url: string; ext?: string }

export interface Library { live: Item[]; movies: Item[]; series: Item[] }
