import React from "react";

// Just enough markdown for our own release notes and legal texts: headings, paragraphs, lists (one level of nesting), tables, bold, code and links.

function inline(text: string, key: string): React.ReactNode[] {
  const parts: React.ReactNode[] = [];
  const pattern = /\[([^\]]+)\]\(([^)]+)\)|\*\*([^*]+)\*\*|`([^`]+)`|(https?:\/\/[^\s)]+)/g;
  let last = 0;
  let n = 0;
  let m: RegExpExecArray | null;
  while ((m = pattern.exec(text))) {
    if (m.index > last) parts.push(text.slice(last, m.index));
    const id = `${key}-${n++}`;
    if (m[3]) parts.push(<strong key={id}>{m[3]}</strong>);
    else if (m[4]) parts.push(<code key={id}>{m[4]}</code>);
    else {
      const href = m[2] ?? m[5];
      parts.push(<a key={id} href={href} rel="noopener noreferrer">{m[1] ?? m[5]}</a>);
    }
    last = m.index + m[0].length;
  }
  if (last < text.length) parts.push(text.slice(last));
  return parts;
}

function cells(row: string) {
  return row.replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
}

export function Markdown({ source, startLevel = 1 }: { source: string; startLevel?: number }) {
  const lines = source.split("\n");
  const out: React.ReactNode[] = [];
  let i = 0;

  const heading = (level: number, text: string, key: string) => {
    const Tag = `h${Math.min(6, level + startLevel - 1)}` as "h1";
    return <Tag key={key}>{inline(text, key)}</Tag>;
  };

  while (i < lines.length) {
    const line = lines[i];

    if (line.startsWith("|") && lines[i + 1]?.startsWith("|") && /^\|[\s:|-]+\|$/.test(lines[i + 1])) {
      const head = cells(line);
      const body: string[][] = [];
      i += 2;
      while (i < lines.length && lines[i].startsWith("|")) body.push(cells(lines[i++]));
      out.push(
        <div className="table-wrap" key={`t${i}`}>
          <table>
            <thead><tr>{head.map((h, k) => <th key={k}>{inline(h, `th${i}-${k}`)}</th>)}</tr></thead>
            <tbody>{body.map((row, r) => <tr key={r}>{row.map((c, k) => <td key={k}>{inline(c, `td${i}-${r}-${k}`)}</td>)}</tr>)}</tbody>
          </table>
        </div>,
      );
      continue;
    }

    if (/^\s*- /.test(line)) {
      const items: { text: string; sub: string[] }[] = [];
      while (i < lines.length && /^\s*- /.test(lines[i])) {
        if (lines[i].startsWith("- ")) items.push({ text: lines[i].slice(2), sub: [] });
        else items[items.length - 1]?.sub.push(lines[i].trim().slice(2));
        i++;
      }
      out.push(
        <ul key={`u${i}`}>
          {items.map((it, k) => (
            <li key={k}>
              {inline(it.text, `li${i}-${k}`)}
              {it.sub.length > 0 && <ul>{it.sub.map((s, j) => <li key={j}>{inline(s, `sub${i}-${k}-${j}`)}</li>)}</ul>}
            </li>
          ))}
        </ul>,
      );
      continue;
    }

    const h = /^(#{1,4}) (.*)$/.exec(line);
    if (h) out.push(heading(h[1].length, h[2], `h${i}`));
    else if (line.trim()) out.push(<p key={`p${i}`}>{inline(line, `p${i}`)}</p>);
    i++;
  }

  return <>{out}</>;
}
