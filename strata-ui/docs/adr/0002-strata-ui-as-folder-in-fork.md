# 0002 — Strata UI lives as a folder inside a fork of Strata, for now

Strata UI is developed as `strata-ui/`, a sibling folder to `strata-daemon/` inside a
personal fork (`ElijahLynn/Strata`), rather than in a standalone repository — even though
the upstream maintainer suggested a separate repo. This keeps the daemon source, its D-Bus
contract, and the GSettings schema in one tree while the UI is prototyped, and makes any
daemon-side changes easy to develop and later upstream via PR.

## Status

accepted (provisional — "for now")

## Consequences

- The UI's git history is entangled with the Strata fork; splitting it into its own repo
  later means a `git subtree split` (history is preservable).
- `git pull upstream` stays conflict-free as long as we only add `strata-ui/` and don't edit
  daemon files — until/unless we extend the daemon for edit/pin (which would touch
  `strata-daemon/`).
- The project's "home" (issues, releases, extension UUID) is deferred; for now it lives in
  the fork. Upstream issue context: Edu4rdSHL/Strata#3.
