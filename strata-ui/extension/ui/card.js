/* card.js — one Card on the Shelf.
 *
 * v1: Text card (002) + Image card (003). Link / Color / File renderers land in
 * 007; Peek in 006. The card is an St.Button so later features (focus,
 * Enter-to-copy, Alt+N) get keyboard activation for free.
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
        this.isImage = this.strataMime.startsWith('image/');
        this.set_width(opts.cardWidth ?? 300);

        const body = new St.BoxLayout({
            style_class: 'strata-card-body',
            vertical: true,
            x_expand: true,
            y_expand: true,
        });
        body.add_child(this.isImage ? this._buildThumb() : this._buildText(meta));
        this.set_child(body);

        // Bold/highlight on keyboard focus (used by select/navigation features
        // later); the colours live in CSS so themes can override them.
        this.connect('key-focus-in', () => this.add_style_class_name('strata-card-focused'));
        this.connect('key-focus-out', () => this.remove_style_class_name('strata-card-focused'));
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
