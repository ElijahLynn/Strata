# Pending merge state (written pre-compaction)

`strata-ui` HEAD = c7ebda9 (011 whole-card highlight — already on strata-ui).

## Worktree branches to cherry-pick onto strata-ui (each cut from 752afad)
- 017 search placeholder contrast — commit 7c181d9 — branch worktree-agent-a68421ccb0c51dae5 — DONE
- 018 crisp thumbnails (contain) — commit aa07d164 — branch worktree-agent-add0b681b3047cd98 — DONE
- 019 image multi-format paste-back — agent a5b8003960e23166b — RUNNING (may report BLOCKED: only fixable via daemon SetClipboard if it works on Mutter; else crosses ADR-0003)
- 020 Delete key removes focused item — agent a7d18b96c3623fd43 — RUNNING
- 021 gear re-click refocuses open prefs — agent a8a76ddc79ca34374 — RUNNING (likely live-smoke-gated; prefs window not observable headlessly)

## Merge procedure (post-compaction)
1. For each finished worktree branch: `git cherry-pick <commit>` onto strata-ui. Resolve conflicts:
   - claude-progress.txt: keep ALL entries, newest on top.
   - docs/tasks.json: keep ALL added slices (017-021 each add their feature).
   - verify.sh / stylesheet.css: different case blocks / rules — keep both sides.
2. After all are in: `cd strata-ui && ./test-harness/verify.sh all` — require ALL GREEN before declaring done.
3. Clean up: `git worktree remove --force` each + `git branch -D` the worktree branches. Delete this file.

## Tasked, NOT built
- 022 file-path-for-images (just added to tasks.json; do not build until directed).

## Honest gaps to record (not pretend-fixed)
- 013 gear works live but is NOT headless-teeth-tested (openPreferences cant be observed headlessly) -> mark live-smoke-gated.
- Image paste into a text terminal is inherent/unfixable via clipboard; slice 022 (file path) is the workaround.

## Live-verified working
capture, nav + visible whole-card highlight, text paste, image paste (into image apps), gear/prefs, layout/theme.
