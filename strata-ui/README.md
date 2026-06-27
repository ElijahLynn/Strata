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

Install for real use (live reload, symlink):
```sh
bash test-harness/init.sh        # links extension/ → ~/.local/share/.../extensions, compiles schemas
# Wayland: log out/in to reload JS
```

Test it (headless nested shell, ~1.5s, never touches your clipboard):
```sh
# launch → screenshot → teardown
SMOKE_OUT=/tmp/shot.png bash test-harness/launch-nested.sh --smoke && xdg-open /tmp/shot.png

# or drive it yourself
source test-harness/launch-nested.sh
nested_up                            # launch (~1.5s)
nested_key space                     # keystroke
sleep 1; nested_screenshot out.png   # capture (sleep = let it paint)
nested_eval "global.context.unsafe_mode"
nested_down                          # kill + clean
```

Autonomous build loop (picks next not-done feature, `claude` builds it):
```sh
bash test-harness/loop.sh
```

Needs: `mutter-devkit` (GNOME ≥49), `gnome-shell`, `gdbus`, `dbus-run-session`, `jq`, `sqlite3`.

Gotchas:
- Use `--headless --virtual-monitor WxH`. `MUTTER_DEBUG_DUMMY_MODE_SPECS` = 0×0 on GNOME ≥49.
- Don't `pgrep`/`pkill -f 'gnome-shell...'` — matches stale shells + your own cmdline. Harness uses a bus file + `setsid`.

#### ⚠️ unsafe-mode helper
`test-ext/strata-harness@local` sets `global.context.unsafe_mode = true` → unlocks Eval + Screenshot.
Loads **only** in the throwaway nested shell (own temp profile + bus, destroyed each run), never a real
session. Authorized for testing.
