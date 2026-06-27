/* card.js — one Card on the Shelf.
 *
 * v1: Text (002) + Image (003) + the type-specific renderers from 007 —
 * Link (URL), Color (hex swatch), File(s) (uri-list / copied-files). Per ADR-0007
 * the shelf classification is "whatever Strata does now": cheap client-side regex
 * for Link and Color, mime for File and Image, everything else Text. There is NO
 * code detection or syntax highlighting on the shelf — that is Peek-only (006).
 *
 * Hard rule (architecture-constraints.md): clipboard content is rendered with
 * St.Label ONLY — never set_markup — so a copied string can't be interpreted
 * as Pango markup. Image cards never decode full-res blobs; they show the
 * daemon's ~200px thumbnail, fetched on demand by the shelf for visible cards.
 */

import GObject from 'gi://GObject';
import Clutter from 'gi://Clutter';
import Pango from 'gi://Pango';
import St from 'gi://St';

// Cards show a daemon preview (already truncated to ~200 chars); cap again
// defensively so one giant entry can't blow up a card's layout cost.
const PREVIEW_LEN = 600;

// Cheap, whole-content classification regexes (run once per card, on the client).
const URL_RE = /^https?:\/\/[^\s]+$/i;          // the entire entry is a single URL
const URL_HOST_RE = /^https?:\/\/([^/\s:?#]+)/i; // → hostname (no scheme/port/path)
const COLOR_RE = /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/; // #rgb or #rrggbb

export const Card = GObject.registerClass(
class Card extends St.Button {
    _init(meta, opts = {}) {
        super._init({
            style_class: 'strata-card',
            can_focus: true,
            reactive: true,
            x_expand: false,
            y_expand: true,
        });

        this.strataId = meta.id;
        this.strataMime = meta.mime_type ?? '';
        const raw = (meta.content_text ?? '').trim();
        this.cardType = classify(this.strataMime, raw);
        this.isImage = this.cardType === 'image'; // the shelf gates thumbnails on this
        this.set_width(opts.cardWidth ?? 300);

        const body = new St.BoxLayout({
            style_class: 'strata-card-body',
            vertical: true,
            x_expand: true,
            y_expand: true,
        });
        body.add_child(this._buildBody(meta, raw));
        this.set_child(body);

        // Bold/highlight on keyboard focus (used by select/navigation features);
        // the colours live in CSS so themes can override them.
        this.connect('key-focus-in', () => this.add_style_class_name('strata-card-focused'));
        this.connect('key-focus-out', () => this.remove_style_class_name('strata-card-focused'));
    }

    /** Re-apply a new card-width live (feature 008 prefs). */
    setWidth(w) { this.set_width(w); }

    _buildBody(meta, raw) {
        switch (this.cardType) {
            case 'image': return this._buildThumb();
            case 'link': return this._buildLink(raw);
            case 'color': return this._buildColor(raw);
            case 'file': return this._buildFile(raw);
            default: return this._buildText(meta);
        }
    }

    _buildText(meta) {
        const raw = (meta.content_text ?? '').replace(/\s+/g, ' ').trim();
        const text = raw.length > PREVIEW_LEN ? `${raw.slice(0, PREVIEW_LEN)}…` : raw;

        const label = new St.Label({
            text: text || '(empty)',
            style_class: 'strata-card-text',
            x_expand: true,
            y_expand: true,
        });
        const ct = label.get_clutter_text();
        ct.set_line_wrap(true);
        ct.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR);
        ct.set_ellipsize(Pango.EllipsizeMode.END); // clip overflow on the fixed-height card
        this._textLabel = label;
        return label;
    }

    /** Link card: the URL, link-styled, with the hostname as a subtitle. */
    _buildLink(url) {
        const box = new St.BoxLayout({ style_class: 'strata-card-link', vertical: true, y_expand: true });
        const host = (URL_HOST_RE.exec(url)?.[1] ?? '').replace(/^www\./, '');

        const link = new St.Label({ text: url, style_class: 'strata-card-link-url', x_expand: true });
        const lct = link.get_clutter_text();
        lct.set_line_wrap(true);
        lct.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR);
        lct.set_ellipsize(Pango.EllipsizeMode.END);

        this._subtitle = new St.Label({ text: host, style_class: 'strata-card-subtitle' });
        box.add_child(link);
        box.add_child(this._subtitle);
        return box;
    }

    /** Color card: a swatch filled with the hex, plus the hex string below it. */
    _buildColor(hex) {
        const box = new St.BoxLayout({ style_class: 'strata-card-color', vertical: true, y_expand: true });
        // hex came straight from COLOR_RE, so it's safe to drop into CSS.
        this._swatch = new St.Widget({
            style_class: 'strata-card-swatch',
            style: `background-color: ${hex};`,
            x_expand: true,
            y_expand: true,
        });
        const label = new St.Label({ text: hex.toUpperCase(), style_class: 'strata-card-color-hex' });
        box.add_child(this._swatch);
        box.add_child(label);
        return box;
    }

    /** File(s) card: an icon plus the filename(s) parsed from the uri-list. */
    _buildFile(content) {
        const names = fileNames(content);
        const box = new St.BoxLayout({ style_class: 'strata-card-file', vertical: false, y_expand: true });
        this._fileIcon = new St.Icon({
            icon_name: names.length > 1 ? 'folder-symbolic' : 'text-x-generic-symbolic',
            icon_size: 32,
            style_class: 'strata-card-file-icon',
            y_align: Clutter.ActorAlign.CENTER,
        });
        const text = new St.BoxLayout({ vertical: true, x_expand: true, y_align: Clutter.ActorAlign.CENTER });
        this._fileText = new St.Label({
            text: names[0] ?? '(no files)',
            style_class: 'strata-card-file-name',
            x_expand: true,
        });
        this._fileText.get_clutter_text().set_ellipsize(Pango.EllipsizeMode.MIDDLE);
        text.add_child(this._fileText);
        if (names.length > 1) {
            text.add_child(new St.Label({
                text: `+${names.length - 1} more`,
                style_class: 'strata-card-subtitle',
            }));
        }
        box.add_child(this._fileIcon);
        box.add_child(text);
        return box;
    }

    /** Image card: a placeholder icon shown immediately; the shelf swaps in the
     *  real thumbnail (as a background-image) once it fetches one for this card
     *  — but only while the card is visible. */
    _buildThumb() {
        this._thumbContainer = new St.Widget({
            style_class: 'strata-card-thumb',
            x_expand: true,
            y_expand: true,
            layout_manager: new Clutter.BinLayout(),
        });
        this._thumbPlaceholder = new St.Icon({
            icon_name: 'image-x-generic-symbolic',
            icon_size: 48,
            style_class: 'strata-card-thumb-placeholder',
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._thumbContainer.add_child(this._thumbPlaceholder);
        return this._thumbContainer;
    }

    /** Apply a fetched/cached thumbnail. The PNG is decoded off the shell thread
     *  by the CSS background-image loader, not on the main loop. */
    applyThumbnail(fileUri) {
        if (!this._thumbContainer)
            return;
        try {
            this._thumbContainer.style =
                `background-image: url("${fileUri}");` +
                'background-size: cover; background-position: center; background-repeat: no-repeat;';
            this._thumbPlaceholder?.hide();
            this._thumbLoaded = true;
        } catch (_) { /* container destroyed mid-flight */ }
    }
});

/** Cheap, whole-content classification (ADR-0007): image/file by mime, Link/Color
 *  by regex on the trimmed text, everything else Text. */
function classify(mime, text) {
    if (mime.startsWith('image/')) return 'image';
    if (mime === 'text/uri-list' || mime.includes('copied-files') || mime.includes('uri-list'))
        return 'file';
    if (URL_RE.test(text)) return 'link';
    if (COLOR_RE.test(text)) return 'color';
    return 'text';
}

/** Basenames of the file:// URIs in a uri-list / copied-files payload. The
 *  gnome/kde "copied-files" form has a leading op line ("copy"/"cut") that has no
 *  file:// prefix, so it's naturally skipped. */
function fileNames(content) {
    const names = [];
    for (const line of (content ?? '').split('\n')) {
        const uri = line.trim();
        if (!uri.startsWith('file://')) continue;
        let base = uri.split('/').pop();
        try { base = decodeURIComponent(base); } catch (_) { /* keep raw */ }
        if (base) names.push(base);
    }
    return names;
}
