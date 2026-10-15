import type { Metadata } from "next";
import Link from "next/link";
import { features, sources } from "@/content/site";

export const metadata: Metadata = { title: "Features", description: "What StreamSetu does: live TV and the guide, movies and series, search, a deep player, folders and lists." };

export default function Features() {
  return (
    <main className="wrap page">
      <h1>Features</h1>
      <p className="lead">The same app on every device, laid out for the screen in front of you: a remote on a television, touch on a phone, a pointer on a Mac.</p>
      <div className="grid">
        {features.map((f) => (
          <article key={f.title} className="card">
            <h3>{f.title}</h3>
            <p>{f.text}</p>
          </article>
        ))}
      </div>

      <h2>What it connects to</h2>
      <ul className="ticks">
        {sources.map((s) => <li key={s}>{s}</li>)}
      </ul>
      <p>A connection is tried once, by hand, before it is saved. A login that works but returns nothing is turned down, and an unfinished setup is kept as a draft you can come back to.</p>

      <h2>Privacy by design</h2>
      <p>There is no StreamSetu account and no server of ours in the middle. Your playlists, favourites and history live on your device, and the app talks only to the servers you give it. Read the <Link href="/privacy">privacy policy</Link>.</p>
    </main>
  );
}
