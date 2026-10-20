/** What was typed in the address bar: a web address as it is, something that looks like one with https:// added, anything else a search. */
export function resolveAddress(typed: string, search = "https://duckduckgo.com/?q="): string {
  const t = typed.trim();
  if (!t) return "about:blank";
  if (/^https?:\/\//i.test(t)) return t;
  if (/^[^\s/]+\.[a-z]{2,}(:\d+)?([/?#]\S*)?$/i.test(t) || /^localhost(:\d+)?([/?#]\S*)?$/i.test(t) || /^\d{1,3}(\.\d{1,3}){3}(:\d+)?([/?#]\S*)?$/.test(t)) return "https://" + t;
  return search + encodeURIComponent(t);
}

/** A short label for a tab from its address. */
export function tabLabel(url: string): string {
  try { const u = new URL(url); return u.hostname.replace(/^www\./, "") || url; } catch { return url; }
}
