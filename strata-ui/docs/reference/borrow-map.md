# Borrow map: Strata's extension vs Copyous

Strata UI is greenfield, but it doesn't start from zero. It lifts the *plumbing* from
Strata's own extension (`strata@edu4rdshl.dev`) — which already integrates the daemon
correctly — and lifts *UX patterns* from Copyous, without its code or its main-loop
architecture.

Detailed source analyses: [copyous-analysis.md](./copyous-analysis.md),
[strata-daemon-dbus-contract.md](./strata-daemon-dbus-contract.md).

## Take from `strata@edu4rdshl.dev` (the plumbing — "the right database etc.")

| What | Why it's already right |
|---|---|
| `dbus.js` client (proxy over `dev.edu4rdshl.Strata.Manager`) | Speaks the daemon contract exactly; reuse method-for-method |
| Daemon supervision (spawn + exponential-backoff watchdog) | Proven lifecycle; one daemon at a time |
| Lazy pagination (`GetHistory(offset,limit)`, fetch-more-on-scroll, `idle_add` batched render) | Stays responsive with thousands of items |
| Thumbnail caching (session `Map` + `~/.cache/strata/thumbnails/{id}.png`) | Avoids refetching/decoding |
| Paste-back (`GetItemContent` → `SetClipboard`, text vs binary handling) | Correct clipboard semantics on Wayland |
| GSettings schema `org.gnome.shell.extensions.strata` | Same prefs (size limits, position, theme, exclusions) |
| Signals (`ItemAdded` / `ItemDeleted` / `HistoryCleared`) | Live updates |

## Take from Copyous (UX patterns only — not code, not backend)

| What | Source of value |
|---|---|
| Horizontal shelf of fixed-width cards | The core ask: readable contents, scan left-right |
| Per-type rich card renderers (text, code w/ highlight, image, link w/ favicon+title, color swatch, file) | Each type gets a purpose-built body |
| Keyboard-first nav (Home/End, arrows, scroll-into-view, type/tag filters) | Fast, mouse-optional |
| Pins + colored tags for lightweight organization | Manual curation without folders |
| Collapsible / auto-hiding header | Maximizes card space |

## Explicitly DON'T take from Copyous

- Eager, non-virtualized rendering (renders every card → stutter).
- Single-threaded backend (capture, hash, decode, highlight, search, JSON persistence all on
  the shell main loop). Strata's daemon already does this in Rust, off the compositor.

## Work-split: the five requirements vs the daemon contract

| # | Requirement | UI-only? | Daemon (Rust) change needed? |
|---|---|---|---|
| 1 | Horizontal shelf, readable cards | yes | none |
| 2 | Space → Peek full text/content | yes | none — `GetItemContent` exists |
| 3 | Space → big full-res image | yes* | *works via `GetItemContent`, but decoding full-res on the shell thread fights "never block the main loop"; clean fix is a daemon `GetPreview(id, max_px)` — see architecture-constraints.md |
| 4 | Ctrl+E → edit an entry's content | no | **yes** — no `UpdateItemContent`; content is immutable |
| 5 | In-UI settings (no separate app) | yes | none — read/write the same gschema |

Scope note (ADR-0003): **tags are dropped** (unused). **Pins** are a possible v2 only — they'd
need a daemon change (no `pinned` column, no `PinItem` method); v1 leaves only a model seam.

So ~4 of 5 requirements are pure front-end. Edit-in-place (and an optional future pin) are the
only things that reach into the Rust daemon.
