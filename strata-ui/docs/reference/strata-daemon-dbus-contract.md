# Strata daemon — D-Bus contract (reference)

The contract the greenfield UI speaks. Sourced from `strata-daemon/src/dbus_service.rs`,
`strata@edu4rdshl.dev/dbus.js`, and `ARCHITECTURE.md`.

- **Bus name:** `dev.edu4rdshl.Strata`
- **Object path:** `/dev/edu4rdshl/Strata`
- **Interface:** `dev.edu4rdshl.Strata.Manager`

## Methods

| Method | Args | Returns | Purpose |
|---|---|---|---|
| `SubmitItem` | `mime: s`, `content: ay` | `()` | Ingest raw clipboard bytes (fire-and-forget). Daemon hashes, dedups, thumbnails, prunes. |
| `GetHistory` | `offset: u`, `limit: u` | `s` (JSON `ItemMeta[]`) | Paginated newest-first metadata. Text preview truncated ~200 chars; no image bytes. |
| `SearchHistory` | `query: s`, `limit: u` | `s` (JSON `ItemMeta[]`) | FTS5 prefix search over text only; empty query → `[]`. |
| `GetThumbnail` | `id: s` | `ay` | Pre-decoded ~200px PNG, or empty if none. Lazy, per visible row. |
| `GetItemContent` | `id: s` | `(s, ay)` mime+bytes | Full original content (text as UTF-8 bytes, or full-res image blob). For paste-back. |
| `SetClipboard` | `id: s` | `()` | Write item back to system clipboard. |
| `DeleteItem` | `id: s` | `()` | Delete one item → emits `ItemDeleted`. |
| `ClearHistory` | — | `()` | Wipe all → emits `HistoryCleared`. |
| `SetConfig` | `max_history: u`, `max_text_bytes: u`, `max_image_bytes: u` | `()` | Live limits (0 = unchanged). Prunes immediately. |
| `Shutdown` | — | `()` | Graceful daemon exit. |

## Signals

| Signal | Args | When |
|---|---|---|
| `ItemAdded` | `id: s`, `mime: s`, `preview: s` | After dedup + thumbnail. `preview` empty for images. |
| `ItemDeleted` | `id: s` | Deletion or prune. Unlink cached thumbnail. |
| `HistoryCleared` | — | Whole history wiped. |

## ItemMeta (JSON from GetHistory/SearchHistory)

```json
{ "id": "<uuid-v4>", "mime_type": "text/plain",
  "content_text": "≤200 chars, or null for images",
  "source_app": null, "created_at": 1719432900000, "has_thumbnail": false }
```

## Data model (SQLite, `strata-daemon/src/db.rs`)

`id` (UUID v4) · `mime_type` · `content_text` XOR `content_blob` · `thumbnail_blob` (~200px PNG)
· `content_hash` (blake3, UNIQUE → dedup) · `source_app` (always NULL on GNOME) · `created_at` (unix ms).
FTS5 over `content_text` only.

**Supported MIME:** images png/jpeg/gif/webp/bmp/tiff/ico; text plain/html/rtf/markdown + X11 atoms;
files `text/uri-list` & gnome/kde copied-files. Password-manager hint mimes are dropped.

**Defaults:** max-history 200 (50–2000) · max-text 1 MB · max-image 5 MB.

## Reuse vs gaps for the greenfield UI

**Reuse as-is:** `dbus.js` method signatures · the gschema `org.gnome.shell.extensions.strata`
· thumbnail cache pattern (`~/.cache/strata/thumbnails/<id>.png`) · paste-back logic · signals.

**Gaps (need Rust daemon changes):**
1. **Edit-in-place** — no `UpdateItemContent(id, mime, bytes)`; content is immutable, and the
   UNIQUE `content_hash` index means an edit is effectively a re-hash/re-dedup.
2. **Pinning / tags** — no `pinned`/`tag` columns; no `PinItem`/`TagItem`; `GetHistory` returns neither.
3. **Crisp large image preview** — only the ~200px thumbnail is pre-decoded. The full-res blob is
   available via `GetItemContent`, but decoding it on the shell thread fights design goal #1
   (see architecture-constraints.md). Clean fix: a daemon `GetPreview(id, max_px) -> ay`.
4. Minor: no source-app, no time-range filters, no delta/since-T sync.
