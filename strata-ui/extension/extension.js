/* extension.js - Strata UI lifecycle: a Quake-style visor over the Strata daemon.
 *
 * v1 / feature 001: the empty visor. Daemon supervision is lifted verbatim from
 * strata@edu4rdshl.dev (ADR-0001); the visor itself is new. The shelf of cards
 * lands in later features. */

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';
import Clutter from 'gi://Clutter';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';

import {StrataProxy, BUS_NAME, OBJECT_PATH} from './dbus.js';
import {Shelf} from './ui/shelf.js';

export default class StrataUIExtension extends Extension {
    /** @type {Gio.Subprocess | null} */
    _daemon = null;
    _daemonSpawnTime = 0;
    _daemonRestartAttempts = 0;
    _shuttingDown = false;
    _daemonRestartTimerId = null;
    _daemonKillTimerId = null;
    _spawnPending = false;

    /** @type {object | null} */
    _proxy = null;

    /** @type {St.Widget | null} full-screen modal layer */
    _visor = null;
    /** @type {St.BoxLayout | null} the edge band */
    _band = null;
    /** @type {Shelf | null} the horizontal card shelf inside the band */
    _shelf = null;
    _visorVisible = false;
    _grab = null;

    /** Live-update state (feature 009). */
    _signalIds = null;          // daemon D-Bus signal subscription ids
    _focusSignalId = null;      // global.display notify::focus-window
    _currentFocusedApp = '';    // wm_class of the focused window (for excluded-apps)

    /** Clipboard capture state (slice 010). On GNOME the daemon's data-control
     *  monitor does not bind (Mutter exposes neither ext- nor wlr-data-control,
     *  see strata-daemon/src/clipboard/monitor.rs), so the extension is the
     *  capture agent: watch the Meta selection and forward copies via SubmitItem. */
    _selectionChangedId = null;   // global.display selection 'owner-changed'
    _clipboardDebounceId = null;  // coalesces rapid clipboard writes
    _clipboardTransferPending = false; // one transfer_async in flight at a time
    _maxTextBytes = 1024 * 1024;
    _maxImageBytes = 5 * 1024 * 1024;

    enable() {
        this._settings = this.getSettings();
        this._shuttingDown = false;
        this._daemonRestartAttempts = 0;
        if (this._daemonKillTimerId) {
            GLib.Source.remove(this._daemonKillTimerId);
            this._daemonKillTimerId = null;
        }

        this._readSizeLimits();   // text/image caps for capture + daemon config
        this._spawnDaemon();      // Rust daemon (supervised); shared with Strata.
        this._connectProxy();     // async — never blocks if the daemon isn't up yet.
        this._buildVisor();
        this._registerShortcut();
        this._watchSettings();    // live layout + theme; also applies the theme now
        this._connectFocusTracking(); // who's focused → excluded-apps decisions
        this._connectSignals();   // ItemAdded / ItemDeleted / HistoryCleared
        this._connectClipboardMonitor(); // capture copies → SubmitItem (GNOME path)
        console.log('[Strata UI] enabled');
    }

    disable() {
        this._shuttingDown = true;
        this._unregisterShortcut();
        this._unwatchSettings();
        this._disconnectClipboardMonitor();
        this._disconnectSignals();
        this._disconnectFocusTracking();
        this._hideVisor();
        this._shelf?.destroy();
        this._shelf = null;
        this._visor?.destroy();   // also destroys the band child
        this._visor = null;
        this._band = null;
        this._searchEntry = null;
        this._gearButton = null;
        if (this._daemonRestartTimerId !== null) {
            GLib.Source.remove(this._daemonRestartTimerId);
            this._daemonRestartTimerId = null;
        }
        if (this._proxyOwnerId && this._proxy) {
            this._proxy.disconnect(this._proxyOwnerId);
            this._proxyOwnerId = 0;
        }
        this._stopDaemon();
        this._proxy = null;
        this._settings = null;
    }

