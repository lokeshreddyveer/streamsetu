# Design system

Dark, cinematic, restrained. Tokens live in `DesignSystem/Theme`.

| Token | Value |
|---|---|
| Background | `#090B10` |
| Sidebar | `#101319` |
| Card | `#171B24` |
| Elevated | `#202633` |
| Text / secondary | `#F6F7FA` / `#98A2B3` |
| Accent (default) | `#EE454A` — user-selectable: Coral, Blue, Green, Violet, Amber |
| Radii | 8 / 12 / 18 pt |
| Sidebar width | 244 pt |
| Spacing | 4 · 8 · 12 · 16 · 20 · 24 · 28 |

Type: system San Francisco. Motion: short ease-out hover/focus (0.12 s), spring for panels; no autoplay previews.

Components: sidebar, poster / landscape / channel cards, shelves, badges (LIVE, quality, count), progress bars, buttons
(primary, secondary, icon, favorite), search field, skeletons and empty states, toasts, artwork image (lazy, cached),
player surface, controls overlay, seek bar, mini-player.

Accessibility: every control has a label/help text, keyboard focus is visible, contrast follows the palette above.
