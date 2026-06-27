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

## What headless verify can and cannot catch

`test-harness/verify.sh` boots a throwaway nested GNOME Shell, drives the
extension over `Eval`, asserts real runtime state, and screenshots. It **does**
exercise: clipboard capture via the Meta selection, real key events, focus,
D-Bus seams (stub the proxy and record calls), and the live daemon signals.

It **does not** cover: the Adw preferences window (it needs a display, so it can
only be `node --check`-ed) and some Wayland-specific clipboard quirks. When a
slice's behaviour falls in that gap, say so in its `steps`, assert as much as you
can headlessly (a spy, a static grep, an end-to-end clipboard read-back), and add
a manual live-session smoke step. **Never flip `passes` on a syntax-check alone** —
that is how the prefs/gear bug shipped green, and why the 005 paste-back test
passed while paste-back was broken in real use (it asserted an internal field,
not the actual system clipboard).

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
