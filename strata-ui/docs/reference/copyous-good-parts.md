# Copyous — the good parts (UX reference)

Distilled from `~/projects/copyous` (TypeScript → GJS GNOME Shell extension). We borrow
*patterns*, not code or backend. Full daemon-vs-Copyous synthesis: [borrow-map.md](./borrow-map.md).

## Patterns worth adopting

1. **Horizontal shelf** — `St.BoxLayout` with `Clutter.Orientation.HORIZONTAL`, fixed-width cards,
   smooth scroll-into-view on focus. (`src/lib/ui/clipboardScrollView.ts`)
2. **Per-type card renderers** — 8 item types (Text, Code, Image, File, Files, Link, Character,
   Color), each with a purpose-built body: code gets highlight.js + line numbers; links fetch
   favicon/title/description; colors render a swatch with auto contrast text. (`src/lib/ui/items/*`)
3. **Reactive entries as `GObject.Object`** — properties + signals give data-binding for free.
4. **Pins + 9 colored tags** — single tag per entry; protection flags block deleting pinned/tagged
   items; filter by tag. (`src/lib/database/database.ts`, `components/tagsItem.ts`)
5. **Filter affordances** — search popup with number keys 1–9 (tags) and Alt+letter (types).
6. **Keyboard-first nav** — Home/End jump, arrows traverse with scroll-into-view, Enter activates.
7. **Collapsible / auto-hiding header** — maximizes card space.
8. **Config-driven card size** with optional content-aware height.

## Keyboard shortcuts (current Copyous)

| Key | Action |
|---|---|
| Ctrl+Alt+V | Toggle the clipboard popup (global) |
| Ctrl+Alt+C | Toggle incognito (pause capture) |
| Home / End | First / last item |
| ← / → | Traverse items / tag bar |
| 1–9 | Filter by tag (in search popup) |
| Alt+letter | Filter by type mnemonic |
| Enter | Activate (copy) focused/first item |

Configurable per-item shortcuts exist for **pin**, **delete**, and **edit** (wired through
`ShortcutManager`), but there is **no Space-to-enlarge Peek** and **no full-screen preview** — that
is net-new for us. Settings are reachable only via the external prefs dialog (in-UI settings is also
net-new — req #5).

## Anti-patterns to avoid (the reason Copyous stutters)

- **Eager rendering** of every card, no virtualization → O(n) on the compositor.
- **Single-threaded heavy work** on the shell main loop: blake3-ish hashing, image decode,
  highlight.js, FTS-less O(n) search, synchronous JSON persistence. Strata's daemon already does all
  of this in Rust, off the compositor — which is the entire point of building on it.
