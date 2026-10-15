import type { Metadata } from "next";
import { Markdown } from "@/lib/markdown";
import { notesFor, prettyDate, releases } from "@/lib/releases";

export const metadata: Metadata = { title: "What's new", description: "What changed in each StreamSetu release." };

export default function Changelog() {
  return (
    <main className="wrap page prose">
      <h1>What's new</h1>
      {releases.map((r, i) => (
        <details key={r.tag} open={i === 0} className="release">
          <summary>
            <span>{prettyDate(r.date)}</span>
            <span className="muted small">Mac {r.mac} · Android and Fire TV {r.android} · iPhone and iPad {r.ios}</span>
          </summary>
          <Markdown source={notesFor(r.tag)} startLevel={3} />
        </details>
      ))}
    </main>
  );
}
