# Strata UI

A horizontal "shelf" front-end for the Strata clipboard daemon: an alternative GNOME Shell extension that renders clipboard history as a strip of rich, readable cards (Copyous / Paste-for-Mac style) instead of Strata's vertical dropdown. It speaks to theexisting Strata daemon over D-Bus and ships as its own extension.



## Language

**Shelf**:
The horizontal, screen-edge-anchored strip of Cards that is Strata UI's primary surface; scrolls left/right.
*Avoid*: bar, dock, tray, panel, drawer

**Card**:
A single Entry rendered as a fixed-width tile in the Shelf, with a type-specific body.
*Avoid*: row, item, tile, cell

**Entry**:
One clipboard-history record owned by the Daemon — a UUID plus a MIME type, content (text or blob), an optional Thumbnail, and a creation time.
*Avoid*: clip, snippet, record, history item

**Peek**:
The large, transient full-content preview of the focused Card, summoned with Space — full text for text/code, full-resolution image for images.
*Avoid*: quick look, quicklook, preview, zoom, lightbox, expand

**Daemon**:
The Strata Rust backend process (`dev.edu4rdshl.Strata`) that owns capture, storage, search, and thumbnailing. Strata UI is a pure client — "Rust thinks, JS draws."
*Avoid*: backend, server, service, core

**Thumbnail**:
The ~200px PNG the Daemon pre-generates for an image Entry (`GetThumbnail`). Distinct from Full Content.
*Avoid*: preview image, icon

**Full content**:
An Entry's original bytes, fetched on demand from the Daemon (`GetItemContent`) — the full text or full-resolution image. What a Peek shows.
*Avoid*: payload, raw, original
