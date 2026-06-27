# AGENTS.md — Strata UI

Guidelines for AI agents working inside `strata-ui/`. The repo-root `../AGENTS.md`
governs the daemon and the original `strata@edu4rdshl.dev` extension; this file
governs the greenfield UI.

## The development pattern (read this first)

Strata UI is built by long-running agents with **finite context windows**. Any
piece of work has to be resumable by a fresh agent who never saw the conversation
that produced it. That only holds if every change goes through the same loop. Do
not freelance fixes from a chat request — even an obvious one-line bug.

1. **Every change is a slice in `docs/tasks.json`.** Found a bug in a live
   session? Want a feature? Add (or update) a feature entry first, in the existing
   schema: `id / title / category / description / steps / blockedBy / refs /
   passes:false`. The task list is the durable memory; the chat window is not. A
   bug that only lives in a chat message is a bug that the next agent will reintroduce.

2. **Every slice carries a headless test step.** A slice is not done until
   `bash test-harness/verify.sh <id>` proves it. When a bug reached a human, the
   first step of its fix-slice is *"add a verify.sh case that reproduces it (RED)"*.
   A fix with no failing-test-first is not allowed — shipping fixes that way is
   exactly how the capture, navigation, paste-back, and gear bugs escaped.

3. **TDD red → green, then flip `passes`, then commit.** Write the test, watch it
   fail, implement in `extension/`, watch it pass, then **run the whole suite —
   `bash test-harness/verify.sh all` — and require it green** (every prior case,
   not just the one you touched; that is what stops regressions). Then set
   `passes:true`, append an entry to `claude-progress.txt` headed by a UTC
   ISO-8601 timestamp (`YYYY-MM-DDThh:mm:ssZ`, from `date --utc +%Y-%m-%dT%H:%M:%SZ`),
   and commit — **one slice per commit**. (`verify.sh all` is built in slice 015;
   until it lands, re-run every prior case by hand.)

4. **Work the highest-priority `passes:false` slice whose `blockedBy` all pass.**
   One slice at a time. Never delete, weaken, or merge a slice to make it pass
   (see the `instructions` field in `docs/tasks.json`).

Why this is strict: context is the bottleneck, not effort. A consistent,
test-gated, one-slice-at-a-time loop is the only thing that lets a fresh agent
resume safely and keeps fixed bugs from coming back.

## Who runs the loop, and who does not

There are two roles, and an agent must know which one it is:

- The **autonomous loop agent** runs `coding-prompt.md` (via `loop.sh`) and
  BUILDS slices test-first. This is the only role that edits `extension/`.
- An **interactive assistant** (a chat/IDE session) helps design slices, wires up
  the harness, reviews, and diagnoses. By default it does NOT build slices and
  does NOT run the loop.

When an interactive session turns up a bug or new work: capture it as a
`tasks.json` slice and **hand off**. Do not freelance-fix it, and do not pre-empt
the loop by building the slice yourself. "Continue", "keep going", or finishing a
setup task is **not** permission to start building — the human decides who runs
the loop and when; if that is unstated, ask. This rule exists because it was
broken: an assistant asked only to set up the slices went and built two of them
itself, spending the context and the loop run the human had reserved.

## Running the loop

`./test-harness/loop.sh` IS the loop — run it from `strata-ui/`. It re-spawns a
fresh coding agent per iteration until every feature is `passes:true`, or a
max-iterations cap is hit (default 20; `loop.sh 50` raises it, `loop.sh 1` does a
single iteration). Two layers:

- **Inner** (one agent): a fresh `claude --print "$(cat coding-prompt.md)"` works
  feature → feature (pick lowest `passes:false` → red → green → `verify.sh all` →
  flip → commit → next) until all pass or it runs low on context, then stops clean.
- **Outer** (`loop.sh` itself): re-spawn a fresh agent — a clean context each time
  — until `jq` finds no `passes:false` left. The cap is the backstop so a feature
  that can never pass can't spin agents (and spend) forever.

Equivalent by hand, minus the cap (so don't leave it unattended):

  ```sh
  cd strata-ui
  while jq -e '.features[]|select(.passes==false)' docs/tasks.json >/dev/null; do
    cat test-harness/coding-prompt.md | claude -p --dangerously-skip-permissions
  done
  ```

## What headless verify can and cannot catch

`test-harness/verify.sh` boots a throwaway nested GNOME Shell and can drive far
more than its name suggests. Before marking anything "needs a human", assume it
is scriptable and prove otherwise — most GUI actions are. It can:

- send **real key events** (a virtual keyboard via `nested_key`, including
  arrows / Enter / Escape), routed through the live grab and capture phase;
- **set and read** the system clipboard (`St.Clipboard`) and the Meta selection —
  so paste-back is checkable end-to-end (write it, then read it back), not by a
  proxy field;
- exercise **D-Bus seams** (stub the proxy and record calls) and the live daemon signals;
- open the **real prefs window** via `org.gnome.Shell.Extensions.OpenExtensionPrefs`
  on the nested bus (the same path `openPreferences()` takes) and assert prefs.js
  loaded with no Adw error in the log — `node --check` catches only syntax, never a
  runtime Adw API change;
- **screenshot** the result.

It genuinely cannot judge: pixel-level visual polish, and behaviour that only
appears against real apps or the real Wayland session (e.g. a clipboard race with
one specific app). For those, reproduce headlessly FIRST; a live smoke / journal
is the fallback **only** when the headless result is already correct, never the
default.

**Never flip `passes` on a syntax-check or a spy alone** — that is how the
prefs/gear bug shipped green, and why the 005 paste-back test passed while
paste-back was broken in real use (it asserted an internal field, not the actual
system clipboard).

## Orientation

- **UI-only.** Never modify `strata-daemon` (ADR-0003). "Rust thinks, JS draws."
- **The extension is the clipboard capture agent on GNOME.** Mutter exposes
  neither `ext-` nor `wlr-data-control`, so the daemon's monitor does not bind;
  the extension must watch `global.display.get_selection()` and forward copies via
  `SubmitItem` (see `../AGENTS.md` ingest note and `strata-daemon/src/clipboard/monitor.rs`).
- **Only one Strata extension at a time.** `strata-ui@elijahlynn.net` and
  `strata@edu4rdshl.dev` both supervise the daemon, both bind Ctrl+Alt+C, and both
  capture the clipboard. Running both makes them fight; disable the other one.
- **Cards are `St.Label` only** — never `set_markup` on clipboard content.
- Glossary: `CONTEXT.md`. Spec: `docs/v1-spec.md`. Decisions: `docs/adr/`.
  References: `docs/reference/`. Progress log (newest on top): `claude-progress.txt`.
- Harness: `test-harness/{verify.sh,launch-nested.sh,coding-prompt.md,loop.sh}`.
- Live-session logs: `journalctl --user -f -o cat | grep 'Strata UI'`.
- GJS logs are prefixed `[Strata UI]`; no em-dashes or emojis in code/docs
  (inherited from `../AGENTS.md`).
