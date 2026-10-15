import Link from "next/link";
import { PhoneMockup, TvMockup } from "@/components/Mockup";
import { faq, features, highlights, platforms, sources, site } from "@/content/site";
import { downloads, latest } from "@/lib/releases";

export default function Home() {
  const d = downloads(latest);
  return (
    <main>
      <section className="hero">
        <div className="wrap hero-grid">
          <div>
            <p className="eyebrow">Mac, iPhone, iPad, Android, Fire TV and Android TV</p>
            <h1>Your streams.<br />One home.</h1>
            <p className="lead">StreamSetu plays the IPTV playlists and media servers you already have. Everything stays on your device: no account, no ads, no tracking.</p>
            <div className="actions">
              <Link className="button" href="/download">Download</Link>
              <Link className="button ghost" href="/features">See what it does</Link>
            </div>
            <p className="small muted">Latest: Mac {latest.mac}, Android and Fire TV {latest.android}, iPhone and iPad {latest.ios}. Windows is coming soon.</p>
          </div>
          <div className="hero-art">
            <TvMockup />
            <PhoneMockup />
          </div>
        </div>
      </section>

      <section className="band">
        <div className="wrap cols3">
          {highlights.map((h) => (
            <div key={h.title}>
              <h3>{h.title}</h3>
              <p>{h.text}</p>
            </div>
          ))}
        </div>
      </section>

      <section className="block">
        <div className="wrap">
          <h2>What it does</h2>
          <div className="grid">
            {features.slice(0, 6).map((f) => (
              <article key={f.title} className="card">
                <h3>{f.title}</h3>
                <p>{f.text}</p>
              </article>
            ))}
          </div>
          <p><Link href="/features">All features</Link></p>
        </div>
      </section>

      <section className="block alt">
        <div className="wrap split">
          <div>
            <h2>Bring what you already have</h2>
            <p>If your provider gave you a username, a password and an address, or a link that ends in .m3u, you are ready. StreamSetu reads these:</p>
            <ul className="ticks">
              {sources.map((s) => <li key={s}>{s}</li>)}
            </ul>
          </div>
          <div className="steps">
            <h2>Three steps</h2>
            <ol>
              <li><strong>Install it.</strong> Pick your device on the Download page.</li>
              <li><strong>Add your playlist.</strong> Type the login or paste the link. StreamSetu tests it before saving.</li>
              <li><strong>Watch.</strong> Live TV, movies and series are sorted and searchable in a moment.</li>
            </ol>
          </div>
        </div>
      </section>

      <section className="block">
        <div className="wrap">
          <h2>Get it for your device</h2>
          <div className="grid five">
            {platforms.map((p) => (
              <article key={p.id} className="card tight">
                <h3>{p.name}</h3>
                <p className="muted">{p.detail}</p>
              </article>
            ))}
          </div>
          <p className="actions">
            <a className="button" href={d.mac}>Mac {latest.mac}</a>
            <a className="button ghost" href={site.testflight}>iPhone and iPad on TestFlight</a>
            <Link className="button ghost" href="/download">All downloads</Link>
          </p>
        </div>
      </section>

      <section className="block alt">
        <div className="wrap narrow">
          <h2>Questions</h2>
          {faq.slice(0, 4).map((f) => (
            <details key={f.q}>
              <summary>{f.q}</summary>
              <p>{f.a}</p>
            </details>
          ))}
          <p><Link href="/support">More answers and how to reach me</Link></p>
        </div>
      </section>
    </main>
  );
}