    // -- Visor -----------------------------------------------------------------

    _buildVisor() {
        // Full-screen, transparent modal layer. Captures input so a click off the
        // band (or Escape) dismisses — our stand-in for focus-loss.
        this._visor = new St.Widget({
            style_class: 'strata-visor',
            reactive: true,
            visible: false,
            layout_manager: new Clutter.BinLayout(),
        });

        this._band = new St.BoxLayout({
            style_class: 'strata-visor-band',
            vertical: true,
            x_expand: true,
            reactive: true,
        });

        // Header: search box (search-first) + a gear that opens our prefs.
        const header = new St.BoxLayout({style_class: 'strata-visor-header', x_expand: true});
        this._searchEntry = new St.Entry({
            style_class: 'strata-search',
            hint_text: 'Search clipboard…',
            x_expand: true,
            can_focus: true,
        });
        this._searchEntry.get_clutter_text().connect('text-changed', () => {
            this._shelf?.setQuery(this._searchEntry.get_text());
        });
        // Enter while typing copies the top result (focus never left the box).
        this._searchEntry.get_clutter_text().connect('activate', () => {
            this._shelf?.activatePick(null);
        });
        header.add_child(this._searchEntry);

        // In-UI settings (req #5): the gear opens our prefs window directly via
        // openPreferences() — no detour through the GNOME Extensions app. Dismiss
        // the visor first so its modal grab doesn't fight the prefs window.
        this._gearButton = new St.Button({
            style_class: 'strata-gear',
            child: new St.Icon({icon_name: 'emblem-system-symbolic', icon_size: 18}),
            can_focus: true,
            reactive: true,
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._gearButton.connect('clicked', () => this._onGearClicked());
        header.add_child(this._gearButton);

        // The shelf renders clipboard history as a horizontal band of cards,
        // paginated from the daemon and loaded on each open. onPick dismisses
        // the visor after a copy.
        this._shelf = new Shelf(this._proxy, this._settings, {
            onPick: () => this._hideVisor(),
            peekHost: this._visor,
        });

        this._band.add_child(header);
        this._band.add_child(this._shelf.actor);
        this._visor.add_child(this._band);

        Main.layoutManager.addChrome(this._visor);

        // Space → Peek is handled in the CAPTURE phase: it must intercept the key
        // before the focused card (an St.Button) activates-on-Space and copies.
        // While a Peek is open it owns the keyboard — Space/Escape dismiss it and
        // every other key is swallowed so the shelf/search don't react underneath.
        this._visor.connect('captured-event', (_actor, event) => {
            if (event.type() !== Clutter.EventType.KEY_PRESS)
                return Clutter.EVENT_PROPAGATE;
            const sym = event.get_key_symbol();
            const shelf = this._shelf;
            const isSpace = sym === Clutter.KEY_space || sym === Clutter.KEY_KP_Space;
            if (shelf?.isPeeking()) {
                if (isSpace || sym === Clutter.KEY_Escape)
                    shelf.closePeek();
                return Clutter.EVENT_STOP;
            }
            // Peek the focused Card. With no card focused (focus in search) let
            // Space through so it types a space into the search box.
            if (isSpace && shelf?.peekFocused())
                return Clutter.EVENT_STOP;
            // Arrow navigation across the horizontal shelf. We MUST intercept in
            // the capture phase: the search entry's own ClutterText consumes
            // Left/Right for its text cursor before a bubble-phase handler would
            // ever see them (that was the "stuck in search" bug). The trade is
            // that arrows navigate cards instead of moving the search cursor —
            // expected for a launcher (Home/End/Backspace still edit the query).
            const searchText = this._searchEntry?.get_clutter_text();
            if (sym === Clutter.KEY_Right) {
                shelf?.moveFocus(1);   // search → first card, then card → card
                return Clutter.EVENT_STOP;
            }
            if (sym === Clutter.KEY_Left) {
                // moveFocus returns false when stepping left off the first card →
                // hand focus back to the search box.
                if (!shelf?.moveFocus(-1) && searchText)
                    global.stage.set_key_focus(searchText);
                return Clutter.EVENT_STOP;
            }
            return Clutter.EVENT_PROPAGATE;
        });

        this._visor.connect('key-press-event', (_actor, event) => {
            const sym = event.get_key_symbol();
            const state = event.get_state();
            if (sym === Clutter.KEY_Escape) {
                this._hideVisor();
                return Clutter.EVENT_STOP;
            }
            // Enter reaches the visor only when no card consumed it (i.e. focus is
            // in the search box or nowhere) → copy the top result.
            if (sym === Clutter.KEY_Return || sym === Clutter.KEY_KP_Enter) {
                this._shelf?.activatePick(global.stage.get_key_focus());
                return Clutter.EVENT_STOP;
            }
            // Alt+1…9 → copy the Nth visible card (Alt so plain digits type into search).
            if ((state & Clutter.ModifierType.MOD1_MASK) &&
                sym >= Clutter.KEY_1 && sym <= Clutter.KEY_9) {
                this._shelf?.activateVisibleIndex(sym - Clutter.KEY_1 + 1);
                return Clutter.EVENT_STOP;
            }
            // Left/Right (card navigation) are handled in the capture phase above,
            // because the search entry would otherwise swallow them for its cursor.
            return Clutter.EVENT_PROPAGATE;
        });
        // Click on the layer but outside the band → dismiss.
        this._visor.connect('button-press-event', (_actor, event) => {
            const [, y] = event.get_coords();
            const [bandY] = this._band.get_transformed_position();
            const bandH = this._band.get_height();
            if (y < bandY || y > bandY + bandH)
                this._hideVisor();
            return Clutter.EVENT_STOP;
        });
    }

    _positionVisor() {
        const m = Main.layoutManager.primaryMonitor;
        const h = this._settings.get_int('visor-height');
        const edge = this._settings.get_string('visor-edge');

        // The layer covers the whole monitor; the band is a fixed-height strip
        // pinned to the chosen edge. We let the visor's BinLayout place the band
        // via alignment (FILL across, START/END to the edge) rather than absolute
        // coords — a child's set_y is ignored under a layout manager, and a FILL
        // y-align would stretch the band to full height (so set_height is moot).
        this._visor.set_position(m.x, m.y);
        this._visor.set_size(m.width, m.height);

        this._band.set_height(h);
        this._band.x_align = Clutter.ActorAlign.FILL;
        this._band.y_align = edge === 'top' ? Clutter.ActorAlign.START : Clutter.ActorAlign.END;
    }

    /** Gear handler: drop the modal grab, then open our prefs in-UI (req #5). */
    _onGearClicked() {
        this._hideVisor();
        this.openPreferences();
    }

    _toggleVisor() {
        this._visorVisible ? this._hideVisor() : this._showVisor();
    }

    _showVisor() {
        if (this._visorVisible || !this._visor)
            return;
        this._positionVisor();
        this._visor.show();
        this._visorVisible = true;
        // Instant — no animation (ADR-0004). Grab keyboard so Escape works.
        this._grab = Main.pushModal(this._visor, {actionMode: Shell.ActionMode.NORMAL});
        this._shelf?.load();   // pull current history (page 0) on every summon
        // Search-first: each summon starts in browse with an empty, focused box.
        // (load() already shows browse; clearing leftover text just resets the UI.)
        this._searchEntry?.set_text('');
        // Focus must be deferred one tick: set synchronously right after pushModal
        // it doesn't stick (the modal grab settles focus after we return).
        GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
            if (this._visorVisible && this._searchEntry)
                global.stage.set_key_focus(this._searchEntry.get_clutter_text());
            return GLib.SOURCE_REMOVE;
        });
        console.log('[Strata UI] visor shown');
    }

