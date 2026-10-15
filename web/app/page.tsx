import Link from "next/link";
import { Flow } from "@/components/Flow";
import { PlayerScreen } from "@/components/Devices";
import { Gallery, LaptopFrame, PhoneFrame, TvFrame } from "@/components/Shots";
import { PrivacyMap } from "@/components/PrivacyMap";
import { Reveal } from "@/components/Reveal";
import { SearchDemo } from "@/components/SearchDemo";
import { faq, site, sources } from "@/content/site";
import { downloads, latest } from "@/lib/releases";

const player = [
  { title: "Picture", items: ["Brightness, contrast, saturation and gamma", "Deinterlace, hardware or software decoding", "Fit, fill and zoom", "A resolution picker for streams that offer several"] },
  { title: "Sound", items: ["Volume boost up to 150%", "Even out loud and quiet scenes", "Audio timing in small steps", "Picture and sound timing, together or apart"] },
  { title: "Subtitles", items: ["Size, colour, position and background", "Timing, earlier or later", "From a file, or from OpenSubtitles", "Remembered for each title"] },
];

export default function Home() {
  const d = downloads(latest);
  return (
    <main>
      <section className="hero">
        <svg className="swoosh" viewBox="0 0 1200 500" preserveAspectRatio="none" aria-hidden="true">
          <defs>
            <linearGradient id="sw" x1="0" x2="1">
              <stop offset="0" stopColor="#29c7f2" stopOpacity="0" />
              <stop offset="0.5" stopColor="#29c7f2" />
              <stop offset="1" stopColor="#f2b23c" />
            </linearGradient>
          </defs>
          <path d="M-20 420 C 260 470, 640 380, 1220 90" fill="none" stroke="url(#sw)" strokeWidth="2" />
        </svg>
        <div className="wrap hero-grid">
          <div className="hero-copy">
            <p className="eyebrow">Mac · iPhone · iPad · Android · Fire TV · Android TV</p>
            <h1>Your streams.<br /><span>One home.</span></h1>
            <p className="lead">StreamSetu plays the IPTV playlists and media servers you already have. Everything stays on your device: no account, no ads, no tracking.</p>
            <div className="actions">
              <Link className="button" href="/download">Download</Link>
              <Link className="button ghost" href="/features">What it does</Link>
            </div>
            <p className="fine">Latest: Mac {latest.mac} · Android and Fire TV {latest.android} · iPhone and iPad {latest.ios}. Windows is coming soon.</p>
          </div>
          <div className="stage">
            <TvFrame src="/shots/firetv-home-sidebar.jpg" alt="StreamSetu on a Fire TV: the home screen with the sidebar open" priority />
            <PhoneFrame src="/shots/ios-home.jpg" alt="StreamSetu on an iPhone: the home screen" className="tilt" priority />
          </div>
        </div>
      </section>

      <div className="ticker" aria-label="What it connects to">
        <div className="ticker-track">
          {[...sources, ...sources].map((s, i) => <span key={i}>{s}</span>)}
        </div>
      </div>

      <section className="section">
        <div className="wrap">
          <Reveal className="head">
            <p className="kicker">One library</p>
            <h2>Everything you have, in one place</h2>
            <p>Add as many playlists and servers as you like. StreamSetu shows them as one library, so a film that sits in two of them is one film to you, and you choose which connection plays it.</p>
          </Reveal>
          <Reveal><Flow /></Reveal>
        </div>
      </section>

      <section className="section dark">
        <div className="wrap">
          <Reveal className="head">
            <p className="kicker">The player</p>
            <h2>Made for people who watch a lot</h2>
            <p>Most players stop at pause and volume. This one lets you go to an exact time, skips an opening you have already seen, and remembers what you chose last time.</p>
          </Reveal>
          <Reveal><PlayerScreen /><p className="player-cap">An illustration of the player controls.</p></Reveal>
          <div className="cols3 player-cols">
            {player.map((p, i) => (
              <Reveal key={p.title} delay={i * 80}>
                <h3>{p.title}</h3>
                <ul className="ticks">{p.items.map((it) => <li key={it}>{it}</li>)}</ul>
              </Reveal>
            ))}
          </div>
        </div>
      </section>

      <section className="section">
        <div className="wrap split">
          <Reveal className="head left">
            <p className="kicker">Search</p>
            <h2>Type what you mean</h2>
            <p>One search covers channels, movies, series, episodes and the guide. It reads the way you talk: "hindi movies 2024" gives Hindi films from 2024. A misspelt word is fixed from the titles in your own library, and it all works offline.</p>
            <p>Search is inside the player too, with a menu for All, Movies, Series or Live TV.</p>
          </Reveal>
          <Reveal delay={120}><SearchDemo /></Reveal>
        </div>
      </section>

      <section className="section gal">
        <div className="wrap">
          <Reveal className="head">
            <p className="kicker">See it</p>
            <h2>The same library on every screen</h2>
          </Reveal>
        </div>
        <Reveal><Gallery /></Reveal>
      </section>

      <section className="section dark">
        <div className="wrap split rev">
          <Reveal className="devices">
            <LaptopFrame src="/shots/mac-home.jpg" alt="StreamSetu on a Mac: Discover with a banner and rows of titles" />
            <PhoneFrame src="/shots/android-home.jpg" alt="StreamSetu on an Android phone: the home screen" />
          </Reveal>
          <Reveal className="head left" delay={120}>
            <p className="kicker">Every screen</p>
            <h2>Laid out for the screen in front of you</h2>
            <p>A remote on a television, touch on a phone, a pointer on a Mac. The same library and the same settings idea, but each app is built for how you hold it, not stretched from another.</p>
            <ul className="ticks">
              <li>Lists with sort, edit and remove all, on every device</li>
              <li>Hindi and Telugu as well as English</li>
              <li>Search inside the player, on every device</li>
            </ul>
          </Reveal>
        </div>
      </section>

      <section className="section">
        <div className="wrap">
          <Reveal className="head">
            <p className="kicker">Private by design</p>
            <h2>There is no StreamSetu server</h2>
            <p>The app talks to your provider and to nobody else. Your logins sit in the system's secure storage, and there is nothing to sign up for.</p>
          </Reveal>
          <Reveal><PrivacyMap /></Reveal>
        </div>
      </section>

      <section className="section get">
        <div className="wrap">
          <Reveal className="head">
            <p className="kicker">Download</p>
            <h2>Get it for your device</h2>
          </Reveal>
          <Reveal className="get-grid">
            <a href={d.mac}><strong>Mac</strong><small>Version {latest.mac}</small></a>
            <a href={site.testflight}><strong>iPhone and iPad</strong><small>TestFlight, {latest.ios}</small></a>
            <a href={d.android}><strong>Android</strong><small>Phone and tablet, {latest.android}</small></a>
            <a href={d.tv}><strong>Fire TV</strong><small>And Android TV, {latest.android}</small></a>
            <div className="soon"><strong>Windows</strong><small>Coming soon</small></div>
          </Reveal>
          <p className="fine center"><Link href="/download">Install steps and older versions</Link></p>
        </div>
      </section>

      <section className="section dark">
        <div className="wrap narrow">
          <Reveal className="head left">
            <h2>Questions</h2>
          </Reveal>
          {faq.slice(0, 5).map((f) => (
            <details key={f.q}>
              <summary>{f.q}</summary>
              <p>{f.a}</p>
            </details>
          ))}
          <p className="fine"><Link href="/support">More answers, and how to reach me</Link></p>
        </div>
      </section>
    </main>
  );
}
