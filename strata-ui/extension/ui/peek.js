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
 *   - image: fetch the full-resolution blob (GetItemContent) and show it,
 *     decoded off the shell thread by the CSS background-image loader (the same
 *     bargain as the shelf thumbnails) — one image, on keypress.
 *
 * Layering (030): the dim/scrim is its OWN actor (the bottom child of the
 * overlay), with the text/image/loading views as later siblings ABOVE it — so the
 * full-resolution image renders at FULL brightness, never under the scrim. While
 * the content is fetched/decoded a lightweight loading state shows instead of a
 * dark blank, and close() tears the overlay down synchronously.
 *
 * Space again, Escape, or a click dismiss back to the shelf.
 */

import GLib from 'gi://GLib';
import Clutter from 'gi://Clutter';
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

const _enc = new TextEncoder();

export class Peek {
    constructor(host, opts = {}) {
        this._host = host;                      // actor we overlay (the visor)
        this._fetchContent = opts.fetchContent; // (id) => Promise<[mime, bytes]>
        this.visible = false;
        this._epoch = 0;                        // drops a stale async render
        this._returnFocus = null;               // actor to refocus on close
        this._rendered = null;                  // observable: last render summary
        this._imageFile = null;                 // temp file backing the image view
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

        // Image view: the full-res blob applied as a CSS background-image, decoded
        // off the shell thread by the loader (same as the shelf thumbnails). A direct
        // child of the overlay ABOVE the dim (030) — it carries no dark tint of its
        // own, so the image is shown at full brightness.
        this._imageView = new St.Widget({
            style_class: 'strata-peek-image',
            visible: false,
            x_expand: true,
            y_expand: true,
            layout_manager: new Clutter.BinLayout(),
        });

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

    /** Open Peek for a Card. Fetches the full content on demand (one entry). */
    open(card) {
        if (!card || !this._overlay) return;
        const id = card.strataId;
        const mime = card.strataMime || '';
        const epoch = ++this._epoch;
        this._returnFocus = card;
        // Provisional summary, refined once content arrives (observable by tests).
        this._rendered = { id, kind: null, isCode: false, spanCount: 0, language: null, mime };

        this._reveal();
        // Show a lightweight loading state immediately instead of a dark blank while
        // the full content is fetched + decoded (030).
        this._setView('loading');

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

        this._imageView.style = null;
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
        this._setView('image');
        try {
            const dir = `${GLib.get_user_cache_dir()}/strata/peek`;
            GLib.mkdir_with_parents(dir, 0o755);
            const path = `${dir}/${id}.${extFor(mime)}`;
            GLib.file_set_contents(path, bytes);
            this._imageFile = path;
            this._imageView.style =
                `background-image: url("file://${path}");` +
                'background-size: contain; background-position: center; background-repeat: no-repeat;';
        } catch (e) {
            console.error('[Strata UI] Peek image failed:', e);
        }
        this._rendered = { id, kind: 'image', isCode: false, spanCount: 0, language: null, mime };
    }

    toggle(card) { this.visible ? this.close() : this.open(card); }

    close() {
        if (!this.visible) return;
        this._epoch++; // invalidate any in-flight fetch
        this.visible = false;
        // Tear down SYNCHRONOUSLY (030): hide the overlay FIRST so the dismiss is
        // immediate, then release the full-res image texture + temp file — nothing is
        // deferred to a later frame.
        if (this._overlay) this._overlay.visible = false;
        if (this._loading) this._loading.hide();
        if (this._imageView) { this._imageView.hide(); this._imageView.style = null; }
        this._clearImageFile();
        const refocus = this._returnFocus;
        this._returnFocus = null;
        if (refocus && refocus.get_parent?.()) {
            try { global.stage?.set_key_focus(refocus); } catch (_) {}
        }
    }

    _clearImageFile() {
        if (this._imageFile) {
            try { GLib.unlink(this._imageFile); } catch (_) {}
            this._imageFile = null;
        }
    }

    destroy() {
        this._epoch++;
        this._clearImageFile();
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

function extFor(mime) {
    switch (mime) {
        case 'image/jpeg': return 'jpg';
        case 'image/gif': return 'gif';
        case 'image/webp': return 'webp';
        case 'image/bmp': return 'bmp';
        default: return 'png';
    }
}
