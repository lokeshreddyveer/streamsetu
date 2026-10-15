import "./globals.css";
import type { Metadata, Viewport } from "next";
import { Header } from "@/components/Header";
import { Footer } from "@/components/Footer";
import { site } from "@/content/site";

export const metadata: Metadata = {
  metadataBase: new URL("http://localhost:4300"),
  title: { default: `${site.name}: ${site.tagline}`, template: `%s · ${site.name}` },
  description: site.description,
  openGraph: { title: `${site.name}: ${site.tagline}`, description: site.description, images: ["/img/social.png"], type: "website" },
};

export const viewport: Viewport = { themeColor: "#0b0e14" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <a className="skip" href="#content">Skip to the content</a>
        <Header />
        <div id="content">{children}</div>
        <Footer />
      </body>
    </html>
  );
}
