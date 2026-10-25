/**
 * The address the site is served from, for the sitemap and the social-image links. Set SITE_URL when deploying (for example https://streamsetu.example).
 * Without it the local preview address is used; a production build says so, so a localhost address cannot go out unnoticed.
 */
const configured = process.env.SITE_URL?.trim().replace(/\/+$/, "");
const preview = "http://localhost:4300";

if (!configured && process.env.NODE_ENV === "production" && process.env.npm_lifecycle_event === "build") {
  console.warn(`\n⚠ SITE_URL is not set: the sitemap and social image will point at ${preview}. Set it before deploying.\n`);
}

export const origin = configured || preview;
