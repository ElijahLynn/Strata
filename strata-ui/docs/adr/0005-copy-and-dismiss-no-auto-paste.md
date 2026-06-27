# 0005 — Copy-and-dismiss; never auto-paste

Selecting a Card (Enter) writes the entry to the system clipboard and dismisses the visor — the user
presses Ctrl+V themselves. Strata UI does **not** auto-paste (synthesize a paste into the previously
focused app), even though it technically could from inside the compositor.

## Why

The user dislikes auto-paste and disables it in every tool that ships it on by default.
Copy-and-dismiss is also simpler and more robust on Wayland. Recorded as an explicit "no" so
auto-paste isn't reintroduced as a default later; if ever wanted, it may exist only as an opt-in
setting (default off).
