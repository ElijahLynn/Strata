# 0003 — v1 is UI-only; daemon changes deferred to v2

v1 of Strata UI ships against the Strata daemon's current D-Bus contract with **no changes to
`strata-daemon/`**. The features that would require Rust/daemon work — edit-in-place (Ctrl+E,
needs `UpdateItemContent`), crisp large-image Peek (needs `GetPreview(id, max_px)`), and pins/tags
(needs schema + methods) — are deferred to v2.

## Why

- Fastest path to a daily-driver — exactly what the upstream maintainer asked to see before
  considering anything deeper (Edu4rdSHL/Strata#3).
- ~80% of the value (readable horizontal Shelf, rich Cards, text Peek, in-UI settings, keyboard
  nav) needs no daemon change.
- Keeps the fork conflict-free with upstream: only `strata-ui/` is touched, so `git pull upstream`
  stays clean.
- Deferred daemon work then bundles into one clean, well-motivated PR — far easier to upstream when
  a working UI demonstrably needs it.

## Consequences

- Big-image Peek in v1 uses a single on-demand `GetItemContent` decode on Space (one image, on
  keypress — acceptable, unlike Copyous decoding all images eagerly). Graduates to a daemon
  `GetPreview` endpoint in v2.
- **Tags are out of scope** — the user doesn't use them; no tag concept is carried in the Card
  model, Entry view-model, or settings.
- **Pins** are a possible v2. The Card model leaves a lightweight seam for a single `pinned` flag so
  v2 doesn't force a restructure, but no pin UI ships in v1.
- **Fuzzy search** is deferred to v2 as a daemon feature (Rust fuzzy matcher over `content_text`,
  off-thread). v1 ships Strata's existing FTS5 *prefix* search. Client-side JS fuzzy was rejected: it
  would pull the whole history into the shell and score it on the main loop.