    _hideVisor() {
        if (!this._visorVisible)
            return;
        this._shelf?.closePeek();   // never leave a Peek hanging behind a hidden visor
        if (this._grab) {
            Main.popModal(this._grab);
            this._grab = null;
        }
        this._visor?.hide();
        this._visorVisible = false;
    }

    // -- Settings: live layout + theme (feature 008) ---------------------------

    /** React to prefs changes without a re-enable: layout keys re-flow the visor
     *  (live if open, else on next summon), the theme re-toggles its CSS class.
     *  Cheap signal handlers only — nothing here blocks the main loop. */
    _watchSettings() {
        const onLimitsChanged = () => { this._readSizeLimits(); this._pushConfig(); };
        this._settingsIds = [
            this._settings.connect('changed::visor-edge', () => this._relayoutVisor()),
            this._settings.connect('changed::visor-height', () => this._relayoutVisor()),
            this._settings.connect('changed::card-width', () =>
                this._shelf?.setCardWidth(this._settings.get_int('card-width'))),
            this._settings.connect('changed::theme', () => this._applyTheme()),
            this._settings.connect('changed::max-history', onLimitsChanged),
            this._settings.connect('changed::max-text-mb', onLimitsChanged),
            this._settings.connect('changed::max-image-mb', onLimitsChanged),
        ];
        // 'auto' theme follows the system light/dark preference.
        this._interfaceSettings = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
        this._interfaceThemeId = this._interfaceSettings.connect('changed::color-scheme', () => {
            if (this._settings.get_string('theme') === 'auto') this._applyTheme();
        });
        this._applyTheme();   // set the initial class
    }

