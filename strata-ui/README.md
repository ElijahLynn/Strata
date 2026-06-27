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

Install into your own session to try by hand (the loop doesn't need this):
```sh
bash test-harness/install.sh     # symlinks extension/ → ~/.local/share/.../extensions, compiles schemas
# Wayland: log out/in, then `gnome-extensions enable strata-ui@elijahlynn.net`, Ctrl+Alt+C
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

Autonomous build loop — one agent works `tasks.json` top to bottom, verifying each feature:
```sh
claude --print "$(cat test-harness/coding-prompt.md)" --dangerously-skip-permissions
```
At larger scale, give each feature a fresh context (outer loop) instead — **bash**, capped so a
feature that never passes can't spin forever:
```bash
max=20; n=0
while jq --exit-status '.features[]|select(.passes==false)' docs/tasks.json >/dev/null; do
  n=$((n + 1)); [ "$n" -gt "$max" ] && { echo "stopped at max-iterations $max"; break; }
  cat test-harness/coding-prompt.md | claude --print --dangerously-skip-permissions
done
```
Each session: pick next `passes:false` (deps met) → build in `extension/` → verify in the nested
shell → flip `passes` → commit. Stops when all pass; Ctrl+C to pause, re-run to resume.
(`test-harness/loop.sh` = one iteration of the above.)

Needs: `mutter-devkit` (GNOME ≥49), `gnome-shell`, `gdbus`, `dbus-run-session`, `jq`, `sqlite3`.

Gotchas:
- Use `--headless --virtual-monitor WxH`. `MUTTER_DEBUG_DUMMY_MODE_SPECS` = 0×0 on GNOME ≥49.
- Don't `pgrep`/`pkill -f 'gnome-shell...'` — matches stale shells + your own cmdline. Harness uses a bus file + `setsid`.

#### ⚠️ unsafe-mode helper
`test-ext/strata-harness@local` sets `global.context.unsafe_mode = true` → unlocks Eval + Screenshot.
Loads **only** in the throwaway nested shell (own temp profile + bus, destroyed each run), never a real
session. Authorized for testing.
