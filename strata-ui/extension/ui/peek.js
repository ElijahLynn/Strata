/* peek.js — the Peek overlay: Space enlarges the focused Card.
 *
 * Feature 006. Peek is the single place where we do the "expensive, on demand"
 * work the shelf deliberately avoids (ADR-0007 / ADR-0003): one entry, on a
 * keypress, off the per-card hot path —
 *
 *   - text/code: fetch the FULL content (GetItemContent — the shelf only has the
 *     ~200-char preview) and show it large; code is syntax-highlighted via Pango
 *     foreground attributes on the St.Label's clutter_text. The content is set as
 *     plain text and coloured out-of-band: never set_markup, so a copied string
 *     can't be interpreted as markup (reference/architecture-constraints.md).
 *   - image: fetch the full-resolution blob (GetItemContent) and decode it
 *     IN-PROCESS — one image, on keypress.
 *
 * Image decode (033): the bytes are decoded straight from the in-memory blob with
 * GdkPixbuf.new_from_stream over a Gio.MemoryInputStream and uploaded to an
 * St.ImageContent (a Clutter.Content) set on the image actor. There is NO temp
 * file, NO temp-file URL, and NO CSS background image — so the slow path 006/030
 * took is gone: the old code wrote the bytes to a temp file and pointed a CSS
 * background image at that on-disk file URL, which on GNOME routes through
 * St.TextureCache's file loader + the glycin sandbox (a cold bwrap subprocess spin
 * up per decode ≈ the ~2s black "Loading…", and the heavy glycin-backed GL texture
 * was also slow to tear down ≈ the ~1s Escape). The in-process content decodes in
 * tens of ms, is CACHED per item id, can be PRE-FETCHED for the focused card in the
 * background (so the common peek is instant), and is released on dismiss by simply
 * dropping the actor's content reference — a cheap pointer swap, no glycin teardown.
 *
 * Layering (030): the dim/scrim is its OWN actor (the bottom child of the overlay),
 * with the text/image/loading views as later siblings ABOVE it — so the
 * full-resolution image renders at FULL brightness, never under the scrim. While the
 * content is fetched/decoded a lightweight loading state shows instead of a dark
 * blank, and close() tears the overlay down synchronously.
 *
 * Space again, Escape, or a click dismiss back to the shelf.
 */

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import GdkPixbuf from 'gi://GdkPixbuf';
import Clutter from 'gi://Clutter';
import Cogl from 'gi://Cogl';
import Pango from 'gi://Pango';
import St from 'gi://St';

import { highlight } from '../lib/highlight.js';

// Token type → foreground colour (One-Dark-ish). null = inherit the default fg.
const THEME = {
    keyword: '#c678dd',
    string: '#98c379',
    comment: '#7f848e',
    number: '#d19a66',
    op: '#56b6c2',
    name: null,
    other: null,
    ws: null,
};

// A single entry can be up to max-text (1 MB). Tokenising and laying that out on
// the main loop — even one-off — would still jank, so cap what we render/colour.
// (The clipboard, and the daemon, still hold the full content.)
const DISPLAY_CAP = 100000;

// Bound the decoded-image cache so memory can't grow without limit. Peeks are
// one-at-a-time and the win is a warm focused card + recent re-peeks; a handful of
// full-res textures is plenty. Oldest entry is evicted past the cap.
const IMAGE_CACHE_CAP = 8;

const _enc = new TextEncoder();

export class Peek {
    constructor(host, opts = {}) {
        this._host = host;                      // actor we overlay (the visor)
        this._fetchContent = opts.fetchContent; // (id) => Promise<[mime, bytes]>
        this.visible = false;
        this._epoch = 0;                        // drops a stale async render
        this._returnFocus = null;               // actor to refocus on close
        this._rendered = null;                  // observable: last render summary
        this._imageCache = new Map();           // id -> St.ImageContent (decoded, in-process)
        this._inflight = new Map();             // id -> Promise (prefetch/open dedupe)
        this._buildUI();
    }

