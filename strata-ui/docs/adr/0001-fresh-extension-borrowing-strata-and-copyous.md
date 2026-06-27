# 0001 — A fresh extension that borrows Strata's plumbing and Copyous's UX

Strata UI is built as its own GNOME Shell extension — not by forking Copyous, and not by
editing Strata's vertical panel in place. It borrows **heavily from `strata@edu4rdshl.dev`**
for the parts that are already right (the `dbus.js` client, daemon supervision, lazy
pagination, thumbnail caching, paste-back, and the GSettings schema — "the right database
etc.") and takes **only UX patterns** from Copyous (horizontal shelf, per-type rich cards,
keyboard-first navigation) — not its code and not its architecture.

## Why

- Strata's extension already speaks the daemon's D-Bus contract correctly and offloads all
  heavy work to the Rust daemon. Re-deriving that plumbing would be wasted effort and a bug
  source.
- Copyous has the UX we want but stutters: capture, hashing, image decode, syntax
  highlighting, search, and JSON persistence all run on the GNOME Shell main loop, and it
  renders every card eagerly with no virtualization. Forking it inherits that.
- A separate extension (own UUID) preserves design freedom and keeps the maintainer's
  preferred path open: prove the UI standalone first, upstream later.

## Consequences

- We re-implement the presentation layer (Shelf, Card renderers, Peek) from scratch; we do
  not re-implement daemon integration.
- The daemon's current contract gates a couple of wanted features — edit-in-place and true
  pinning are not in the daemon today (tracked as a separate scope decision).
