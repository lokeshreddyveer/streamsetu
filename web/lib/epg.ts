import type { EpgMap } from "./store";

const PROG = /<programme\b([^>]*)>([\s\S]*?)<\/programme>/g;
const TITLE = /<title\b[^>]*>([\s\S]*?)<\/title>/;

function attr(a: string, name: string): string {
  const m = new RegExp(`${name}="([^"]*)"`).exec(a);
  return m ? m[1] : "";
}

function decode(s: string): string {
  return s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n))).trim();
}

/** "20260101120000 +0100" -> unix ms */
export function xmltvTime(s: string): number {
  const m = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\s*([+-])?(\d{2})?(\d{2})?/.exec(s);
  if (!m) return NaN;
  const t = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]);
  const off = m[7] ? (+(m[8] ?? 0) * 60 + +(m[9] ?? 0)) * 60000 * (m[7] === "-" ? -1 : 1) : 0;
  return t - off;
}

/** Keeps only programmes that end in the future and start within 36h. */
export function parseXmltv(xml: string, now = Date.now()): EpgMap {
  const out: EpgMap = {};
  for (const m of xml.matchAll(PROG)) {
    const s = xmltvTime(attr(m[1], "start")), e = xmltvTime(attr(m[1], "stop"));
    const ch = attr(m[1], "channel");
    if (!ch || !(e > now) || !(s < now + 36 * 3600_000)) continue;
    const tm = TITLE.exec(m[2]);
    const t = tm ? decode(tm[1]) : "";
    if (t) (out[ch] ||= []).push({ s, e, t });
  }
  for (const k in out) out[k].sort((a, b) => a.s - b.s);
  return out;
}

export async function gunzipIfNeeded(buf: ArrayBuffer): Promise<string> {
  const b = new Uint8Array(buf);
  if (b[0] === 0x1f && b[1] === 0x8b) {
    const stream = new Blob([buf]).stream().pipeThrough(new DecompressionStream("gzip"));
    return await new Response(stream).text();
  }
  return new TextDecoder().decode(b);
}
