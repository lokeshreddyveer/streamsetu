import Hls from "hls.js";
import mpegts from "mpegts.js";

/** How an address is played in the page. Chromium (WebView2) plays MP4 and WebM itself; HLS and MPEG-TS need a small player library; anything else goes to an installed player. */
export type Way = "hls" | "ts" | "native" | "external";

export function wayToPlay(url: string, live: boolean): Way {
  const path = url.split(/[?#]/)[0].toLowerCase();
  if (path.endsWith(".m3u8")) return "hls";
  if (path.endsWith(".ts") || path.endsWith(".m2ts")) return "ts";
  if (/\.(mp4|m4v|webm|mov|mkv)$/.test(path)) return "native";
  if (/\.(avi|wmv|flv|mpg|mpeg|vob|divx)$/.test(path)) return "external";
  return live ? "hls" : "native";
}

export interface Playing { stop(): void }

/** Starts `url` on the video element, through the local proxy (which lets the page read the stream). Resolves when it has been set up; errors are reported to `onError`. */
export function start(video: HTMLVideoElement, url: string, way: Way, proxyBase: string, startAt: number, onError: (message: string) => void): Playing {
  const via = `${proxyBase}/p?u=${encodeURIComponent(url)}`;
  if (way === "hls" && Hls.isSupported()) {
    const hls = new Hls({ maxBufferLength: 30, liveSyncDurationCount: 3, enableWorker: true });
    hls.on(Hls.Events.ERROR, (_e, data) => {
      if (!data.fatal) return;
      if (data.type === Hls.ErrorTypes.NETWORK_ERROR) hls.startLoad();
      else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) hls.recoverMediaError();
      else { onError("This stream could not be played."); hls.destroy(); }
    });
    hls.loadSource(via); hls.attachMedia(video);
    if (startAt > 0) video.addEventListener("loadedmetadata", () => { video.currentTime = startAt; }, { once: true });
    void video.play().catch(() => {});
    return { stop: () => hls.destroy() };
  }
  if (way === "ts" && mpegts.getFeatureList().mseLivePlayback) {
    const player = mpegts.createPlayer({ type: "mpegts", isLive: true, url: via }, { enableWorker: true, liveBufferLatencyChasing: true });
    player.on(mpegts.Events.ERROR, () => onError("This stream could not be played."));
    player.attachMediaElement(video); player.load(); void player.play();
    return { stop: () => { player.pause(); player.unload(); player.detachMediaElement(); player.destroy(); } };
  }
  video.src = via;
  video.addEventListener("error", () => onError("This format could not be played here."), { once: true });
  if (startAt > 0) video.addEventListener("loadedmetadata", () => { video.currentTime = startAt; }, { once: true });
  void video.play().catch(() => {});
  return { stop: () => { video.removeAttribute("src"); video.load(); } };
}
