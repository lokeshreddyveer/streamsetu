/** Everything the screens ask of the app. Inside the app these go to Rust; opened in an ordinary browser (to look at the design) they are answered by stand-ins. */
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

export const inApp = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export const bridge = {
  proxyBase: (): Promise<string> => (inApp ? invoke("proxy_base") : Promise.resolve("http://127.0.0.1:0")),
  fetchText: async (url: string): Promise<string> => {
    if (inApp) return invoke("fetch_text", { url });
    const r = await fetch(url); if (!r.ok) throw new Error(`The server answered ${r.status}.`); return r.text();
  },
  secretSet: (playlistId: string, value: string): Promise<void> => (inApp ? invoke("secret_set", { playlistId, value }) : Promise.resolve(void sessionStorage.setItem("secret:" + playlistId, value))),
  secretGet: (playlistId: string): Promise<string | null> => (inApp ? invoke("secret_get", { playlistId }) : Promise.resolve(sessionStorage.getItem("secret:" + playlistId))),
  secretDelete: (playlistId: string): Promise<void> => (inApp ? invoke("secret_delete", { playlistId }) : Promise.resolve(void sessionStorage.removeItem("secret:" + playlistId))),
  playExternal: (url: string): Promise<string> => (inApp ? invoke("play_external", { url }) : Promise.reject(new Error("Only in the app."))),
  browserOpen: (label: string, url: string, b: Bounds) => (inApp ? invoke("browser_open", { label, url, ...b }) : Promise.resolve()),
  browserBounds: (label: string, b: Bounds) => (inApp ? invoke("browser_bounds", { label, ...b }) : Promise.resolve()),
  browserShow: (label: string, visible: boolean) => (inApp ? invoke("browser_show", { label, visible }) : Promise.resolve()),
  browserClose: (label: string) => (inApp ? invoke("browser_close", { label }) : Promise.resolve()),
  browserNavigate: (label: string, url: string) => (inApp ? invoke("browser_navigate", { label, url }) : Promise.resolve()),
  browserAction: (label: string, action: "back" | "forward" | "reload" | "stop") => (inApp ? invoke("browser_action", { label, action }) : Promise.resolve()),
  onPage: (fn: (e: { label: string; url: string; loading: boolean }) => void) => (inApp ? listen<{ label: string; url: string; loading: boolean }>("browser:page", (e) => fn(e.payload)) : Promise.resolve(() => {})),
  onResize: (fn: () => void) => (inApp ? listen("window:resized", () => fn()) : Promise.resolve(() => {})),
};

export interface Bounds { x: number; y: number; w: number; h: number }
