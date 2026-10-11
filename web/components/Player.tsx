"use client";
import { useEffect, useRef, useState } from "react";

export default function Player({ url }: { url: string }) {
  const ref = useRef<HTMLVideoElement>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    const video = ref.current;
    if (!video) return;
    let cleanup = () => {};
    let cancelled = false;
    setErr(null);
    const path = url.split("?")[0].toLowerCase();

    (async () => {
      try {
        if (path.endsWith(".m3u8") || path.includes("/hls")) {
          if (video.canPlayType("application/vnd.apple.mpegurl")) {
            video.src = url;
          } else {
            const Hls = (await import("hls.js")).default;
            if (cancelled) return;
            if (!Hls.isSupported()) throw new Error("HLS not supported in this browser");
            const hls = new Hls();
            hls.on(Hls.Events.ERROR, (_, d) => { if (d.fatal) setErr(`Stream error: ${d.details}`); });
            hls.loadSource(url);
            hls.attachMedia(video);
            cleanup = () => hls.destroy();
          }
        } else if (path.endsWith(".ts") || /\/live\//.test(path)) {
          const mpegts = (await import("mpegts.js")).default;
          if (cancelled) return;
          if (!mpegts.isSupported()) throw new Error("MPEG-TS not supported in this browser");
          const p = mpegts.createPlayer({ type: "mpegts", isLive: true, url: `/api/stream?url=${encodeURIComponent(url)}` });
          p.attachMediaElement(video);
          p.load();
          p.on(mpegts.Events.ERROR, (_t: string, d: string) => setErr(`Stream error: ${d}`));
          cleanup = () => p.destroy();
        } else {
          video.src = url;
        }
        video.play().catch(() => {});
      } catch (e) {
        setErr((e as Error).message);
      }
    })();

    return () => { cancelled = true; cleanup(); video.removeAttribute("src"); video.load(); };
  }, [url]);

  return (
    <div className="player">
      <video ref={ref} controls autoPlay playsInline onError={() => setErr("Unable to play this stream (codec, CORS or mixed-content block).")} />
      {err && <div className="player-err">{err}</div>}
    </div>
  );
}