    _buildUI() {
        // The overlay is a transparent CONTAINER. Its children paint in child order
        // (BinLayout), which is also z-order: the dim/scrim is the bottom child, the
        // content paints on top.
        this._overlay = new St.Widget({
            style_class: 'strata-peek',
            reactive: true,
            visible: false,
            x_expand: true,
            y_expand: true,
            layout_manager: new Clutter.BinLayout(),
        });

        // Dim/scrim backdrop (030): its OWN actor, the BOTTOM child, so it paints
        // BEHIND the content. Feature 006 made the scrim the overlay's own
        // background-color with the image as a descendant, which rendered the
        // full-resolution image very dark; here the image is a LATER sibling, ABOVE
        // the dim, so nothing darkens it.
        this._dim = new St.Widget({
            style_class: 'strata-peek-dim',
            x_expand: true,
            y_expand: true,
        });

        // Text/code container.
        this._panel = new St.BoxLayout({
            style_class: 'strata-peek-panel',
            vertical: true,
            x_expand: true,
            y_expand: true,
        });

        // Text/code view: a scrollable, wrapped St.Label (St.Label only — no markup).
        this._textScroll = new St.ScrollView({
            style_class: 'strata-peek-scroll',
            x_expand: true,
            y_expand: true,
            hscrollbar_policy: St.PolicyType.NEVER,
            vscrollbar_policy: St.PolicyType.AUTOMATIC,
        });
        this._textLabel = new St.Label({ style_class: 'strata-peek-text', x_expand: true });
        const ct = this._textLabel.get_clutter_text();
        ct.set_line_wrap(true);
        ct.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR);
        ct.set_selectable(true);
        // A ScrollView's child must be St.Scrollable; a bare St.Label is not, so
        // wrap it in a BoxLayout (as the shelf does with its cards).
        this._textBox = new St.BoxLayout({ vertical: true, x_expand: true, y_expand: true });
        this._textBox.add_child(this._textLabel);
        this._textScroll.set_child(this._textBox);
        this._panel.add_child(this._textScroll);

        // Image view (033): the full-res blob is decoded IN-PROCESS and set as this
        // actor's Clutter.Content (St.ImageContent) — no CSS background image, no
        // on-disk file URL, no glycin file-load. A direct child of the overlay ABOVE the
        // dim (030) — it carries no dark tint of its own, so the image is shown at
        // full brightness. RESIZE_ASPECT letter-boxes it (the old "contain").
        this._imageView = new St.Widget({
            style_class: 'strata-peek-image',
            visible: false,
            x_expand: true,
            y_expand: true,
            layout_manager: new Clutter.BinLayout(),
        });
        this._imageView.set_content_gravity(Clutter.ContentGravity.RESIZE_ASPECT);

        // Lightweight loading state (030): shown immediately while the full content is
        // fetched/decoded, so the user sees a readable label rather than a dark blank
        // during the (daemon-bound) GetItemContent transfer.
        this._loading = new St.Label({
            style_class: 'strata-peek-loading',
            text: 'Loading…',
            visible: false,
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
            x_expand: true,
            y_expand: true,
        });

        // Child order = paint order: dim (bottom) -> text -> image -> loading (top).
        this._overlay.add_child(this._dim);
        this._overlay.add_child(this._panel);
        this._overlay.add_child(this._imageView);
        this._overlay.add_child(this._loading);
        this._host?.add_child(this._overlay);

