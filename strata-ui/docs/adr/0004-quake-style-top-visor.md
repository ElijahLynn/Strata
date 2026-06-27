# 0004 — Strata UI is a Quake-style visor (full-width, bottom by default)

The Shelf is not an always-on dock. It is a hotkey-summoned, transient overlay positioned like a
Quake console ("visor"), spanning the **entire screen width** at a **fixed pixel height**, and
dismisses on Escape / paste / focus-loss. It **appears instantly — no slide animation** (deliberate:
animation is fluff and spends shell-thread frames we want kept free).

- **Edge:** configurable top or bottom; **bottom is the default**.
- **Height:** fixed, default **~360px** (≈ a third of a 1080p screen — estimated from the Paste
  reference shot), exposed as a `visor-height` setting; scales with the display text-scaling factor.
  Internal budget (tags/categories dropped, so no category tab bar): ~48px search header + ~280px
  card row + ~32px padding.
- **Summon shortcut:** default **Ctrl+Alt+C**, customizable via the reused `keyboard-shortcut`
  GSettings key.

## Why

- A clipboard manager is summon-on-demand; a permanent dock would cost a full-time band of screen
  space and is heavier to do on GNOME (reserved struts).
- The Quake summon is a familiar, fast, keyboard-first interaction; shown instantly it feels snappy.
- A tall, full-width fixed band (vs Strata's narrow popup) is the whole point — it makes clipboard
  contents readable, which was the #1 pain.

## Consequences

- Windowing is a full-width, edge-anchored overlay shown/hidden instantly (no slide animation; not a
  struts-reserving dock).
- Edge (top/bottom) and height are settings; v1 defaults are bottom / ~360px.
- Ctrl+Alt+C is the documented default; conflicts are the user's to resolve since it's customizable.
