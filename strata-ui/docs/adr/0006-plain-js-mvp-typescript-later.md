# 0006 — Plain JS for the MVP; migrate to TypeScript after it works

The v1 MVP is written in plain JavaScript (GJS), matching `strata@edu4rdshl.dev` so its `dbus.js`
client, daemon supervision, and pagination can be lifted almost verbatim. Converting to TypeScript
(the Copyous stack, with `@girs` GNOME typings) is a deliberate goal **after** a working MVP, not a
prerequisite.

## Why

- Fastest path to a working daily-driver: zero build step, and the borrowed Strata plumbing drops in
  with no porting.
- TypeScript's value (type-checking the GNOME/St/Clutter surface) is real but pays off most once the
  shape has stabilised; migrating after the MVP avoids churning types while the design still moves.

## Consequences

- No build tooling in v1; the TS migration (tsc/esbuild + `@girs/gnome-shell`) is a tracked post-MVP
  task.
- Until then we lean on the borrowed, battle-tested JS patterns from Strata's extension rather than
  fresh typed code.
