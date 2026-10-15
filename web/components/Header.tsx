import Image from "next/image";
import Link from "next/link";

const links = [
  { href: "/features", label: "Features" },
  { href: "/download", label: "Download" },
  { href: "/changelog", label: "What's new" },
  { href: "/support", label: "Support" },
];

export function Header() {
  return (
    <header className="top">
      <div className="wrap top-row">
        <Link href="/" className="brand" aria-label="StreamSetu home">
          <Image src="/img/icon.png" alt="" width={36} height={36} priority />
          <span>Stream<b>Setu</b></span>
        </Link>
        <nav aria-label="Main">
          {links.map((l) => <Link key={l.href} href={l.href}>{l.label}</Link>)}
        </nav>
      </div>
    </header>
  );
}