        // Click anywhere on the overlay dismisses (Space/Escape are routed by the
        // visor's capture handler in extension.js).
        this._overlay.connect('button-press-event', () => {
            this.close();
            return Clutter.EVENT_STOP;
        });
    }

    /** Show exactly one of the three views: 'loading' | 'text' | 'image'. */
    _setView(which) {
        this._loading.visible = which === 'loading';
        this._panel.visible = which === 'text';
        this._imageView.visible = which === 'image';
    }

    /** Open Peek for a Card. Fetches the full content on demand (one entry). A
     *  cached image (from a prior peek or a prefetch) shows instantly with no fetch
     *  and no loading flash. */
    open(card) {
        if (!card || !this._overlay) return;
        const id = card.strataId;
        const mime = card.strataMime || '';
        const epoch = ++this._epoch;
        this._returnFocus = card;
        // Provisional summary, refined once content arrives (observable by tests).
        this._rendered = { id, kind: null, isCode: false, spanCount: 0, language: null, mime };

        this._reveal();

        // Cache hit: the decoded image content is already in hand — show it now,
        // skipping the GetItemContent fetch + decode entirely (instant peek).
        const cached = this._imageCache.get(id);
        if (cached) { this._applyImageContent(id, mime || 'image/png', cached); return; }

        // Show a lightweight loading state immediately instead of a dark blank while
        // the full content is fetched + decoded (030).
        this._setView('loading');

        // A focus-driven prefetch for this id may still be IN FLIGHT (034: the card was
        // focused and Space pressed before the background warm finished). Ride that same
        // fetch rather than issuing a SECOND GetItemContent — when it resolves the decoded
        // image is in the cache. Fall back to a fresh fetch only if the prefetch produced
        // nothing (decode failure / not actually an image).
        const inflight = this._inflight.get(id);
        if (inflight) {
            inflight.then(() => {
                if (epoch !== this._epoch || !this._overlay) return; // superseded / closed
                const c = this._imageCache.get(id);
                if (c) this._applyImageContent(id, mime || 'image/png', c);
                else this._fetchAndShow(id, mime, epoch);
            }).catch(e => console.error('[Strata UI] Peek failed:', e));
            return;
        }

        this._fetchAndShow(id, mime, epoch);
    }

    /** Fetch an item's full content and render it (image or text). Factored out so a
     *  cold open and the ride-the-in-flight-prefetch fallback share one path. */
    _fetchAndShow(id, mime, epoch) {
        Promise.resolve(this._fetchContent ? this._fetchContent(id) : null)
            .then(res => {
                if (epoch !== this._epoch || !this._overlay) return; // superseded / closed
                if (!res) return;
                const [cmime, bytes] = res;
                const m = cmime || mime;
                if (m.startsWith('image/')) this._showImage(id, m, bytes);
                else this._showText(id, m, bytes);
            })
            .catch(e => console.error('[Strata UI] Peek failed:', e));
    }

    /** Pre-decode a card's full-res image into the cache in the background, WITHOUT
     *  showing it — so the common peek (the focused card) is instant. No-op for
     *  non-images, already-cached ids, or an in-flight fetch. (Wire this to the
     *  shelf's focus change to warm the focused card ahead of Space.) */
    prefetch(card) {
        if (!card || !this._overlay || !this._fetchContent) return;
        const id = card.strataId;
        const mime = card.strataMime || '';
        if (!mime.startsWith('image/')) return;
        if (this._imageCache.has(id) || this._inflight.has(id)) return;

        const p = Promise.resolve(this._fetchContent(id))
            .then(res => {
                if (!res || !this._overlay || this._imageCache.has(id)) return;
                const [cmime, bytes] = res;
                if (!(cmime || mime).startsWith('image/')) return;
                try { this._cacheImage(id, this._decodeToContent(bytes)); }
                catch (e) { console.error('[Strata UI] Peek prefetch decode failed:', e); }
            })
            .catch(e => console.error('[Strata UI] Peek prefetch failed:', e))
            .finally(() => { this._inflight.delete(id); });
        this._inflight.set(id, p);
    }

    _reveal() {
        this.visible = true;
        this._overlay.visible = true;
        // Keep the overlay above the band among the host's children.
        this._host?.set_child_above_sibling?.(this._overlay, null);
        try { global.stage?.set_key_focus(this._overlay); } catch (_) {}
    }

    _showText(id, mime, bytes) {
        let text = '';
        try { text = new TextDecoder('utf-8').decode(bytes); } catch (_) { text = ''; }
        if (text.length > DISPLAY_CAP)
            text = `${text.slice(0, DISPLAY_CAP)}\n…(truncated)`;

        // Drop any image content so the prior image's texture isn't held behind text.
        this._imageView.set_content(null);
        this._setView('text');
        this._textScroll.show();
        this._textLabel.set_text(text); // plain text — NEVER set_markup

        const { tokens, isCode, language } = highlight(text);
        const ct = this._textLabel.get_clutter_text();
        let spanCount = 0;
        if (isCode) {
            // Colour code by walking the tiling tokens and laying down Pango
            // foreground attributes over their BYTE ranges (UTF-8 offsets).
            const attrs = Pango.AttrList.new();
            let off = 0;
            for (const tok of tokens) {
                const len = _enc.encode(tok.text).length;
                const hex = THEME[tok.type];
                if (hex) {
                    const a = Pango.attr_foreground_new(
                        parseInt(hex.slice(1, 3), 16) * 257,
                        parseInt(hex.slice(3, 5), 16) * 257,
                        parseInt(hex.slice(5, 7), 16) * 257);
                    a.start_index = off;
                    a.end_index = off + len;
                    attrs.insert(a);
                    spanCount++;
                }
                off += len;
            }
            ct.set_attributes(attrs);
        } else {
            ct.set_attributes(null); // plain prose stays uncoloured
        }
        this._rendered = { id, kind: 'text', isCode, spanCount, language, mime };
    }

    _showImage(id, mime, bytes) {
        let content = this._imageCache.get(id);
        if (!content) {
            try {
                content = this._decodeToContent(bytes);
                this._cacheImage(id, content);
            } catch (e) {
                // Decode failure (corrupt/unsupported bytes): show nothing rather than
                // crash; the overlay stays up with the loading state cleared.
                console.error('[Strata UI] Peek image decode failed:', e);
                this._setView('image');
                this._imageView.set_content(null);
                this._rendered = { id, kind: 'image', isCode: false, spanCount: 0, language: null, mime };
                return;
            }
        }
        this._applyImageContent(id, mime, content);
    }

    /** Put a decoded image content on the image actor and switch to the image view. */
    _applyImageContent(id, mime, content) {
        this._setView('image');
        this._imageView.set_content(content);
        this._rendered = { id, kind: 'image', isCode: false, spanCount: 0, language: null, mime };
    }

    /** Decode image bytes IN-PROCESS to an St.ImageContent (a Clutter.Content):
     *  GdkPixbuf.new_from_stream over a Gio.MemoryInputStream → raw pixels uploaded
     *  to a Cogl texture. No temp file, no on-disk file URL, no CSS background image. */
    _decodeToContent(bytes) {
        const pixbuf = GdkPixbuf.Pixbuf.new_from_stream(
            Gio.MemoryInputStream.new_from_bytes(GLib.Bytes.new(bytes)), null);
        const w = pixbuf.get_width();
        const h = pixbuf.get_height();
        const content = St.ImageContent.new_with_preferred_size(w, h);
        content.set_bytes(
            this._coglContext(),
            GLib.Bytes.new(pixbuf.get_pixels()),
            pixbuf.get_has_alpha() ? Cogl.PixelFormat.RGBA_8888 : Cogl.PixelFormat.RGB_888,
            w, h, pixbuf.get_rowstride());
        return content;
    }

    _coglContext() {
        return global.stage.get_context().get_backend().get_cogl_context();
    }

    _cacheImage(id, content) {
        this._imageCache.delete(id);          // re-insert so it counts as most-recent
        this._imageCache.set(id, content);
        while (this._imageCache.size > IMAGE_CACHE_CAP) {
            // Evict the oldest entry; dropping the St.ImageContent reference frees its
            // GL texture on GC, bounding memory.
            const oldest = this._imageCache.keys().next().value;
            this._imageCache.delete(oldest);
        }
    }

    toggle(card) { this.visible ? this.close() : this.open(card); }

    close() {
        if (!this.visible) return;
        this._epoch++; // invalidate any in-flight fetch
        this.visible = false;
        // Tear down SYNCHRONOUSLY (030/033): hide the overlay FIRST so the dismiss is
        // immediate, then RELEASE the displayed image content — just drop the actor's
        // content reference (a cheap pointer swap). The decoded texture itself stays in
        // the bounded cache for an instant re-peek; nothing is deferred to a later frame
        // and there is no glycin/St.TextureCache teardown (the old ~1s Escape lag).
        if (this._overlay) this._overlay.visible = false;
        if (this._loading) this._loading.hide();
        if (this._imageView) { this._imageView.hide(); this._imageView.set_content(null); }
        const refocus = this._returnFocus;
        this._returnFocus = null;
        if (refocus && refocus.get_parent?.()) {
            try { global.stage?.set_key_focus(refocus); } catch (_) {}
        }
    }

    /** Release every decoded texture (disable/destroy): drop all content references
     *  so their GL textures are freed; bounds memory to zero when Peek is torn down. */
    _releaseCache() {
        this._inflight?.clear();
        this._imageCache?.clear();
    }

    destroy() {
        this._epoch++;
        this._imageView?.set_content(null);
        this._releaseCache();
        this._overlay?.destroy();
        this._overlay = null;
        this._dim = null;
        this._loading = null;
        this._textLabel = null;
        this._imageView = null;
        this._host = null;
        this._fetchContent = null;
    }
}
