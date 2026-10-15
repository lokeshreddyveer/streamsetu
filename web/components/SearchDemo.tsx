import { Art } from "./Art";

const results = [
  { kind: "Movie", title: "Harbour Lights", note: "2024 · Hindi", seed: 2 },
  { kind: "Series", title: "The Long Way Home", note: "2024 · 3 seasons", seed: 4 },
  { kind: "Movie", title: "Northern Lights", note: "2024 · Hindi", seed: 1 },
  { kind: "Live", title: "Hindi Movies HD", note: "Channel 214", seed: 3 },
];

// The typing is a CSS animation, so there is no script behind it.
export function SearchDemo() {
  return (
    <div className="search-demo" role="img" aria-label="A search for hindi movies 2024 and the results it finds">
      <div className="search-box">
        <span className="glass" />
        <span className="typed">hindi movies 2024</span>
        <span className="menu">All</span>
      </div>
      <ul>
        {results.map((r, i) => (
          <li key={r.title} style={{ animationDelay: `${2.4 + i * 0.25}s` }}>
            <span className="thumb"><Art seed={r.seed} /></span>
            <span className="what"><strong>{r.title}</strong><small>{r.note}</small></span>
            <em>{r.kind}</em>
          </li>
        ))}
      </ul>
    </div>
  );
}
