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

    enable() {
        this._settings = this.getSettings();
        this._shuttingDown = false;
        this._daemonRestartAttempts = 0;
        if (this._daemonKillTimerId) {
            GLib.Source.remove(this._daemonKillTimerId);
            this._daemonKillTimerId = null;
        }

        this._spawnDaemon();      // Rust daemon (supervised); shared with Strata.
        this._connectProxy();     // async — never blocks if the daemon isn't up yet.
        this._buildVisor();
        this._registerShortcut();
        console.log('[Strata UI] enabled');
    }

    disable() {
        this._shuttingDown = true;
        this._unregisterShortcut();
        this._hideVisor();
        this._shelf?.destroy();
        this._shelf = null;
        this._visor?.destroy();   // also destroys the band child
        this._visor = null;
        this._band = null;
        this._searchEntry = null;
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

        // Header: search box (search-first). The gear button arrives in 008.
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

        // The shelf renders clipboard history as a horizontal band of cards,
        // paginated from the daemon and loaded on each open. onPick dismisses
        // the visor after a copy.
        this._shelf = new Shelf(this._proxy, this._settings, {onPick: () => this._hideVisor()});

        this._band.add_child(header);
        this._band.add_child(this._shelf.actor);
        this._visor.add_child(this._band);

        Main.layoutManager.addChrome(this._visor);

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
            // Left/Right move focus into and across the shelf.
            if (sym === Clutter.KEY_Left || sym === Clutter.KEY_Right) {
                this._shelf?.moveFocus(sym === Clutter.KEY_Right ? 1 : -1);
                return Clutter.EVENT_STOP;
            }
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

        // Layer covers the whole monitor; band is pinned to the chosen edge.
        this._visor.set_position(m.x, m.y);
        this._visor.set_size(m.width, m.height);

        this._band.set_width(m.width);
        this._band.set_height(h);
        this._band.set_x(0);
        this._band.set_y(edge === 'top' ? 0 : m.height - h);
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
        if (this._grab) {
            Main.popModal(this._grab);
            this._grab = null;
        }
        this._visor?.hide();
        this._visorVisible = false;
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
                    this._proxyOwnerId = proxy.connect('notify::g-name-owner', () => {});
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
