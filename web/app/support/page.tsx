import type { Metadata } from "next";
import { faq, site } from "@/content/site";

export const metadata: Metadata = { title: "Support", description: "Answers to common questions about StreamSetu, and how to get in touch." };

export default function Support() {
  return (
    <main className="wrap page narrow">
      <h1>Support</h1>
      <p className="lead">Something not working, or a question that is not here? Write to <a href={`mailto:${site.email}`}>{site.email}</a>. Say which device you use and what you saw, and a screenshot helps.</p>
      <h2>Common questions</h2>
      {faq.map((f) => (
        <details key={f.q}>
          <summary>{f.q}</summary>
          <p>{f.a}</p>
        </details>
      ))}
      <h2>If a channel or film will not play</h2>
      <ul>
        <li>Check that the same login works in another player. If it does not, the problem is with the provider.</li>
        <li>Try the other player in the player's options: ExoPlayer or AVPlayer, and MPV. Some files only play in one.</li>
        <li>Providers that allow one connection need the earlier stream to close first. Wait a few seconds and try again.</li>
        <li>On a Fire TV, check that the clock and date are right. A wrong date breaks secure connections.</li>
      </ul>
    </main>
  );
}
