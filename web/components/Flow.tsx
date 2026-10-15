import Image from "next/image";
import { sources } from "@/content/site";

const devices = ["Mac", "iPhone and iPad", "Android phone and tablet", "Fire TV and Android TV"];

function curve(fromX: number, fromY: number, toX: number, toY: number) {
  const mid = (fromX + toX) / 2;
  return `M${fromX} ${fromY} C ${mid} ${fromY}, ${mid} ${toY}, ${toX} ${toY}`;
}

export function Flow() {
  const left = sources.map((_, i) => curve(0, ((i + 0.5) / sources.length) * 100, 42, 50));
  const right = devices.map((_, i) => curve(58, 50, 100, ((i + 0.5) / devices.length) * 100));
  return (
    <div className="flow">
      <svg className="flow-lines" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
        {left.map((d, i) => <path key={`l${i}`} d={d} className="line a" style={{ animationDelay: `${i * 0.25}s` }} />)}
        {right.map((d, i) => <path key={`r${i}`} d={d} className="line b" style={{ animationDelay: `${i * 0.3}s` }} />)}
      </svg>
      <ul className="flow-col">
        {sources.map((s) => <li key={s}>{s}</li>)}
      </ul>
      <div className="flow-hub">
        <Image src="/img/icon.png" alt="" width={120} height={120} />
        <strong>One library</strong>
        <small>Searchable, sorted, remembered</small>
      </div>
      <ul className="flow-col right">
        {devices.map((d) => <li key={d}>{d}</li>)}
      </ul>
    </div>
  );
}