    _unwatchSettings() {
        if (this._settingsIds && this._settings) {
            for (const id of this._settingsIds) this._settings.disconnect(id);
        }
        this._settingsIds = null;
        if (this._interfaceThemeId && this._interfaceSettings) {
            this._interfaceSettings.disconnect(this._interfaceThemeId);
        }
        this._interfaceThemeId = 0;
        this._interfaceSettings = null;
    }

    _relayoutVisor() {
        if (this._visorVisible) this._positionVisor();   // else picked up on next open
    }

    /** Theme via class-toggle (ADR/req): swap a single CSS class on the visor —
     *  never re-parse markup. 'auto' resolves against the system color-scheme. */
    _applyTheme() {
        if (!this._visor) return;
        const resolved = this._resolveTheme();
        this._visor.remove_style_class_name('strata-theme-light');
        this._visor.remove_style_class_name('strata-theme-dark');
        this._visor.add_style_class_name(`strata-theme-${resolved}`);
    }

    _resolveTheme() {
        const theme = this._settings.get_string('theme');
        if (theme === 'light' || theme === 'dark') return theme;
        // auto: prefer-dark → dark; default / prefer-light → light.
        let scheme = 'default';
        try { scheme = this._interfaceSettings?.get_string('color-scheme') ?? 'default'; } catch (_) {}
        return scheme === 'prefer-dark' ? 'dark' : 'light';
    }

    // -- Shortcut --------------------------------------------------------------

    _registerShortcut() {
        Main.wm.addKeybinding(
            'keyboard-shortcut',
            this._settings,
            Meta.KeyBindingFlags.IGNORE_AUTOREPEAT,
            Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW | Shell.ActionMode.POPUP,
            () => this._toggleVisor()
        );
    }

    _unregisterShortcut() {
        Main.wm.removeKeybinding('keyboard-shortcut');
    }

    // -- Live updates: daemon signals (feature 009) ----------------------------

    /** Subscribe to the daemon's three signals on the session bus. We subscribe
     *  by name (not through the proxy) so it works even before the proxy settles;
     *  each callback unpacks and forwards to a plain handler the harness can call. */
    _connectSignals() {
        const IFACE = 'dev.edu4rdshl.Strata.Manager';
        const sub = (name, cb) => Gio.DBus.session.signal_subscribe(
            BUS_NAME, IFACE, name, OBJECT_PATH, null, Gio.DBusSignalFlags.NONE, cb);
        this._signalIds = [
            sub('ItemAdded', (_c, _s, _p, _i, _sig, params) => {
                const [id, mime, preview] = params.deepUnpack();
                this._handleItemAdded(id, mime, preview);
            }),
            sub('ItemDeleted', (_c, _s, _p, _i, _sig, params) => {
                const [id] = params.deepUnpack();
                this._handleItemDeleted(id);
            }),
            sub('HistoryCleared', () => this._handleHistoryCleared()),
        ];
    }

