import fs from "node:fs";
import path from "node:path";
import index from "@/content/releases.json";
import { site } from "@/content/site";

export type Release = {
  tag: string;
  title: string;
  summary: string;
  date: string;
  mac: string;
  android: string;
  ios: string;
};

export const releases: Release[] = index.releases;
export const latest = releases[0];

export function notesFor(tag: string) {
  return fs.readFileSync(path.join(process.cwd(), "content", "releases", `${tag}.md`), "utf8");
}

const base = (r: Release) => `${site.repo}/releases/download/${r.tag}`;

/** The television file is streamsetu-tv-<version>.apk from 0.20.0; earlier releases keep the name they were published with. */
function tvFile(r: Release) {
  const [major, minor] = r.android.split(".").map((n) => parseInt(n, 10) || 0);
  return major > 0 || minor >= 20 ? `streamsetu-tv-${r.android}.apk` : `StreamSetu-FireTV-${r.android}.apk`;
}

/** From Mac 2.19.1 a release has two disk images (Apple silicon and Intel) and no universal one; earlier releases have the one file they were published with. */
function twoMacFiles(version: string) {
  const [a, b, c] = version.split(".").map((n) => parseInt(n, 10) || 0);
  return a > 2 || (a === 2 && (b > 19 || (b === 19 && c >= 1)));
}

export function downloads(r: Release) {
  const split = twoMacFiles(r.mac);
  return {
    mac: split ? `${base(r)}/StreamSetu-${r.mac}-AppleSilicon.dmg` : `${base(r)}/StreamSetu-${r.mac}.dmg`,
    macAppleSilicon: `${base(r)}/StreamSetu-${r.mac}-AppleSilicon.dmg`,
    macIntel: `${base(r)}/StreamSetu-${r.mac}-Intel.dmg`,
    macSplit: split,
    tv: `${base(r)}/${tvFile(r)}`,
    android: `${base(r)}/StreamSetu-Android-${r.android}.apk`,
    page: `${site.repo}/releases/tag/${r.tag}`,
  };
}

export function prettyDate(iso: string) {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });
}
