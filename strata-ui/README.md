# Strata UI

A horizontal **shelf** front-end for the [Strata](https://github.com/Edu4rdSHL/Strata) clipboard
daemon — an alternative GNOME Shell extension that shows clipboard history as a Quake-style,
full-width **visor** of rich, readable cards (Copyous / Paste-for-Mac style) instead of Strata's
vertical dropdown. It talks to the existing Strata daemon over D-Bus; the daemon is unchanged
(v1 is UI-only).

**Status:** design + autonomous test harness complete; extension implementation not started.

- Glossary: [CONTEXT.md](./CONTEXT.md)
- Spec: [docs/v1-spec.md](./docs/v1-spec.md) · Decisions: [docs/adr/](./docs/adr/) · References: [docs/reference/](./docs/reference/)
- Build plan: [docs/tasks.json](./docs/tasks.json) — 9 tracer-bullet vertical slices
- Upstream context: [Edu4rdSHL/Strata#3](https://github.com/Edu4rdSHL/Strata/issues/3)

## Developing

### Live install
`test-harness/init.sh` symlinks the extension (`extension/`, UUID `strata-ui@elijahlynn.net`) into
`~/.local/share/gnome-shell/extensions/` for live reload, compiles schemas, and checks that
`strata-daemon` is on `PATH`. On Wayland, pick up changes with a logout/in — or test in the headless
nested shell below.

### Autonomous test harness
The build loop verifies each feature in a throwaway, **headless GNOME Shell** it can **screenshot**
and **drive with keystrokes** — closed-loop, no human. Pattern adapted from copyous's `make bench`;
loop methodology from
[Anthropic — effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents).

| File | Role |
|---|---|
| `test-harness/launch-nested.sh` | throwaway headless shell + driver functions |
| `test-harness/test-ext/strata-harness@local/` | helper that unlocks Eval + Screenshot (see note) |
| `test-harness/loop.sh` | picks the next ready feature, dispatches an autonomous `claude` agent |
| `test-harness/init.sh` | live-reload install into your real session |

The nested shell is `gnome-shell --headless --virtual-monitor 1280x720 --wayland` under
`dbus-run-session` with a temp `XDG_*` profile: an offscreen framebuffer (observe via screenshots,
no window), and the daemon it spawns writes to the temp profile — **never your real clipboard**.

> `MUTTER_DEBUG_DUMMY_MODE_SPECS` is ignored on GNOME ≥ 49 (gives a 0×0 stage). Use
> `--headless --virtual-monitor WxH` for a real, screenshot-able framebuffer.

Driver functions (`source test-harness/launch-nested.sh`):

```sh
nested_up [WxH] [EXTRA_EXT_DIR]   nested_eval "<js>"          nested_key space
nested_type "hi"                  nested_screenshot out.png   nested_enable_ext <uuid>   nested_down
```

Self-test: `bash test-harness/launch-nested.sh --smoke` (brings the shell up, screenshots, tears down).

**Requirements:** `mutter-devkit` (GNOME ≥ 49), `gnome-shell`, `gdbus`, `dbus-run-session`, `jq`, `sqlite3`.

#### ⚠️ The unsafe-mode helper
`test-harness/test-ext/strata-harness@local` sets `global.context.unsafe_mode = true` — a deliberate
security-mitigation toggle that unlocks `org.gnome.Shell.Eval` (arbitrary JS) and bypasses the
screenshot sender-check, the two capabilities the loop needs to drive + observe the shell. It loads
**only** inside the disposable headless nested session the harness spawns (own temp profile + private
bus, destroyed after each run), **never** a real desktop session. Explicitly authorized for autonomous
testing.
