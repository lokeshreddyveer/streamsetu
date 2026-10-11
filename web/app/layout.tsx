import "./globals.css";
import type { Metadata } from "next";

export const metadata: Metadata = { title: "Reddy Stream IPTV", description: "A clean player for your own IPTV playlists." };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (<html lang="en"><body>{children}</body></html>);
}
