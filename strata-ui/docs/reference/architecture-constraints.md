# Architecture constraints the greenfield UI must honor

Distilled from Strata's `ARCHITECTURE.md` and the post
[Rethinking the GNOME clipboard issues](https://edu4rdshl.dev/posts/rethinking-the-gnome-clipboard-issues/).

**The one rule:** never block the GNOME Shell main loop. GJS is single-threaded and that thread
*is* the compositor — "every millisecond of [heavy work] is a millisecond the compositor is
frozen." Copyous stutters because hashing, image decode, highlighting, search, persistence, and
rendering all happen there. Strata's answer: **"Rust thinks, JS draws."** Our UI must stay on the
"draws" side.

## Hard invariants to replicate (proven in `strata@edu4rdshl.dev`)

- **Fire-and-forget ingest** — never `await` in the clipboard hot path; `SubmitItem` and return.
- **Lazy pagination** — `GetHistory(offset, limit)` with `page-size` (default 50); fetch the next
  page only when scroll nears the end. The full table never sits in JS memory.
- **On-demand thumbnails** — fetch `GetThumbnail(id)` per *visible* card; cache to
  `~/.cache/strata/thumbnails/<id>.png`; unlink on `ItemDeleted`. Never decode full-res images for cards.
- **Paced rendering** — batch DOM inserts via `GLib.idle_add` in chunks (~20) so a big page can't
  freeze a frame. (This is the virtualization Copyous lacks.)
- **Debounced search** — 150 ms debounce + an epoch counter so stale responses never paint over a newer query.
- **St.Label only** — no `set_markup`; clipboard content must never be parsed as Pango markup.
- **No execution of clipboard content** — no `spawn`, `launch_uri`, or `show_uri`.
- **Paste-back** — `St.Clipboard.set_text` for text; `Meta.SelectionSourceMemory.new` + `set_owner` for binary.
- **Daemon lifecycle** — reuse the spawn + exponential-backoff watchdog + `GetNameOwner` single-instance
  check (so a systemd-managed daemon is reused, not double-spawned).
- **Theming** — dark base `stylesheet.css` + `light.css` overrides scoped under a `.strata-theme-light`
  ancestor class; switch is one class toggle; load `light.css` once.

## Where our requirements collide with the rule

- **Big-image Peek (req #3):** `GetItemContent` returns the full-res blob, but decoding a multi-MB
  image on the shell thread is exactly the freeze we're escaping. For a *single* image on Space the
  one-off hitch may be tolerable for v1; the architecturally-clean answer is a daemon
  `GetPreview(id, max_px)` that decodes/resizes in Rust. **Open decision.**
- **Edit-in-place (req #4):** content is immutable in the daemon; needs a new Rust method
  (`UpdateItemContent`) plus re-hash/re-dedup handling. **Daemon change.**

## Confirmed: alternative front-ends are explicitly supported

The daemon is desktop-agnostic; the D-Bus interface *is* the contract (ARCHITECTURE.md
§"Non-GNOME front-end"). It even ships a `wl-clipboard-rs` monitor for wlroots compositors — not
used on GNOME (Mutter doesn't expose `data-control`), but it means the daemon can run standalone.
