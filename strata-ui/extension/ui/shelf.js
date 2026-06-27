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
import Gio from 'gi://Gio';
import St from 'gi://St';

import { Card } from './card.js';

const RENDER_BATCH = 20;          // cards inserted per idle tick (paced rendering)
const LOAD_MORE_THRESHOLD = 200;  // px from the end that triggers the next page
const SEARCH_DEBOUNCE_MS = 150;   // collapse rapid keystrokes into one query

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
        this._loadEpoch = 0;      // bumped on each (re)render so stale renders bail

        // Search state (feature 004).
        this._query = '';              // applied query ('' = browse mode)
        this._searchEpoch = 0;         // drops out-of-order search responses
        this._searchDebounceId = null; // pending debounce timer

        /** @type {Map<string, Card>} id → card; doubles as a dedup guard. */
        this._cards = new Map();

        // On-demand thumbnail state (feature 003).
        /** @type {Map<string, string>} id → cache file path (session cache). */
        this._thumbCache = new Map();
        /** @type {Set<string>} ids already fetched/in-flight, so a visible card
         *  is never re-requested while it stays on screen. */
        this._thumbRequested = new Set();

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

        // Drive both pagination and lazy thumbnails off the horizontal viewport:
        // value changes on scroll; upper/page-size change once a freshly-rendered
        // page is laid out (so card allocations are valid when we test visibility).
        const adj = this._scroll.get_hadjustment();
        this._adjIds = [];
        for (const prop of ['notify::value', 'notify::upper', 'notify::page-size'])
            this._adjIds.push(adj?.connect(prop, () => this._onViewportChanged()));
        this._adj = adj;
    }

    _onViewportChanged() {
        this._maybeLoadMore();
        this._updateVisibleThumbs();
    }

    /** (Re)load from the top. Called each time the visor opens, so a summon
     *  always shows current history. */
    load() {
        // Entering browse mode: cancel any in-flight/pending search.
        this._query = '';
        this._searchEpoch++;
        if (this._searchDebounceId) {
            GLib.Source.remove(this._searchDebounceId);
            this._searchDebounceId = null;
        }
        this._loadEpoch++;
        this._loadingMore = true;   // hold off scroll-driven loads until page 0 lands
        this._loadedOffset = 0;
        this._hasMore = true;
        this.renderStats.batches = 0;
        // Drop per-view thumbnail requests (cards are about to be rebuilt) but
        // keep the session path cache so a reopen re-applies without re-fetching.
        this._thumbRequested.clear();
        this._clear();
        this._loadPage(0, this._loadEpoch);
    }

    _clear() {
        this._cards.clear();
        this._cardBox?.destroy_all_children();
        this.renderStats.count = 0;
    }

    // -- Search (feature 004) --------------------------------------------------

    /** Debounce search-box input; collapses rapid keystrokes into one query. */
    setQuery(query) {
        const trimmed = (query ?? '').trim();
        if (this._searchDebounceId) {
            GLib.Source.remove(this._searchDebounceId);
            this._searchDebounceId = null;
        }
        this._searchDebounceId = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT, SEARCH_DEBOUNCE_MS, () => {
                this._searchDebounceId = null;
                this._runQuery(trimmed).catch(e =>
                    console.error('[Strata UI] search failed:', e));
                return GLib.SOURCE_REMOVE;
            });
    }

    /** Seam: FTS5 prefix search via the daemon — SearchHistory(query, limit).
     *  Overridden in tests. */
    async _fetchSearch(query, limit) {
        const [json] = await this._proxy.SearchHistoryAsync(query, limit);
        return JSON.parse(json);
    }

    /** Run one query. Empty → restore the browse view. Non-empty → fetch matches
     *  (bounded by max-history) and render them through the same paced pipeline.
     *  An epoch guard drops a stale response that resolves after a newer query. */
    async _runQuery(query) {
        const epoch = ++this._searchEpoch;
        if (!query) {
            this.load();              // browse mode (recent history)
            return;
        }
        this._query = query;
        const limit = this._settings.get_int('max-history');
        let metas;
        try {
            metas = await this._fetchSearch(query, limit);
        } catch (e) {
            console.error('[Strata UI] SearchHistory failed:', e);
            return;
        }
        if (epoch !== this._searchEpoch || !this._cardBox) return; // superseded / destroyed
        this._renderResults(metas);
    }

    /** Replace the shelf with a result set. Search has no browse pagination — the
     *  daemon already returned every match up to the limit. Reuses the paced
     *  idle_add render and the lazy-thumbnail pass. */
    _renderResults(metas) {
        const renderEpoch = ++this._loadEpoch; // supersede any browse/search render
        this._loadingMore = false;
        this._hasMore = false;
        this._loadedOffset = 0;
        this._thumbRequested.clear();
        this.renderStats.batches = 0;
        this._clear();
        this._renderBatched(metas, renderEpoch).then(() => {
            if (renderEpoch !== this._loadEpoch) return;
            GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
                if (renderEpoch === this._loadEpoch) this._updateVisibleThumbs();
                return GLib.SOURCE_REMOVE;
            });
        });
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
        // Backstop: once the page has had a chance to lay out, load thumbnails
        // for whatever ended up visible (in case no adjustment signal fired).
        GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            if (epoch === this._loadEpoch) this._updateVisibleThumbs();
            return GLib.SOURCE_REMOVE;
        });
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

    // -- On-demand thumbnails (feature 003) ------------------------------------

    _thumbDir() { return `${GLib.get_user_cache_dir()}/strata/thumbnails`; }
    _thumbPath(id) { return `${this._thumbDir()}/${id}.png`; }

    /** Seam: fetch the daemon's ~200px PNG thumbnail bytes for one item.
     *  Overridden in tests; the real path calls GetThumbnail(id). */
    async _fetchThumbnail(id) {
        const [bytes] = await this._proxy.GetThumbnailAsync(id);
        return bytes;
    }

    /** Ensure one (visible) image card has its thumbnail. No-op for non-image
     *  cards and for ids already requested this view, so off-screen cards never
     *  hit D-Bus. Reuses the session map and the on-disk cache before fetching. */
    _ensureThumb(card) {
        const id = card.strataId;
        if (!card.isImage || this._thumbRequested.has(id)) return;
        this._thumbRequested.add(id);

        const path = this._thumbPath(id);
        if (this._thumbCache.has(id) || GLib.file_test(path, GLib.FileTest.EXISTS)) {
            this._thumbCache.set(id, path);
            card.applyThumbnail(`file://${path}`);
            return;
        }
        if (!this._proxy) { this._thumbRequested.delete(id); return; }

        GLib.mkdir_with_parents(this._thumbDir(), 0o755);
        this._fetchThumbnail(id).then(bytes => {
            if (!this._cards.has(id)) return;          // deleted while in flight
            if (!bytes || bytes.length === 0) return;  // daemon has no thumbnail
            const file = Gio.File.new_for_path(path);
            file.replace_contents_bytes_async(
                new GLib.Bytes(bytes), null, false, Gio.FileCreateFlags.NONE, null,
                (f, res) => {
                    try {
                        f.replace_contents_finish(res);
                        this._thumbCache.set(id, path);
                        this._cards.get(id)?.applyThumbnail(`file://${path}`);
                    } catch (e) {
                        console.error('[Strata UI] thumbnail write failed:', e);
                    }
                });
        }).catch(e => {
            this._thumbRequested.delete(id);           // allow a later retry
            console.error('[Strata UI] GetThumbnail failed:', e);
        });
    }

    /** Request thumbnails for every image card currently in the viewport. Called
     *  on scroll and after a page lays out. Cards without a real allocation yet
     *  are skipped — they get picked up on the next relayout. */
    _updateVisibleThumbs() {
        if (!this._cardBox || !this._scroll) return;
        const adj = this._scroll.get_hadjustment();
        if (!adj || adj.page_size <= 0) return;
        const lo = adj.value;
        const hi = adj.value + adj.page_size;
        for (const card of this._cardBox.get_children()) {
            if (!card.isImage || this._thumbRequested.has(card.strataId)) continue;
            const box = card.get_allocation_box();
            if (box.x2 - box.x1 <= 0) continue;        // not laid out yet
            if (box.x2 >= lo && box.x1 <= hi) this._ensureThumb(card);
        }
    }

    /** A daemon item went away (delete or prune): drop its card and unlink the
     *  cached thumbnail. (The ItemDeleted signal subscription is wired in 009.) */
    onItemDeleted(id) {
        const path = this._thumbCache.get(id) ?? this._thumbPath(id);
        try { GLib.unlink(path); } catch (_) {}
        this._thumbCache.delete(id);
        this._thumbRequested.delete(id);
        const card = this._cards.get(id);
        if (card) {
            card.destroy();
            this._cards.delete(id);
            this.renderStats.count = this._cards.size;
        }
    }

    destroy() {
        this._loadEpoch++;   // invalidate any in-flight render
        this._searchEpoch++; // invalidate any in-flight search
        if (this._searchDebounceId) {
            GLib.Source.remove(this._searchDebounceId);
            this._searchDebounceId = null;
        }
        if (this._adjIds && this._adj) {
            for (const id of this._adjIds) { if (id) this._adj.disconnect(id); }
        }
        this._adjIds = null;
        this._adj = null;
        this._clear();
        this._scroll?.destroy();
        this._scroll = null;
        this._cardBox = null;
        this._proxy = null;
        this._settings = null;
    }
}
