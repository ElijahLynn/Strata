/**
 * prefs.js — Strata UI preferences window (GNOME 45+ / Adw).
 *
 * Feature 008: opened in-UI from the gear in the visor header via
 * Extension.openPreferences() — no detour through the GNOME Extensions app.
 *
 * The shortcut dialog and the excluded-apps Privacy page are lifted from
 * strata@edu4rdshl.dev (ADR-0001); the Layout group (visor-edge / visor-height /
 * card-width) is new for the edge visor (ADR-0004).
 *
 * Pages:
 *  General:  Layout (edge/height/card-width), History (limits/size caps),
 *            Appearance (theme), Keyboard (shortcut)
 *  Privacy:  excluded-apps editable list
 */

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';
import Gdk from 'gi://Gdk';
import Gio from 'gi://Gio';

import { ExtensionPreferences } from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

export default class StrataUIPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();
        window.add(this._buildGeneralPage(settings));
        window.add(this._buildPrivacyPage(settings));
    }

    // -------------------------------------------------------------------------
    // General page
    // -------------------------------------------------------------------------

    _buildGeneralPage(settings) {
        const page = new Adw.PreferencesPage({
            title: 'General',
            icon_name: 'preferences-system-symbolic',
        });

        // ── Layout (the edge visor — new keys) ────────────────────────────────
        const layoutGroup = new Adw.PreferencesGroup({
            title: 'Layout',
            description: 'Where the visor sits and how big it is',
        });

        const edges = [
            { id: 'bottom', label: 'Bottom' },
            { id: 'top',    label: 'Top'    },
        ];
        const edgeRow = new Adw.ComboRow({
            title: 'Visor edge',
            subtitle: 'Screen edge the visor band is anchored to',
            model: Gtk.StringList.new(edges.map(e => e.label)),
        });
        const currentEdge = settings.get_string('visor-edge');
        const currentEdgeIdx = edges.findIndex(e => e.id === currentEdge);
        edgeRow.selected = currentEdgeIdx >= 0 ? currentEdgeIdx : 0;
        edgeRow.connect('notify::selected', () => {
            settings.set_string('visor-edge', edges[edgeRow.selected].id);
        });
        settings.connect('changed::visor-edge', () => {
            const idx = edges.findIndex(e => e.id === settings.get_string('visor-edge'));
            if (idx >= 0 && edgeRow.selected !== idx) edgeRow.selected = idx;
        });
        layoutGroup.add(edgeRow);

        const heightRow = new Adw.SpinRow({
            title: 'Visor height',
            subtitle: 'Height of the visor band in pixels',
            adjustment: new Gtk.Adjustment({
                lower: 200, upper: 900, step_increment: 10, page_increment: 50,
            }),
        });
        settings.bind('visor-height', heightRow, 'value', Gio.SettingsBindFlags.DEFAULT);
        layoutGroup.add(heightRow);

        const cardWidthRow = new Adw.SpinRow({
            title: 'Card width',
            subtitle: 'Width of each shelf card in pixels',
            adjustment: new Gtk.Adjustment({
                lower: 200, upper: 600, step_increment: 10, page_increment: 50,
            }),
        });
        settings.bind('card-width', cardWidthRow, 'value', Gio.SettingsBindFlags.DEFAULT);
        layoutGroup.add(cardWidthRow);

        page.add(layoutGroup);

        // ── History (reused Strata keys) ──────────────────────────────────────
        const historyGroup = new Adw.PreferencesGroup({ title: 'History' });

        const maxHistoryRow = new Adw.SpinRow({
            title: 'Maximum items',
            subtitle: 'Older items are deleted past this limit',
            adjustment: new Gtk.Adjustment({
                lower: 50, upper: 2000, step_increment: 10, page_increment: 50,
            }),
        });
        settings.bind('max-history', maxHistoryRow, 'value', Gio.SettingsBindFlags.DEFAULT);
        historyGroup.add(maxHistoryRow);

        const pageSizeRow = new Adw.SpinRow({
            title: 'Items per page',
            subtitle: 'Cards fetched on open and on each scroll toward the end',
            adjustment: new Gtk.Adjustment({
                lower: 20, upper: 200, step_increment: 10, page_increment: 50,
            }),
        });
        settings.bind('page-size', pageSizeRow, 'value', Gio.SettingsBindFlags.DEFAULT);
        historyGroup.add(pageSizeRow);

        const maxTextRow = new Adw.SpinRow({
            title: 'Maximum text size (MB)',
            subtitle: 'Text payloads larger than this are not stored',
            adjustment: new Gtk.Adjustment({
                lower: 1, upper: 100, step_increment: 1, page_increment: 5,
            }),
        });
        settings.bind('max-text-mb', maxTextRow, 'value', Gio.SettingsBindFlags.DEFAULT);
        historyGroup.add(maxTextRow);

        const maxImageRow = new Adw.SpinRow({
            title: 'Maximum image size (MB)',
            subtitle: 'Image payloads larger than this are not stored',
            adjustment: new Gtk.Adjustment({
                lower: 1, upper: 100, step_increment: 1, page_increment: 5,
            }),
        });
        settings.bind('max-image-mb', maxImageRow, 'value', Gio.SettingsBindFlags.DEFAULT);
        historyGroup.add(maxImageRow);

        const moveToTopRow = new Adw.SwitchRow({
            title: 'Move activated item to top',
            subtitle: 'Copying an item moves its card to the front of the shelf',
        });
        settings.bind('move-activated-to-top', moveToTopRow, 'active', Gio.SettingsBindFlags.DEFAULT);
        historyGroup.add(moveToTopRow);

        page.add(historyGroup);

        // ── Appearance (theme — applied via class-toggle by the extension) ─────
        const appearanceGroup = new Adw.PreferencesGroup({ title: 'Appearance' });

        const themes = [
            { id: 'auto',  label: 'Automatic' },
            { id: 'light', label: 'Light'     },
            { id: 'dark',  label: 'Dark'      },
        ];
        const themeRow = new Adw.ComboRow({
            title: 'Theme',
            subtitle: 'Automatic follows the system light/dark preference',
            model: Gtk.StringList.new(themes.map(t => t.label)),
        });
        const currentTheme = settings.get_string('theme');
        const currentThemeIdx = themes.findIndex(t => t.id === currentTheme);
        themeRow.selected = currentThemeIdx >= 0 ? currentThemeIdx : 0;
        themeRow.connect('notify::selected', () => {
            settings.set_string('theme', themes[themeRow.selected].id);
        });
        settings.connect('changed::theme', () => {
            const idx = themes.findIndex(t => t.id === settings.get_string('theme'));
            if (idx >= 0 && themeRow.selected !== idx) themeRow.selected = idx;
        });
        appearanceGroup.add(themeRow);

        page.add(appearanceGroup);

        // ── Keyboard (shortcut — dialog lifted from Strata) ───────────────────
        const kbGroup = new Adw.PreferencesGroup({ title: 'Keyboard' });

        const shortcutRow = new Adw.ActionRow({
            title: 'Toggle Strata UI',
            subtitle: 'Click to change the keyboard shortcut',
            activatable: true,
        });
        const shortcutLabel = new Gtk.ShortcutLabel({
            valign: Gtk.Align.CENTER,
            disabled_text: 'Disabled',
        });
        const updateShortcutLabel = () => {
            const shortcuts = settings.get_strv('keyboard-shortcut');
            shortcutLabel.accelerator = shortcuts[0] ?? '';
        };
        updateShortcutLabel();
        settings.connect('changed::keyboard-shortcut', updateShortcutLabel);
        shortcutRow.add_suffix(shortcutLabel);
        shortcutRow.connect('activated', () => {
            this._showShortcutDialog(shortcutRow.get_root(), settings);
        });
        kbGroup.add(shortcutRow);
        page.add(kbGroup);

        return page;
    }

    // -------------------------------------------------------------------------
    // Privacy page (lifted from strata@edu4rdshl.dev — ADR-0001)
    // -------------------------------------------------------------------------

    _buildPrivacyPage(settings) {
        const page = new Adw.PreferencesPage({
            title: 'Privacy',
            icon_name: 'security-high-symbolic',
        });

        const group = new Adw.PreferencesGroup({
            title: 'App Exclusions',
            description: 'Items copied while these apps have focus are not stored. Enter a partial app name (case-insensitive).',
        });

        const model = new Gtk.StringList();
        for (const app of settings.get_strv('excluded-apps'))
            model.append(app);

        const saveModel = () => {
            const apps = [];
            for (let i = 0; i < model.get_n_items(); i++) {
                const val = model.get_string(i);
                if (val?.trim()) apps.push(val.trim());
            }
            settings.set_strv('excluded-apps', apps);
        };

        const listBox = new Gtk.ListBox({
            selection_mode: Gtk.SelectionMode.NONE,
            css_classes: ['boxed-list'],
        });

        const rebuildList = () => {
            let child = listBox.get_first_child();
            while (child) {
                const next = child.get_next_sibling();
                listBox.remove(child);
                child = next;
            }
            for (let i = 0; i < model.get_n_items(); i++) {
                const idx = i;
                const row = new Adw.ActionRow({ activatable: false });
                const label = new Gtk.EditableLabel({
                    text: model.get_string(i),
                    valign: Gtk.Align.CENTER,
                    hexpand: true,
                });
                label.connect('changed', () => {
                    model.splice(idx, 1, [label.text]);
                    saveModel();
                });
                const removeBtn = new Gtk.Button({
                    icon_name: 'list-remove-symbolic',
                    valign: Gtk.Align.CENTER,
                    css_classes: ['flat', 'destructive-action'],
                    tooltip_text: 'Remove',
                });
                removeBtn.connect('clicked', () => {
                    model.remove(idx);
                    saveModel();
                    rebuildList();
                });
                row.add_suffix(label);
                row.add_suffix(removeBtn);
                listBox.append(row);
            }

            const addRow = new Adw.ActionRow({ activatable: false });
            const addEntry = new Gtk.Entry({
                placeholder_text: 'App name…',
                valign: Gtk.Align.CENTER,
                hexpand: true,
            });
            const addBtn = new Gtk.Button({
                icon_name: 'list-add-symbolic',
                valign: Gtk.Align.CENTER,
                css_classes: ['flat'],
                tooltip_text: 'Add',
            });
            const doAdd = () => {
                const val = addEntry.text.trim();
                if (val) {
                    model.append(val);
                    saveModel();
                    rebuildList();
                }
            };
            addBtn.connect('clicked', doAdd);
            addEntry.connect('activate', doAdd);
            addRow.add_suffix(addEntry);
            addRow.add_suffix(addBtn);
            listBox.append(addRow);
        };

        rebuildList();
        group.add(listBox);
        page.add(group);
        return page;
    }

    // -------------------------------------------------------------------------
    // Keyboard shortcut dialog (lifted from strata@edu4rdshl.dev — ADR-0001)
    // -------------------------------------------------------------------------

    _showShortcutDialog(parent, settings) {
        const dialog = new Adw.MessageDialog({
            heading: 'Set Keyboard Shortcut',
            body: 'Press the desired key combination, or Backspace to clear.',
            transient_for: parent,
            modal: true,
        });
        dialog.add_response('cancel', 'Cancel');
        dialog.add_response('clear',  'Clear');

        const label = new Gtk.ShortcutLabel({
            accelerator: settings.get_strv('keyboard-shortcut')[0] ?? '',
            disabled_text: '(none)',
            margin_top: 12,
            margin_bottom: 12,
            halign: Gtk.Align.CENTER,
        });
        dialog.set_extra_child(label);

        const controller = new Gtk.EventControllerKey();
        controller.connect('key-pressed', (_ctrl, keyval, keycode, state) => {
            const mods = state & Gtk.accelerator_get_default_mod_mask();
            if (keyval === Gdk.KEY_BackSpace) {
                label.accelerator = '';
                return true;
            }
            if (keyval === Gdk.KEY_Escape) {
                dialog.close();
                return true;
            }
            if (Gtk.accelerator_valid(keyval, mods)) {
                label.accelerator = Gtk.accelerator_name(keyval, mods);
                settings.set_strv('keyboard-shortcut',
                    label.accelerator ? [label.accelerator] : []);
                dialog.close();
            }
            return true;
        });
        dialog.add_controller(controller);

        dialog.connect('response', (_d, response) => {
            if (response === 'clear')
                settings.set_strv('keyboard-shortcut', []);
            dialog.destroy();
        });

        dialog.present();
    }
}
