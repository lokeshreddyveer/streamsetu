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

export function downloads(r: Release) {
  return {
    mac: `${base(r)}/StreamSetu-${r.mac}.dmg`,
    tv: `${base(r)}/StreamSetu-FireTV-${r.android}.apk`,
    android: `${base(r)}/StreamSetu-Android-${r.android}.apk`,
    page: `${site.repo}/releases/tag/${r.tag}`,
  };
}

export function prettyDate(iso: string) {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });
}
