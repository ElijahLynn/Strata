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

n=0
while jq --exit-status '.features[] | select(.passes==false)' "$TASKS" >/dev/null; do
  n=$((n + 1))
  if [ "$n" -gt "$MAX" ]; then
    echo "loop.sh: stopped at max-iterations $MAX (features still passes:false)"
    exit 1
  fi
  echo "loop.sh: iteration $n (cap $MAX) — spawning a fresh coding agent…"
  claude --print "$(cat "$HERE/coding-prompt.md")" --dangerously-skip-permissions \
    || echo "loop.sh: agent exited non-zero; continuing to the next iteration"
done
echo "loop.sh: every feature is passes:true — done after $n iteration(s)."
