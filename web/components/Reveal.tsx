"use client";
import { useEffect, useRef, useState } from "react";

// Blocks below the fold fade in as they scroll into view. Everything is visible to start with, so nothing is lost if this never runs.
export function Reveal({ children, className = "", delay = 0 }: { children: React.ReactNode; className?: string; delay?: number }) {
  const ref = useRef<HTMLDivElement>(null);
  const [state, setState] = useState<"shown" | "waiting" | "seen">("shown");

  useEffect(() => {
    const el = ref.current;
    if (!el || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    if (el.getBoundingClientRect().top < window.innerHeight * 0.9) return;
    setState("waiting");
    const watcher = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) { setState("seen"); watcher.disconnect(); }
    }, { threshold: 0.12 });
    watcher.observe(el);
    return () => watcher.disconnect();
  }, []);

  return (
    <div ref={ref} className={`reveal ${state} ${className}`} style={{ transitionDelay: state === "seen" ? `${delay}ms` : "0ms" }}>
      {children}
    </div>
  );
}
