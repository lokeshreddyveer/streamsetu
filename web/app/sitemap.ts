import type { MetadataRoute } from "next";

const pages = ["", "/features", "/download", "/changelog", "/support", "/privacy", "/terms", "/licenses"];

export default function sitemap(): MetadataRoute.Sitemap {
  return pages.map((p) => ({ url: `http://localhost:4300${p}` }));
}
