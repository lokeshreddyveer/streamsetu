import fs from "node:fs";
import path from "node:path";
import { Markdown } from "@/lib/markdown";

// The privacy policy, terms and licences are written once in ../legal and copied into content/legal by legal/sync-legal.py.
export type LegalName = "privacy" | "terms" | "licenses";

export function LegalDocument({ name }: { name: LegalName }) {
  const text = fs.readFileSync(path.join(process.cwd(), "content", "legal", `${name}.md`), "utf8");
  return (
    <main className="wrap prose narrow">
      <Markdown source={text} />
    </main>
  );
}
