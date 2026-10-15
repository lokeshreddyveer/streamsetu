import type { Metadata } from "next";
import { site } from "@/content/site";
import { downloads, latest, prettyDate } from "@/lib/releases";

export const metadata: Metadata = { title: "Download", description: "Download StreamSetu for Mac, Android, Fire TV and Android TV, or join the iPhone and iPad TestFlight." };

export default function Download() {
  const d = downloads(latest);
  return (
    <main className="wrap page">
      <h1>Download</h1>
      <p className="lead">Release of {prettyDate(latest.date)}. One release holds every app; pick your device.</p>

      <div className="dl-grid">
        <article className="dl">
          <h3>Mac</h3>
          <p className="muted">Version {latest.mac}. Apple silicon and Intel, macOS 14 or later. Signed and notarized by Apple, and it updates itself.</p>
          <a className="button" href={d.mac}>Download for Mac</a>
        </article>
        <article className="dl">
          <h3>iPhone and iPad</h3>
          <p className="muted">Version {latest.ios}, through TestFlight. Open to the first 100 testers.</p>
          <a className="button" href={site.testflight}>Join the TestFlight</a>
        </article>
        <article className="dl">
          <h3>Fire TV and Android TV</h3>
          <p className="muted">Version {latest.android}. Made for the remote. Android 5.1 or later.</p>
          <a className="button" href={d.tv}>Download for TV</a>
        </article>
        <article className="dl">
          <h3>Android phone and tablet</h3>
          <p className="muted">Version {latest.android}. Touch layout. Android 5.1 or later.</p>
          <a className="button" href={d.android}>Download for phone</a>
        </article>
      </div>

      <p className="muted">Windows is coming soon. Every file is signed, and its SHA-256 checksum is on the <a href={d.page}>release page</a>.</p>

      <h2>Installing on an Android phone</h2>
      <ol>
        <li>Download for phone on the phone.</li>
        <li>Open it and, when asked, allow installs from your browser or files app.</li>
        <li>Open StreamSetu.</li>
      </ol>

      <h2>Installing on a Fire TV</h2>
      <ol>
        <li>On the Fire TV open Settings, My Fire TV, Developer options, and turn on Install unknown apps for the app you will download with, for example Downloader.</li>
        <li>Open that app, type the address of the TV file from this page, and install.</li>
        <li>Find StreamSetu in Your Apps and Channels.</li>
      </ol>
      <p className="muted">If you installed an early test build before version 0.5.0, uninstall it first. Those builds were signed with a different key, and Android will not update across keys.</p>

      <h2>Older releases</h2>
      <p>Every earlier release is on the <a href={site.repo + "/releases"}>releases page</a>, and what changed in each is on <a href="/changelog">What's new</a>.</p>
    </main>
  );
}
