#!/usr/bin/env bash
# loop.sh — the autonomous build loop.
#
# Re-spawns a FRESH coding agent (coding-prompt.md) per iteration until every
# feature in docs/tasks.json is passes:true, or the max-iterations cap is hit.
# Each agent gets a clean context window; the durable state (tasks.json,
# claude-progress.txt, the commits) is what carries across iterations. A single
# agent already works feature-after-feature until it runs low on context
# (coding-prompt.md) — this loop is what survives that context limit.
#
# Usage:
#   bash test-harness/loop.sh        # run until all features pass (cap 20 agents)
#   bash test-harness/loop.sh 50     # raise the cap
#   bash test-harness/loop.sh 1      # a single iteration (one fresh agent)
set -o nounset -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
UI="$(dirname "$HERE")"
TASKS="$UI/docs/tasks.json"
MAX="${1:-20}"
TARGET="${2:-}"
PROMPT="$(cat "$HERE/coding-prompt.md")"
if [ -n "$TARGET" ]; then
  if ! jq --exit-status --arg id "$TARGET" '.features[] | select(.id == $id)' "$TASKS" >/dev/null; then
    printf 'loop.sh: unknown task %s\n' "$TARGET" >&2
    exit 1
  fi
  PROMPT="$PROMPT

Run scope override: work ONLY feature $TARGET, regardless of other pending IDs.
Stop after this feature or a genuine blocker. Do not build other features.
Do NOT commit or push: the interactive user has not authorized commits.
Keep the required RED, GREEN, teeth, and full-suite gates. Report their exit codes.
If the full suite has existing failures, report them without weakening tests or
marking the feature passing. Leave all work in the working tree for review."
fi

n=0
while jq --exit-status --arg id "$TARGET" '.features[] | select(.passes==false and ($id == "" or .id == $id))' "$TASKS" >/dev/null; do
  n=$((n + 1))
  if [ "$n" -gt "$MAX" ]; then
    echo "loop.sh: stopped at max-iterations $MAX (features still passes:false)"
    exit 1
  fi
  echo "loop.sh: iteration $n (cap $MAX) — spawning a fresh coding agent…"
  claude --print "$PROMPT" --dangerously-skip-permissions \
    || echo "loop.sh: agent exited non-zero; continuing to the next iteration"
done
echo "loop.sh: selected features are passes:true — done after $n iteration(s)."
