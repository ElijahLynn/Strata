# Strata UI — test harness

A **closed, autonomous** verification harness: it runs each feature in a throwaway,
**headless GNOME Shell** that it can **screenshot** and **drive with keystrokes**, so the
coding loop verifies its own work with no human in the loop.

Pattern adapted from copyous's `make bench` (nested-shell + drive-over-D-Bus); see that repo's
`CONTRIBUTING.md`. Loop methodology: [Anthropic — effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents).

## Pieces

| File | Role |
|---|---|
| `launch-nested.sh` | Reusable throwaway headless shell + driver functions |
| `test-ext/strata-harness@local/` | Helper extension that unlocks Eval + Screenshot (see security note) |
| `loop.sh` | Picks the next ready feature, dispatches an autonomous `claude` agent |
| `init.sh` | One-shot live-reload install of the extension into your real session |

## How the nested shell works

`gnome-shell --headless --virtual-monitor 1280x720 --wayland`, launched under
`dbus-run-session` with a temp `XDG_*` profile. It renders to an offscreen framebuffer (no
window — observe it via screenshots), and the daemon the extension spawns writes to the temp
profile, **never your real clipboard**.

> Note: `MUTTER_DEBUG_DUMMY_MODE_SPECS` is ignored on GNOME ≥ 49 (gives a 0×0 stage). Use
> `--headless --virtual-monitor WxH` — that produces a real, screenshot-able framebuffer.

## Driver functions (`source launch-nested.sh`)

```sh
nested_up [WxH] [EXTRA_EXT_DIR]   # launch; exports NESTED_BUS, NESTED_TMP
nested_eval  "<js>"               # run JS in the shell (Eval)
nested_key   space                # press+release a key (Clutter virtual device)
nested_type  "hello world"        # type a string
nested_screenshot out.png         # capture the stage to PNG
nested_enable_ext <uuid>          # enable an installed extension
nested_down                       # kill the shell, remove the temp profile
```

Self-test: `bash launch-nested.sh --smoke` → brings the shell up, screenshots it, tears down.

## Requirements

`mutter-devkit` (GNOME ≥ 49), `gnome-shell`, `gdbus`, `dbus-run-session`, `jq`, `sqlite3`.

## ⚠️ Security note — the unsafe-mode helper

`test-ext/strata-harness@local` sets `global.context.unsafe_mode = true`. That is a deliberate
**security-mitigation toggle**: it unlocks `org.gnome.Shell.Eval` (arbitrary JS) and bypasses the
screenshot sender-check — the two capabilities the loop needs to drive + observe the shell.

It is loaded **only** inside the disposable, headless nested session this harness spawns (its own
temp profile + private bus), which is destroyed after every run. It is **never** enabled in a real
desktop session. This was explicitly authorized for autonomous testing.
