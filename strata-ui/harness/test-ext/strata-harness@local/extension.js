import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

// Test-harness helper for the autonomous loop. Loaded ONLY inside the disposable,
// headless nested GNOME Shell that harness/launch-nested.sh spawns (its own temp
// XDG profile + private session bus) — never a real desktop session.
//
// It flips unsafe mode on, which is what unlocks two gated capabilities the loop
// needs to verify features without a human:
//   - org.gnome.Shell.Screenshot  (bypasses the DBusSenderChecker)
//   - org.gnome.Shell.Eval        (drive the UI / inject keystrokes via Clutter)
// The nested session is torn down after each test run, so the toggle never persists.
export default class StrataHarness extends Extension {
    enable() {
        global.context.unsafe_mode = true;
    }

    disable() {
        global.context.unsafe_mode = false;
    }
}
