#!/usr/bin/env bash
# One iteration of the Strata UI coding loop.
# https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
#
# Picks the highest-priority feature whose blockedBy all pass, dispatches a fresh
# `claude` coding agent to implement ONLY that feature, then prints its manual
# test steps. It deliberately does NOT auto-flip `passes`: a GNOME Shell UI
# feature can only be verified in a live session, so a human flips passes=true
# after testing. Run it again for the next feature.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"          # .../strata-ui
TASKS="$REPO/docs/tasks.json"

# Next ready feature: passes==false AND every blockedBy id has passes==true.
next=$(jq -r '
  (.features | map({(.id): .passes}) | add) as $pass
  | .features[]
  | select(.passes == false)
  | select([.blockedBy[]? | $pass[.]] | all)
  | .id' "$TASKS" | head -n1)

if [ -z "$next" ]; then
  echo "No ready features (all pass, or remaining ones are blocked). Nothing to do."
  exit 0
fi

title=$(jq -r --arg id "$next" '.features[]|select(.id==$id)|.title' "$TASKS")
echo "==> Next ready feature: $next — $title"

read -r -d '' PROMPT <<EOF || true
You are a coding agent on the Strata UI GNOME Shell extension (plain JS, GJS).
Implement ONLY feature "$next" ("$title") from $REPO/docs/tasks.json — its steps are the acceptance criteria.

Authoritative design (read before coding):
  $REPO/docs/v1-spec.md
  $REPO/docs/adr/*.md
  $REPO/docs/reference/strata-daemon-dbus-contract.md
  $REPO/docs/reference/architecture-constraints.md

Rules:
  - Lift the daemon supervision and the dbus.js proxy VERBATIM from ../strata@edu4rdshl.dev/ (ADR-0001).
  - Do NOT modify anything under ../strata-daemon/ (ADR-0003: v1 is UI-only).
  - Put all extension code under $REPO/extension/ ; UUID strata-ui@elijahlynn.net.
  - Honor architecture-constraints.md (never block the main loop, St.Label only, etc.).

When done:
  - Run static checks: glib-compile-schemas on schemas/ if present; sanity-check JS.
  - Append a dated entry to $REPO/claude-progress.txt: what you built + the exact manual test steps.
  - git commit on the current branch, message: "$next: $title".
  - Do NOT set passes=true in tasks.json — a human flips it after a live GNOME test.
EOF

claude -p "$PROMPT" --dangerously-skip-permissions

echo
echo "==> $next implemented + committed. TEST it in a live GNOME session:"
jq -r --arg id "$next" '.features[]|select(.id==$id)|.steps[]|"   [ ] "+.' "$TASKS"
echo "==> If every step passes: set \"passes\": true for $next in docs/tasks.json and commit."
echo "==> Then run this script again for the next feature."
