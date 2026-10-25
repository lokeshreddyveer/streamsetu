import type { MetadataRoute } from "next";
import { origin } from "@/lib/origin";

const pages = ["", "/features", "/download", "/changelog", "/support", "/privacy", "/terms", "/licenses"];

export default function sitemap(): MetadataRoute.Sitemap {
  return pages.map((p) => ({ url: `${origin}${p}` }));
}
