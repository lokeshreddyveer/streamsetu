import Link from "next/link";
import { site } from "@/content/site";

export function Footer() {
  return (
    <footer className="foot">
      <div className="wrap foot-row">
        <div>
          <strong>StreamSetu</strong>
          <p>StreamSetu is a player only. It provides no channels, movies, series or subscriptions, and it does not ship or link to any content.</p>
        </div>
        <nav aria-label="Footer">
          <Link href="/features">Features</Link>
          <Link href="/download">Download</Link>
          <Link href="/changelog">What's new</Link>
          <Link href="/support">Support</Link>
          <Link href="/privacy">Privacy</Link>
          <Link href="/terms">Terms</Link>
          <Link href="/licenses">Licenses</Link>
          <a href={site.repo}>GitHub</a>
        </nav>
      </div>
    </footer>
  );
}
