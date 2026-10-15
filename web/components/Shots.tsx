import Image from "next/image";

// The real app screenshots, in simple device frames.
type Shot = { src: string; alt: string };

export function TvFrame({ src, alt, priority = false }: Shot & { priority?: boolean }) {
  return (
    <div className="f-tv">
      <div className="f-tv-glass"><Image src={src} alt={alt} width={1600} height={900} sizes="(max-width: 980px) 92vw, 640px" priority={priority} /></div>
      <div className="f-tv-foot" />
    </div>
  );
}

export function LaptopFrame({ src, alt }: Shot) {
  return (
    <div className="f-laptop">
      <div className="f-laptop-lid"><Image src={src} alt={alt} width={1600} height={867} sizes="(max-width: 980px) 92vw, 560px" /></div>
      <div className="f-laptop-base" />
    </div>
  );
}

export function PhoneFrame({ src, alt, className = "", priority = false }: Shot & { className?: string; priority?: boolean }) {
  return (
    <div className={`f-phone ${className}`}>
      <div className="f-phone-glass"><Image src={src} alt={alt} width={640} height={1378} sizes="260px" priority={priority} /></div>
    </div>
  );
}

const gallery: (Shot & { label: string; kind: "tv" | "mac" | "phone" })[] = [
  { src: "/shots/mac-movies.jpg", alt: "Movies on a Mac, with folders and a poster grid", label: "Mac · Movies", kind: "mac" },
  { src: "/shots/firetv-live-channels.jpg", alt: "Live TV on a Fire TV, with folders, channels and a live preview", label: "Fire TV · Live TV", kind: "tv" },
  { src: "/shots/ios-series.jpg", alt: "Series on an iPhone", label: "iPhone · Series", kind: "phone" },
  { src: "/shots/mac-live.jpg", alt: "Live TV on a Mac with channel groups and a player", label: "Mac · Live TV", kind: "mac" },
  { src: "/shots/android-movies.jpg", alt: "Movies on an Android phone", label: "Android · Movies", kind: "phone" },
  { src: "/shots/firetv-movies.jpg", alt: "Movies on a Fire TV", label: "Fire TV · Movies", kind: "tv" },
  { src: "/shots/ios-live.jpg", alt: "Live TV on an iPhone", label: "iPhone · Live TV", kind: "phone" },
  { src: "/shots/mac-series.jpg", alt: "Series on a Mac", label: "Mac · Series", kind: "mac" },
  { src: "/shots/firetv-series.jpg", alt: "Series on a Fire TV with a featured banner", label: "Fire TV · Series", kind: "tv" },
  { src: "/shots/android-live.jpg", alt: "Live TV on an Android phone", label: "Android · Live TV", kind: "phone" },
];

export function Gallery() {
  return (
    <div className="gallery" tabIndex={0} aria-label="Screenshots, scroll sideways">
      {gallery.map((g) => (
        <figure key={g.src} className={`g-${g.kind}`}>
          <Image src={g.src} alt={g.alt} width={g.kind === "phone" ? 640 : 1600} height={g.kind === "phone" ? 1378 : g.kind === "mac" ? 867 : 900} sizes="(max-width: 700px) 80vw, 560px" />
          <figcaption>{g.label}</figcaption>
        </figure>
      ))}
    </div>
  );
}
