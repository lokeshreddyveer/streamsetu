// Copies the release notes of a version into the site and records its version numbers.
// Run by Scripts/release.sh after a release:
//   node scripts/sync-releases.mjs --tag 2026.10.15 --mac 2.5.0 --android 0.10.0 --ios 0.6.0
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, "..");
const notesDir = path.join(root, "..", "docs", "releases");
const outDir = path.join(root, "content", "releases");
const indexFile = path.join(root, "content", "releases.json");

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, a, i, all) => (a.startsWith("--") ? [...pairs, [a.slice(2), all[i + 1]]] : pairs), []));
const index = fs.existsSync(indexFile) ? JSON.parse(fs.readFileSync(indexFile, "utf8")) : { releases: [] };

function entryFor(tag, versions) {
  const text = fs.readFileSync(path.join(notesDir, `${tag}.md`), "utf8");
  const lines = text.split("\n");
  const title = (lines.find((l) => l.startsWith("# ")) ?? `# ${tag}`).slice(2).trim();
  const summary = (lines.find((l) => l.startsWith("- ")) ?? "").slice(2).trim();
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, `${tag}.md`), text);
  const [y, m, d] = tag.split(".").map(Number);
  return { tag, title, summary, date: new Date(Date.UTC(y, m - 1, d)).toISOString().slice(0, 10), ...versions };
}

if (args.tag) {
  if (!args.mac || !args.android || !args.ios) {
    console.error("Give --mac, --android and --ios as well as --tag.");
    process.exit(1);
  }
  const entry = entryFor(args.tag, { mac: args.mac, android: args.android, ios: args.ios });
  // The list is newest first, in the order releases were made: a tag is not a reliable date when two releases share a day.
  const at = index.releases.findIndex((r) => r.tag === args.tag);
  if (at >= 0) index.releases[at] = entry;
  else index.releases = [entry, ...index.releases];
  fs.writeFileSync(indexFile, JSON.stringify(index, null, 2) + "\n");
  console.log(`Site updated for ${args.tag}`);
} else {
  for (const r of index.releases) entryFor(r.tag, {});
  console.log(`Refreshed notes for ${index.releases.length} releases`);
}