    _disconnectSignals() {
        if (this._signalIds) {
            for (const id of this._signalIds) Gio.DBus.session.signal_unsubscribe(id);
        }
        this._signalIds = null;
    }

    /** ItemAdded(id, mime, preview): drop it if the app that had focus when it was
     *  copied is excluded (the daemon can't see GNOME focus, so the UI enforces it
     *  and removes the stored item); otherwise prepend a card (the shelf debounces
     *  bursts). The signal carries only a preview — has_thumbnail is inferred. */
    _handleItemAdded(id, mime, preview) {
        if (this._isExcludedApp(this._currentFocusedApp)) {
            this._proxy?.DeleteItemAsync(id)?.catch?.(() => {}); // best-effort
            return;
        }
        this._shelf?.onItemAdded({
            id,
            mime_type: mime ?? '',
            content_text: preview ?? '',
            created_at: 0,
            has_thumbnail: (mime ?? '').startsWith('image/'),
        });
    }

    _handleItemDeleted(id) { this._shelf?.onItemDeleted(id); }
    _handleHistoryCleared() { this._shelf?.onHistoryCleared(); }

    /** True if a wm_class matches any excluded-apps substring (case-insensitive). */
    _isExcludedApp(appClass) {
        if (!appClass) return false;
        return this._settings.get_strv('excluded-apps')
            .some(ex => appClass.includes(ex.toLowerCase()));
    }

    /** Track the focused window's wm_class so ItemAdded can honor excluded-apps. */
    _connectFocusTracking() {
        const read = () =>
            (global.display.focus_window?.get_wm_class() ?? '').toLowerCase();
        this._currentFocusedApp = read();
        this._focusSignalId = global.display.connect('notify::focus-window',
            () => { this._currentFocusedApp = read(); });
    }

    _disconnectFocusTracking() {
        if (this._focusSignalId) {
            global.display.disconnect(this._focusSignalId);
            this._focusSignalId = null;
        }
    }

    // -- Clipboard capture (slice 010, lifted from strata@edu4rdshl.dev) --------
    //
    // The Rust daemon can only monitor the clipboard on wlroots compositors
    // (ext/wlr-data-control); Mutter exposes neither, so on GNOME the extension
    // is the capture agent. Watch the Meta selection (GNOME-native, no Wayland
    // protocol needed), read each new payload off the main thread, and hand the
    // raw bytes to the daemon via SubmitItem. Without this, copies made in other
    // apps never reach Strata.

    /** Read text/image size caps from settings into bytes (also pushed to the
     *  daemon via SetConfig so the History prefs actually take effect). */
    _readSizeLimits() {
        this._maxTextBytes  = this._settings.get_int('max-text-mb')  * 1024 * 1024;
        this._maxImageBytes = this._settings.get_int('max-image-mb') * 1024 * 1024;
    }

    /** Push runtime limits to the daemon. Safe before the proxy is ready / after
     *  the daemon has gone away (the optional-chained call is a no-op then). */
    _pushConfig() {
        this._proxy?.SetConfigRemote?.(
            this._settings.get_int('max-history'),
            this._maxTextBytes,
            this._maxImageBytes,
            () => {});
    }

    _connectClipboardMonitor() {
        const selection = global.display.get_selection();
        this._selectionChangedId = selection.connect('owner-changed', (_sel, type) => {
            if (type !== Meta.SelectionType.SELECTION_CLIPBOARD) return;
            this._scheduleClipboardRead();
        });
    }

