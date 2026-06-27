#!/usr/bin/env -S gjs -m
//
// prefs-construct.js — headlessly construct the REAL Strata UI preferences UI
// against the running GNOME's libadwaita, to prove prefs.js builds cleanly
// (feature 013). The OpenExtensionPrefs D-Bus path can't be used for this: the
// prefs window is built in a *separate* process whose errors never reach the
// nested shell's log (verified — a deliberately broken prefs.js produced no log
// error and OpenExtensionPrefs still returned success). So we build the UI here,
// in-process, where a failing Adw/Gtk widget throws and fails the run.
//
// Usage:  gjs -m prefs-construct.js <schemas-dir> <path-to-prefs.js>
//   <schemas-dir>  a directory containing the compiled gschemas.compiled
//   exits 0 + prints PREFS-CONSTRUCT-OK on success; non-zero on any throw.
//
// prefs.js imports ExtensionPreferences from a gnome-shell GResource that only
// exists inside the shell's gjs. We strip that import + the `extends` clause so
// the exact same widget-construction code runs standalone; getSettings() is then
// supplied from the real compiled schema. Every Adw/Gtk row is built for real.

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import System from 'system';

const [SCHEMA_DIR, PREFS_JS] = ARGV;
if (!SCHEMA_DIR || !PREFS_JS) {
    printerr('usage: prefs-construct.js <schemas-dir> <prefs.js>');
    System.exit(2);
}

function fail(code, msg) {
    printerr(`PREFS-CONSTRUCT-FAIL: ${msg}`);
    System.exit(code);
}

// Real Gio.Settings from the shipped, compiled schema.
const source = Gio.SettingsSchemaSource.new_from_directory(
    SCHEMA_DIR, Gio.SettingsSchemaSource.get_default(), false);
const schema = source.lookup('org.gnome.shell.extensions.strata-ui', false);
if (!schema)
    fail(3, 'gschema org.gnome.shell.extensions.strata-ui not found in ' + SCHEMA_DIR);
const settings = new Gio.Settings({settings_schema: schema});

// Load prefs.js and neutralize the shell-only resource import + base class so the
// widget-building code runs here unchanged.
const [ok, bytes] = GLib.file_get_contents(PREFS_JS);
if (!ok)
    fail(3, 'cannot read ' + PREFS_JS);
let srcText = new TextDecoder().decode(bytes)
    .replace(/import\s*\{\s*ExtensionPreferences\s*\}\s*from\s*'resource:[^']*';/,
             '/* ExtensionPreferences import stripped for standalone construction */')
    .replace(/export default class StrataUIPreferences extends ExtensionPreferences/,
             'export default class StrataUIPreferences');

const tmpDir = GLib.dir_make_tmp('strata-prefs-shim-XXXXXX');
const shim = GLib.build_filenamev([tmpDir, 'prefs-shim.mjs']);
GLib.file_set_contents(shim, srcText);

Gtk.init();
Adw.init();

let exitCode = 0;
try {
    const {default: StrataUIPreferences} = await import('file://' + shim);
    const prefs = new StrataUIPreferences();
    prefs.getSettings = () => settings;   // stands in for ExtensionPreferences.getSettings

    // Build both pages exactly as fillPreferencesWindow does (General + Privacy).
    const win = new Adw.PreferencesWindow();
    prefs.fillPreferencesWindow(win);

    // Also build the keyboard-shortcut dialog (the Adw.MessageDialog the feature
    // flagged) — construction only; the process exits before it can render.
    if (typeof prefs._showShortcutDialog === 'function')
        prefs._showShortcutDialog(win, settings);

    print('PREFS-CONSTRUCT-OK');
} catch (e) {
    printerr('PREFS-CONSTRUCT-FAIL: ' + (e?.stack ?? e));
    exitCode = 1;
} finally {
    GLib.unlink(shim);
    GLib.rmdir(tmpDir);
}
System.exit(exitCode);
