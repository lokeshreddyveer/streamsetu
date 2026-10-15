// Original artwork for the drawings of the app: a sky, a sun or moon and a few ranges of hills, different for each seed.
const palettes = [
  ["#1b2a4e", "#e8805a", "#f6c15a", "#101a33"],
  ["#0c2d3a", "#19a7b8", "#9be7e0", "#071c25"],
  ["#2a1738", "#b24f8f", "#f2a3b8", "#150b20"],
  ["#10281f", "#3a9b6a", "#d6e8a2", "#08170f"],
  ["#331a14", "#d1622e", "#ffd08a", "#1b0d09"],
  ["#14213d", "#4f7bd8", "#bcd4ff", "#0a1226"],
];

function random(seed: number) {
  let a = seed + 0x6d2b79f5;
  return () => {
    a = Math.imul(a ^ (a >>> 15), a | 1);
    a ^= a + Math.imul(a ^ (a >>> 7), a | 61);
    return ((a ^ (a >>> 14)) >>> 0) / 4294967296;
  };
}

function ridge(rand: () => number, base: number, spread: number) {
  const steps = 7;
  let d = `M0 100 L0 ${base}`;
  for (let i = 1; i <= steps; i++) d += ` L${(i * 100) / steps} ${base - rand() * spread}`;
  return d + " L100 100 Z";
}

export function Art({ seed, className }: { seed: number; className?: string }) {
  const rand = random(seed * 977 + 13);
  const [sky, glow, sun, deep] = palettes[seed % palettes.length];
  const id = `art${seed}`;
  const sunX = 20 + rand() * 60;
  const sunY = 22 + rand() * 20;
  return (
    <svg className={className} viewBox="0 0 100 100" preserveAspectRatio="xMidYMid slice" aria-hidden="true">
      <defs>
        <linearGradient id={`${id}s`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={deep} />
          <stop offset="0.55" stopColor={sky} />
          <stop offset="1" stopColor={glow} />
        </linearGradient>
        <radialGradient id={`${id}g`}>
          <stop offset="0" stopColor={sun} stopOpacity="0.9" />
          <stop offset="1" stopColor={sun} stopOpacity="0" />
        </radialGradient>
      </defs>
      <rect width="100" height="100" fill={`url(#${id}s)`} />
      <circle cx={sunX} cy={sunY} r="26" fill={`url(#${id}g)`} />
      <circle cx={sunX} cy={sunY} r="5.5" fill={sun} />
      <path d={ridge(rand, 70, 22)} fill={glow} opacity="0.55" />
      <path d={ridge(rand, 80, 20)} fill={sky} opacity="0.9" />
      <path d={ridge(rand, 90, 16)} fill={deep} />
    </svg>
  );
}