    _disconnectClipboardMonitor() {
        if (this._clipboardDebounceId !== null) {
            GLib.Source.remove(this._clipboardDebounceId);
            this._clipboardDebounceId = null;
        }
        this._clipboardTransferPending = false;
        if (this._selectionChangedId !== null) {
            global.display.get_selection().disconnect(this._selectionChangedId);
            this._selectionChangedId = null;
        }
    }

    /** Coalesce rapid clipboard changes (apps that write the selection several
     *  times per copy) into one read. */
    _scheduleClipboardRead() {
        if (this._clipboardDebounceId !== null) {
            GLib.Source.remove(this._clipboardDebounceId);
            this._clipboardDebounceId = null;
        }
        this._clipboardDebounceId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 50, () => {
            this._clipboardDebounceId = null;
            this._readClipboard();
            return GLib.SOURCE_REMOVE;
        });
    }

    /** One transfer at a time: read the current clipboard's best MIME off-thread
     *  and SubmitItem the raw bytes to the daemon (which hashes, dedups, prunes).
     *  Skips password-manager secrets and anything over the size cap. */
    _readClipboard() {
        if (this._clipboardTransferPending) return;
        const selection = global.display.get_selection();
        const mimes = selection.get_mimetypes(Meta.SelectionType.SELECTION_CLIPBOARD);
        // Password managers (KeePassXC etc.) tag secrets with this hint mime;
        // honoring it keeps passwords out of history.
        if (mimes.includes('x-kde-passwordManagerHint')) return;
        const mime = this._pickMime(mimes);
        if (!mime) return;

        this._clipboardTransferPending = true;
        const outputStream = Gio.MemoryOutputStream.new_resizable();
        selection.transfer_async(
            Meta.SelectionType.SELECTION_CLIPBOARD, mime, -1, outputStream, null,
            (_obj, result) => {
                this._clipboardTransferPending = false;
                try {
                    selection.transfer_finish(result);
                    outputStream.close(null);
                    const bytes = outputStream.steal_as_bytes();
                    const size = bytes.get_size();
                    if (size === 0) return;
                    if (size > (mime.startsWith('image/') ? this._maxImageBytes : this._maxTextBytes))
                        return;
                    // Raw `ay` to the daemon — no synchronous base64 on the main thread.
                    this._proxy?.SubmitItemRemote?.(mime, bytes.get_data(), () => {});
                } catch (e) {
                    console.error('[Strata UI] clipboard read error:', e);
                }
            });
    }

    /** Pick the best MIME to store from the offered list (mirrors the daemon's
     *  pick_mime / the original extension). Allowlist only — reading an unknown
     *  type could pull a huge blob into Shell memory before the size check. */
    _pickMime(mimes) {
        const PREFERRED = [
            'image/png', 'image/jpeg', 'image/jpg', 'image/gif', 'image/webp',
            'image/bmp', 'image/tiff', 'image/x-icon',
            'text/plain;charset=utf-8', 'UTF8_STRING',
            'text/plain', 'STRING', 'TEXT',
            'text/html', 'text/rtf', 'application/rtf', 'text/markdown',
            'x-special/gnome-copied-files', 'x-special/nautilus-clipboard',
            'application/x-kde-cutselection', 'text/uri-list',
        ];
        for (const want of PREFERRED)
            if (mimes.includes(want)) return want;
        return null;
    }

    // -- Daemon supervision (lifted from strata@edu4rdshl.dev, ADR-0001) --------

    _spawnDaemon() {
        if (this._shuttingDown || this._spawnPending)
            return;
        this._spawnPending = true;
        // If the bus name is already owned (e.g. systemd unit, or Strata's own
        // extension), reuse it — never run a second daemon.
        Gio.DBus.session.call(
            'org.freedesktop.DBus', '/org/freedesktop/DBus',
            'org.freedesktop.DBus', 'GetNameOwner',
            new GLib.Variant('(s)', [BUS_NAME]),
            null, Gio.DBusCallFlags.NONE, 2000, null,
            (conn, result) => {
                this._spawnPending = false;
                if (this._shuttingDown)
                    return;
                try {
                    conn.call_finish(result);
                    console.log('[Strata UI] daemon already running, skipping spawn');
                } catch (_) {
                    this._doSpawnDaemon();
                }
            }
        );
    }

    _doSpawnDaemon() {
        if (this._shuttingDown)
            return;
        const path = GLib.find_program_in_path('strata-daemon');
        if (!path) {
            console.error('[Strata UI] strata-daemon not found in PATH.');
            this._notifyDaemonMissing();
            return;
        }
        try {
            this._daemon = new Gio.Subprocess({argv: [path], flags: Gio.SubprocessFlags.NONE});
            this._daemon.init(null);
            this._daemonSpawnTime = GLib.get_monotonic_time() / 1000;
            this._daemon.wait_async(null, proc => this._onDaemonExited(proc));
        } catch (e) {
            console.error('[Strata UI] failed to spawn daemon:', e);
            this._scheduleDaemonRestart();
        }
    }

    _onDaemonExited(proc) {
        if (!this._daemon || proc !== this._daemon)
            return;
        const exit = proc.get_exit_status();
        const lifetimeMs = (GLib.get_monotonic_time() / 1000) - this._daemonSpawnTime;
        this._daemon = null;
        if (this._shuttingDown)
            return;
        if (lifetimeMs >= 5000)
            this._daemonRestartAttempts = 0;
        this._daemonRestartAttempts++;
        console.error(`[Strata UI] daemon exited (status ${exit}, ${Math.round(lifetimeMs)}ms, attempt ${this._daemonRestartAttempts})`);
        if (this._daemonRestartAttempts > 5) {
            console.error('[Strata UI] daemon crash-looping — giving up. Re-enable to retry.');
            return;
        }
        this._scheduleDaemonRestart();
    }

    _scheduleDaemonRestart() {
        if (this._shuttingDown)
            return;
        const backoffMs = 1000 * Math.pow(2, Math.max(0, this._daemonRestartAttempts - 1));
        this._daemonRestartTimerId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, backoffMs, () => {
            this._daemonRestartTimerId = null;
            this._spawnDaemon();
            return GLib.SOURCE_REMOVE;
        });
    }

    _stopDaemon() {
        if (!this._daemon)
            return;
        const daemonToStop = this._daemon;
        this._daemon = null;
        try {
            this._proxy?.ShutdownRemote(() => {});
        } catch (_) {}
        this._daemonKillTimerId = GLib.timeout_add(GLib.PRIORITY_LOW, 1500, () => {
            this._daemonKillTimerId = null;
            try { daemonToStop.send_signal(15); } catch (_) {}
            return GLib.SOURCE_REMOVE;
        });
    }

    _connectProxy() {
        try {
            this._proxy = new StrataProxy(
                Gio.DBus.session, BUS_NAME, OBJECT_PATH,
                (proxy, error) => {
                    if (error) {
                        console.error('[Strata UI] D-Bus proxy error:', error);
                        return;
                    }
                    this._pushConfig();   // apply size caps to the daemon now…
                    this._proxyOwnerId = proxy.connect('notify::g-name-owner',
                        () => { if (proxy.g_name_owner) this._pushConfig(); }); // …and on every respawn
                }
            );
        } catch (e) {
            console.error('[Strata UI] failed to create D-Bus proxy:', e);
        }
    }

    _notifyDaemonMissing() {
        try {
            const source = new MessageTray.Source({
                title: 'Strata UI',
                icon: new St.Icon({icon_name: 'edit-paste-symbolic'}),
            });
            Main.messageTray.add(source);
            source.addNotification(new MessageTray.Notification({
                source,
                title: 'Strata UI: daemon not found',
                body: 'Install strata-daemon to enable clipboard history.',
                urgency: MessageTray.Urgency.HIGH,
            }));
        } catch (_) {}
    }
}
