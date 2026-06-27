/* card.js — one Card on the Shelf.
 *
 * v1 / feature 002: the Text card only. Image / Link / Color / File renderers
 * land in 003 & 007; Peek in 006. The card is an St.Button so later features
 * (focus, Enter-to-copy, Alt+N) get keyboard activation for free.
 *
 * Hard rule (architecture-constraints.md): clipboard content is rendered with
 * St.Label ONLY — never set_markup — so a copied string can't be interpreted
 * as Pango markup.
 */

import GObject from 'gi://GObject';
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
        this.set_width(opts.cardWidth ?? 300);

        const body = new St.BoxLayout({
            style_class: 'strata-card-body',
            vertical: true,
            x_expand: true,
            y_expand: true,
        });

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
        body.add_child(label);

        this.set_child(body);

        // Bold/highlight on keyboard focus (used by select/navigation features
        // later); the colours live in CSS so themes can override them.
        this.connect('key-focus-in', () => this.add_style_class_name('strata-card-focused'));
        this.connect('key-focus-out', () => this.remove_style_class_name('strata-card-focused'));
    }
});
