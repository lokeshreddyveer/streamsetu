import "./globals.css";
import type { Metadata, Viewport } from "next";
import { Sora } from "next/font/google";
import { Header } from "@/components/Header";
import { Footer } from "@/components/Footer";
import { site } from "@/content/site";

const display = Sora({ subsets: ["latin"], weight: ["500", "600", "700"], variable: "--display", display: "swap" });

export const metadata: Metadata = {
  metadataBase: new URL("http://localhost:4300"),
  title: { default: `${site.name}: ${site.tagline}`, template: `%s · ${site.name}` },
  description: site.description,
  openGraph: { title: `${site.name}: ${site.tagline}`, description: site.description, images: ["/img/social.jpg"], type: "website" },
};

export const viewport: Viewport = { themeColor: "#050810" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={display.variable}>
      <body>
        <a className="skip-link" href="#content">Skip to the content</a>
        <Header />
        <div id="content">{children}</div>
        <Footer />
      </body>
    </html>
  );
}
