/* shelf.js — the horizontal Shelf of clipboard Cards.
 *
 * v1 / feature 002: render the daemon's clipboard history, newest-first, as
 * fixed-width Cards in a horizontally-scrolling band. History is pulled a page
 * at a time (GetHistory(offset, page-size)) and inserted in paced idle_add
 * batches, so a big page never freezes a compositor frame and the full table
 * never sits in JS memory (architecture-constraints.md).
 *
 * Later features extend this: thumbnails (003), search (004), select (005),
 * Peek (006), typed cards (007), live signals (009).
 */

import GLib from 'gi://GLib';
import St from 'gi://St';

import { Card } from './card.js';

const RENDER_BATCH = 20;          // cards inserted per idle tick (paced rendering)
const LOAD_MORE_THRESHOLD = 200;  // px from the end that triggers the next page

export class Shelf {
    constructor(proxy, settings) {
        this._proxy = proxy;
        this._settings = settings;

        this._pageSize = settings.get_int('page-size');
        this._cardWidth = settings.get_int('card-width');

        // Browse-mode pagination state.
        this._loadedOffset = 0;   // how many items we've already pulled
        this._hasMore = true;     // false once the daemon returns < pageSize
        this._loadingMore = false; // re-entrancy guard for fetches
        this._loadEpoch = 0;      // bumped on each (re)load so stale renders bail

        /** @type {Map<string, Card>} id → card; doubles as a dedup guard. */
        this._cards = new Map();

        // Observable by the test harness; also handy for debugging.
        this.renderStats = { batchSize: RENDER_BATCH, batches: 0, count: 0 };

        this._buildUI();
    }

    _buildUI() {
        this._cardBox = new St.BoxLayout({
            style_class: 'strata-shelf',
            vertical: false,
            y_expand: true,
        });
        this._scroll = new St.ScrollView({
            style_class: 'strata-shelf-scroll',
            x_expand: true,
            y_expand: true,
            hscrollbar_policy: St.PolicyType.EXTERNAL, // scrollable; no reserved scrollbar gutter
            vscrollbar_policy: St.PolicyType.NEVER,    // cards fill the band height — never scroll vertically
            overlay_scrollbars: true,
        });
        this._scroll.set_child(this._cardBox);
        this.actor = this._scroll;

        const adj = this._scroll.get_hadjustment();
        this._scrollSignalId = adj?.connect('notify::value', () => this._maybeLoadMore());
    }

    /** (Re)load from the top. Called each time the visor opens, so a summon
     *  always shows current history. */
    load() {
        this._loadEpoch++;
        this._loadingMore = true;   // hold off scroll-driven loads until page 0 lands
        this._loadedOffset = 0;
        this._hasMore = true;
        this.renderStats.batches = 0;
        this._clear();
        this._loadPage(0, this._loadEpoch);
    }

    _clear() {
        this._cards.clear();
        this._cardBox?.destroy_all_children();
        this.renderStats.count = 0;
    }

    /** Seam: fetch one page of ItemMeta[] from the daemon. Calls
     *  GetHistory(offset, limit) — newest-first metadata, no image bytes.
     *  Overridden in tests to feed canned history deterministically. */
    async _fetchPage(offset, limit) {
        const [json] = await this._proxy.GetHistoryAsync(offset, limit);
        return JSON.parse(json);
    }

    async _loadPage(offset, epoch) {
        let metas;
        try {
            metas = await this._fetchPage(offset, this._pageSize);
        } catch (e) {
            console.error('[Strata UI] GetHistory failed:', e);
            if (epoch === this._loadEpoch) this._loadingMore = false;
            return;
        }
        if (epoch !== this._loadEpoch || !this._cardBox) return; // superseded / destroyed
        await this._renderBatched(metas, epoch);
        if (epoch !== this._loadEpoch) return;
        this._loadedOffset = offset + metas.length;
        this._hasMore = metas.length >= this._pageSize;
        this._loadingMore = false;
    }

    /** Insert cards in idle_add chunks of RENDER_BATCH so a full page never
     *  builds in one frame. Bails between chunks if a newer load superseded us
     *  or the shelf was destroyed. */
    async _renderBatched(metas, epoch) {
        for (let i = 0; i < metas.length; i += RENDER_BATCH) {
            if (epoch !== this._loadEpoch || !this._cardBox) return;
            await new Promise(resolve =>
                GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
                    if (epoch === this._loadEpoch && this._cardBox) {
                        const end = Math.min(i + RENDER_BATCH, metas.length);
                        for (let j = i; j < end; j++) this._appendCard(metas[j]);
                        this.renderStats.batches++;
                    }
                    resolve();
                    return GLib.SOURCE_REMOVE;
                }));
        }
    }

    _appendCard(meta) {
        if (!meta || this._cards.has(meta.id)) return; // dedup
        const card = new Card(meta, { cardWidth: this._cardWidth });
        this._cards.set(meta.id, card);
        this._cardBox.add_child(card);
        this.renderStats.count = this._cards.size;
    }

    /** Pull the next page when the horizontal scroll nears the end. */
    _maybeLoadMore() {
        if (this._loadingMore || !this._hasMore) return;
        const adj = this._scroll?.get_hadjustment();
        if (!adj || adj.upper <= adj.page_size) return; // nothing to scroll yet
        const distanceToEnd = adj.upper - (adj.value + adj.page_size);
        if (distanceToEnd > LOAD_MORE_THRESHOLD) return;
        this._loadingMore = true;
        this._loadPage(this._loadedOffset, this._loadEpoch);
    }

    destroy() {
        this._loadEpoch++; // invalidate any in-flight render
        const adj = this._scroll?.get_hadjustment();
        if (this._scrollSignalId && adj) {
            adj.disconnect(this._scrollSignalId);
            this._scrollSignalId = 0;
        }
        this._clear();
        this._scroll?.destroy();
        this._scroll = null;
        this._cardBox = null;
        this._proxy = null;
        this._settings = null;
    }
}
