# Strata UI — coding session

Build Strata UI (plain-JS GNOME Shell extension over the Strata daemon), **TDD / red-green**, one
feature at a time until all `passes:true` — or you're low on context, then stop with clean,
committed state.

Per feature:
1. **Catch up:** `claude-progress.txt`, `git log --oneline -10`, `docs/tasks.json`.
2. **Pick:** lowest `id` with `passes:false` whose every `blockedBy` is `passes:true`. None → say "all pass", stop.
3. **Announce.** Immediately append a UTC-timestamped `<ts> — starting <id>: <title>` line to
   `claude-progress.txt` (`ts=$(date --utc +%Y-%m-%dT%H:%M:%SZ)`) so in-flight work is visible
   (no separate commit — it rides the completion commit).
4. **🔴 Red — write the test first.** Turn the feature's `steps` into assertions in
   `test-harness/verify.sh` (its `case "<id>")` block) via `nested_eval` / log markers / the
   screenshot. Run `./test-harness/verify.sh <id>` and confirm it **FAILS** for the right reason
   (the behavior isn't built yet). Don't write impl in this step.
4. **🟢 Green — implement.** Build only that feature in `extension/` (uuid `strata-ui@elijahlynn.net`)
   until `verify.sh <id>` exits 0 and the screenshot looks right. Authoritative: `docs/v1-spec.md`,
   `docs/adr/*`, `docs/reference/*`. Lift daemon supervision + `dbus.js` verbatim from
   `../strata@edu4rdshl.dev/` (ADR-0001). Never touch `../strata-daemon/` (ADR-0003). Honor
   `architecture-constraints.md` (never block the main loop, St.Label only, …).
5. **Flip + commit.** Run `./test-harness/verify.sh all` and require it green (every prior case,
   not just `<id>`). Then set that feature's `passes:true`; `git commit --message "<id>: <title>"`
   (test + impl together); append a UTC-timestamped note (`date --utc +%Y-%m-%dT%H:%M:%SZ`) to
   `claude-progress.txt`. Next feature.

Conventions: plain JS (TS after MVP, ADR-0006); shell scripts use **long options** (`--print`,
`--message`, `--parents`, …) not short ones.
