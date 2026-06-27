# Strata UI — v1 running spec

Living scope doc, updated as we grill. ADRs record the *why* for contested calls; this records the
*what*. See also: [borrow-map](./reference/borrow-map.md),
[architecture-constraints](./reference/architecture-constraints.md),
[D-Bus contract](./reference/strata-daemon-dbus-contract.md).

## What it is

A greenfield GNOME Shell extension that presents the Strata daemon's clipboard history as a
**Quake-style visor**: a hotkey-summoned, full-width, fixed-height horizontal **Shelf** of rich,
readable **Cards**. Borrows plumbing from `strata@edu4rdshl.dev`, rich-card UX from Copyous, the
Quake-summon pattern from Guake, and the readable-band form factor from Paste (macOS) — code from
none of them. (Copyous has unfixable main-loop performance issues; Guake is stuck in X11 — we take
the patterns, not the programs. See [borrow-map](./reference/borrow-map.md).)
Daemon unchanged in v1. (ADR-0001, ADR-0003) Written in plain JS for the MVP, migrating to
TypeScript once it works (ADR-0006).

## Form factor (ADR-0004)

- Full-width visor, fixed height **~360px** (`visor-height` setting; scales with text-scaling).
- Cards: fixed **~300×280px**, **~6 visible on 1080p** (Paste-like), horizontal scroll; `card-width` setting.
- Anchored to the configured **edge**: bottom (default) or top. Appears **instantly** — no slide animation.
- Summon: **Ctrl+Alt+C** (customizable, reuses `keyboard-shortcut` gschema key).
- Dismiss on Escape / paste / focus-loss.

## Card type catalog (v1)

All UI-side interpretations of what the daemon serves (text/image/file). No daemon change.

| Card | Source content | Body |
|---|---|---|
| **Text** | `text/plain` | Wrapped text, several lines visible |
| **Image** | image/* | Thumbnail (`GetThumbnail`, ~200px, cached) |
| **Link** | `text/plain` matching URL | Link-styled, hostname as subtitle (matches Strata today) |
| **File(s)** | uri-list / copied-files | Filename(s) + icon |
| **Color** | `text/plain` matching `#rgb`/`#rrggbb` | **Hex color swatch** (matches Strata's current UI) |

Classification on the shelf is **whatever Strata's current extension does** (ADR-0007): regex for
Link and Color, everything else is Text — no code card. Code entries render as Text on the shelf and
are **syntax-highlighted in Peek**.

## Interactions (v1)

- **Peek** — Space enlarges the focused Card: full text, **syntax-highlighted for code** (ADR-0007);
  full-res image via on-demand `GetItemContent` decode (single image, on keypress — ADR-0003).
- **Search** — v1 ships Strata's existing **FTS5 prefix** search (`SearchHistory`), 150 ms debounce +
  epoch guard. **Fuzzy / typo-tolerant search is deferred to v2** as a daemon feature (ADR-0003).
- **Open state & keyboard model** — opens **search-first** (cursor in the search box):
  - type → filter (`SearchHistory`)
  - `←/→` or `Tab` → move focus into the Shelf and between Cards (scroll-into-view)
  - `Enter` → copy the focused Card (or the top result if focus is still in search) and dismiss —
    no auto-paste (ADR-0005)
  - `Alt+1…9` → quick-select: copy the Nth visible Card and dismiss (Alt-modified so plain digits
    still type into search)
  - `Space` → Peek focused Card · `Esc` → dismiss
- **In-UI settings** — a gear in the visor header opens the extension's prefs window directly
  (`openPreferences()`) — no hunting in the GNOME Extensions app (req #5).

## Settings (gschema)

Reuse Strata's keys (`max-history`, size caps, `theme` auto/light/dark, `excluded-apps`,
`keyboard-shortcut`, `move-activated-to-top`) + new: `visor-edge` (top|bottom, default bottom),
`visor-height` (px), `card-width` (px).

## Deferred to v2 (need daemon changes)

- **Edit-in-place** (Ctrl+E) → `UpdateItemContent`.
- **Crisp big-image Peek** → daemon `GetPreview(id, max_px)`.
- **Pins** → `pinned` column + `PinItem`; v1 leaves only a model seam.
- **Fuzzy search** → Rust fuzzy matcher over `content_text` (off-thread); v1 uses FTS5 prefix.

## Explicitly out of scope

- **Tags** (unused — ADR-0003).
- **Auto-paste** (user disables it everywhere — ADR-0005).

## Open questions (grill queue)

_None — the MVP spec is complete. Remaining work is implementation: scaffold the extension, then build._
