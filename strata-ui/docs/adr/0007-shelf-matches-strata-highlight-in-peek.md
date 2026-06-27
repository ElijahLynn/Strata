# 0007 — Shelf classification matches Strata; syntax highlighting only in Peek

On the Shelf, Cards are classified exactly as Strata's current extension does — plain **Text**,
**URL** (link-styled, hostname subtitle), **Color** (hex swatch), **Image** (thumbnail), **File(s)** —
with no code detection or colorizing on the cards. **Syntax highlighting happens only in Peek**, the
single enlarged Card, and ships in v1.

## Why

- "Whatever Strata does now" for the shelf keeps each card's render cheap and familiar.
- Running highlight.js to detect/colorize code for every visible Card is exactly the main-loop work
  the architecture forbids (it's why Copyous, which does it, stutters).
- In Peek the cost is one-off, on a single entry, on user action (Space) — the same bargain as the
  on-demand full-res image decode (ADR-0003), so it's safe in v1.

## Consequences

- Brings in a syntax-highlighting lib (e.g. highlight.js, as Copyous bundles) used only on the Peek
  path; language auto-detect on one entry is fine.
- Code entries look like plain Text on the shelf; colorized code appears when you Space into them.
