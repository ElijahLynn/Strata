/* loader.js — the Test Clipboard Corpus loader (slice 016).
 *
 * A reusable seam for verify.sh cases. Every other verify case rolls its own
 * inline, almost-all-TEXT stub and NO case ever loads a REAL image — which is
 * exactly why the image paste-back bug shipped (the binary path was never
 * exercised). This loads the shared corpus (test-harness/corpus/, 3 realistic
 * items of EACH claimed type, with REAL bytes — real small PNGs included) and
 * makes it available to a verify case two ways:
 *
 *   seedViaSubmit(baseDir, proxy, cb)  — PREFERRED. SubmitItem each item's raw
 *       bytes into the (throwaway) daemon, exercising capture + storage +
 *       thumbnailing, just like a real copy. Image items go through the binary
 *       `ay` path, so the real image pipeline is finally covered.
 *
 *   stubFetchPage(shelf, baseDir)      — daemon-free alternative. Builds an
 *       ItemMeta[] from the corpus (text inline; images as has_thumbnail metas)
 *       and overrides shelf._fetchPage with it, so classification + rendering
 *       can be asserted without a live daemon.
 *
 * GJS / GNOME-Shell-Eval friendly: this whole file is eval'd as a string (so it
 * works regardless of imports.searchPath) and installs globalThis.StrataCorpus.
 * Bytes are read off disk with Gio so the REAL fixture bytes reach the daemon.
 *
 * "claimed types" are NOT invented here — they are the union of
 * docs/reference/strata-daemon-dbus-contract.md ("Supported MIME"),
 * strata@edu4rdshl.dev/extension.js _pickMime PREFERRED, and the cardTypes
 * extension/ui/card.js classify() renders. See manifest.json.
 */
(function () {
    const GLib = imports.gi.GLib;
    const Gio = imports.gi.Gio;

    function readBytes(path) {
        const [ok, bytes] = GLib.file_get_contents(path);
        if (!ok) throw new Error('corpus: cannot read ' + path);
        // file_get_contents gives a Uint8Array (GLib.Bytes-backed) in modern GJS.
        return bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    }

    function manifest(baseDir) {
        const txt = new TextDecoder('utf-8').decode(readBytes(baseDir + '/manifest.json'));
        return JSON.parse(txt).items;
    }

    /** One corpus item with its REAL bytes resolved from disk. text is the UTF-8
     *  decoding for non-binary items (what the daemon stores as content_text),
     *  null for raster images. */
    function readItem(baseDir, item) {
        const bytes = readBytes(baseDir + '/' + item.file);
        const text = item.binary ? null : new TextDecoder('utf-8').decode(bytes);
        return Object.assign({}, item, { bytes, text });
    }

    function items(baseDir) {
        return manifest(baseDir).map((it) => readItem(baseDir, it));
    }

    /** PREFERRED: push every corpus item into the daemon via SubmitItem (raw ay),
     *  exactly like a real clipboard copy. Submits are serialized with a small gap
     *  (SubmitItem is fire-and-forget; the daemon hashes/dedups/thumbnails async),
     *  then cb(submittedCount) fires. */
    function seedViaSubmit(baseDir, proxy, cb) {
        const list = items(baseDir);
        let i = 0;
        (function next() {
            if (i >= list.length) { if (cb) cb(list.length); return; }
            const it = list[i++];
            proxy.SubmitItemRemote(it.type, it.bytes, function () {
                GLib.timeout_add(GLib.PRIORITY_DEFAULT, 60, function () { next(); return false; });
            });
        })();
    }

    /** Daemon-free: synthesize ItemMeta[] (newest-first) from the corpus and stub
     *  the shelf's _fetchPage seam with it, so classification + rendering can be
     *  asserted deterministically. Image items carry has_thumbnail:true + null
     *  content_text (the daemon never returns image bytes in history). Returns the
     *  metas so a case can index them. */
    function buildMetas(baseDir) {
        const list = items(baseDir);
        return list.map((it, idx) => ({
            id: it.id,
            mime_type: it.type,
            content_text: it.binary ? null : it.text,
            source_app: null,
            created_at: list.length - idx, // declaration order = newest-first
            has_thumbnail: !!it.binary,
        }));
    }

    function stubFetchPage(shelf, baseDir) {
        const metas = buildMetas(baseDir);
        shelf._fetchPage = function (o, l) { return Promise.resolve(metas.slice(o, o + l)); };
        return metas;
    }

    globalThis.StrataCorpus = {
        manifest, readItem, items, seedViaSubmit, buildMetas, stubFetchPage,
        // expose the raw byte reader so a case can verify REAL fixture bytes
        readBytes,
    };
    return 1;
})();
