#!/usr/bin/env bash
# One coding-loop iteration: feed the canonical prompt (coding-prompt.md) to a
# fresh agent. The loop, the max-iterations cap, and the fish/bash notes live in
# the README "Developing" section — this is just the single-shot convenience.
set -o errexit -o nounset -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec claude --print "$(cat "$HERE/coding-prompt.md")" --dangerously-skip-permissions
