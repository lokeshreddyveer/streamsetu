import fs from "node:fs";
import path from "node:path";
import React from "react";

/** The privacy policy, terms and licences. The text lives in ../legal/*.md and is copied here by legal/sync-legal.py. */
export type LegalName = "privacy" | "terms" | "licenses";

function inline(text: string, key: string): React.ReactNode[] {
  const out: React.ReactNode[] = [];
  const re = /\[([^\]]+)\]\(([^)]+)\)|\*\*([^*]+)\*\*|(https?:\/\/[^\s)]+)/g;
  let last = 0, m: RegExpExecArray | null, i = 0;
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(text.slice(last, m.index));
    if (m[3]) out.push(<strong key={`${key}-${i++}`}>{m[3]}</strong>);
    else { const href = m[2] ?? m[4]; out.push(<a key={`${key}-${i++}`} href={href} rel="noopener noreferrer">{m[1] ?? m[4]}</a>); }
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

export function LegalDocument({ name }: { name: LegalName }) {
  const text = fs.readFileSync(path.join(process.cwd(), "content", "legal", `${name}.md`), "utf8");
  const nodes: React.ReactNode[] = [];
  let list: string[] = [];
  const flush = () => { if (list.length) { nodes.push(<ul key={`u${nodes.length}`}>{list.map((l, i) => <li key={i}>{inline(l, `l${nodes.length}-${i}`)}</li>)}</ul>); list = []; } };
  text.split("\n").forEach((line, n) => {
    if (line.startsWith("- ")) { list.push(line.slice(2)); return; }
    flush();
    if (line.startsWith("# ")) nodes.push(<h1 key={n}>{line.slice(2)}</h1>);
    else if (line.startsWith("## ")) nodes.push(<h2 key={n}>{line.slice(3)}</h2>);
    else if (line.trim()) nodes.push(<p key={n}>{inline(line, `p${n}`)}</p>);
  });
  flush();
  return (
    <main style={{ maxWidth: 720, margin: "0 auto", padding: "32px 20px 64px", lineHeight: 1.6 }}>
      <nav style={{ marginBottom: 24, fontSize: 14 }}>
        <a href="/">StreamSetu</a> · <a href="/privacy">Privacy</a> · <a href="/terms">Terms</a> · <a href="/licenses">Licenses</a>
      </nav>
      {nodes}
    </main>
  );
}
